import AppKit
import Foundation
import HeftCore

/// Runs the reader's agent for one window's search bar and keeps the
/// conversations it is in.
///
/// A run outlives the bar: closing it leaves the agent working, and the
/// answer is in the chat the next time the bar opens on it. Each question is
/// a fresh process; a reply continues the agent's own session, so it
/// remembers what it read. Several chats can be answering at once, each in
/// its own process.
@MainActor
final class AgentRunner: ObservableObject {

    /// The conversation on screen, or nil for the list of chats.
    @Published private(set) var chat: AgentChat?
    /// Every chat in the vault, latest first.
    @Published private(set) var chats: [AgentChat] = []
    /// What each running chat's agent is doing right now, by chat.
    @Published private(set) var activities: [String: String] = [:]
    /// Whether the agent command could not be found on the last try.
    @Published private(set) var isMissing = false


    /// Whether the chat on screen is being answered.
    var isRunning: Bool { chat.map { runs[$0.id] != nil } ?? false }
    /// What the chat on screen's agent is doing.
    var activity: String? { chat.flatMap { activities[$0.id] } }
    /// Whether any chat is being answered, on screen or not.
    var isBusy: Bool { !runs.isEmpty }

    /// What to run and with which model; settings by default, a fake in tests.
    var command: () -> String = { GeneralSettings.shared.agentCommand }
    var model: () -> String = { GeneralSettings.shared.agentModel }
    /// Called with the proposals a run left, once it has finished.
    var onProposals: ([AgentChat.ProposalNote]) -> Void = { _ in }
    /// Where this app's `heft` is linked for the agent; nil in tests.
    var heftDirectory: () -> URL? = AgentRunner.linkedHeftDirectory
    /// Full paths the agent may call `heft` by; this app's own by default.
    var heftAliases: () -> [String] = AgentRunner.ownHeftPaths
    /// Names a chat from its first question and answer; nil leaves it
    /// named by the question. Apple's on-device model by default.
    var titler: @MainActor (String, String) async -> String? = { question, answer in
        guard GeneralSettings.shared.namesChats else { return nil }
        return await ChatTitler.title(question: question, answer: answer)
    }

    private var vaultRoot: URL?
    /// A chat being answered: its process, and the chat as the run has it,
    /// kept apart from the one on screen so closing the bar mid-answer
    /// loses nothing.
    private struct Run {
        var process: Process
        var chat: AgentChat
        /// When it started: its proposals are the ones signed with its chat
        /// and made since, so one re-proposed under the same id counts.
        var started: Date
    }
    @Published private var runs: [String: Run] = [:]
    private static let host = ProcessInfo.processInfo.hostName

    /// How long a run may take before it is stopped: an agent that hangs
    /// would otherwise hold its chat, and its process, forever.
    var timeLimit: Duration = .seconds(600)
    private var quitObserver: NSObjectProtocol?
    /// Runs stopped for taking too long, so they say so.
    private var timedOut: Set<String> = []

    init() {
        // Quitting stops every run rather than leaving them to finish alone,
        // where one could still leave a proposal with no chat to show it.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    /// Stops every run and saves each chat as it stands, marked stopped:
    /// for a window closing or the app quitting, which will not be here
    /// when the processes end.
    func stopAll() {
        for (_, run) in runs {
            run.process.terminate()
            var chat = run.chat
            chat.turns[chat.turns.count - 1].failure = "Stopped"
            finish(chat)
        }
        runs.removeAll()
        activities.removeAll()
    }

    // MARK: Chats

    func load(vaultRoot: URL?) {
        if self.vaultRoot != vaultRoot { chat = nil }
        self.vaultRoot = vaultRoot
        chats = vaultRoot.map(AgentChatStore.all(in:)) ?? []
    }

    func open(_ chat: AgentChat) {
        self.chat = runs[chat.id]?.chat ?? chat
    }

    /// Back to the list; a run in progress carries on and saves.
    func close() {
        chat = nil
    }

    func isRunning(_ chatID: String) -> Bool { runs[chatID] != nil }

    /// Names a chat as the reader wants it; its first question until then.
    func rename(_ chat: AgentChat, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var renamed = runs[chat.id]?.chat ?? (self.chat?.id == chat.id ? self.chat ?? chat : chat)
        renamed.title = trimmed
        if runs[chat.id] != nil { runs[chat.id]?.chat = renamed }
        finish(renamed)
    }

    func delete(_ chat: AgentChat) {
        guard let vaultRoot else { return }
        runs[chat.id]?.process.terminate()
        if self.chat?.id == chat.id { close() }
        AgentChatStore.delete(chat.id, in: vaultRoot)
        load(vaultRoot: vaultRoot)
    }

    // MARK: Asking

    /// Asks `question`: a new chat, or the next turn of the one on screen.
    ///
    /// - Parameters:
    ///   - instruction: what the agent is sent in place of `question`,
    ///     which is what the chat shows.
    ///   - files: files and folders the reader named, which the agent may
    ///     read without being refused first.
    ///   - scope: the vault-relative folder a new chat reads in, empty for
    ///     the whole vault. A reply keeps its chat's scope.
    func ask(
        _ question: String, instruction: String? = nil, files: [URL] = [],
        vaultRoot: URL, scope: String
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        self.vaultRoot = vaultRoot
        var chat = self.chat ?? AgentChat(question: trimmed, instruction: instruction, scope: scope)
        if self.chat != nil { chat.turns.append(.init(question: trimmed, instruction: instruction)) }
        var sent = instruction ?? trimmed
        let lent = lend(files, to: &chat, vaultRoot: vaultRoot)
        if !lent.isEmpty {
            sent = "(The reader named these, and you may read them:\n"
                + lent.map { "- \($0.named) is at \($0.readable)" }.joined(separator: "\n")
                + ")\n\n" + sent
            chat.turns[chat.turns.count - 1].instruction = sent
        }
        run(chat, question: sent)
    }

    /// Lets the agent read what the reader named: a folder as it is, a file
    /// as a copy in a folder of this chat's own.
    private func lend(_ files: [URL], to chat: inout AgentChat, vaultRoot: URL) -> [(named: String, readable: String)] {
        let scopeFolder = chat.scope.isEmpty ? vaultRoot : vaultRoot.appendingPathComponent(chat.scope)
        let inside = scopeFolder.standardizedFileURL.path + "/"
        var lent: [(String, String)] = []
        var copies: [URL] = []
        for file in files where !file.standardizedFileURL.path.hasPrefix(inside) {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                if !chat.allowed.contains(file.path) { chat.allowed.append(file.path) }
                lent.append((file.path, file.path))
            } else {
                copies.append(file)
            }
        }
        guard !copies.isEmpty else { return lent }
        let folder = Self.lendingFolder(for: chat.id)
        for (original, copy) in AgentFiles.stage(copies, into: folder) {
            lent.append((original.path, copy.path))
        }
        if !chat.allowed.contains(folder.path) { chat.allowed.append(folder.path) }
        return lent
    }

    /// Where a chat's copies of named files go: the temporary folder, so
    /// the system clears them in time.
    static func lendingFolder(for chatID: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Heft Ask", isDirectory: true)
            .appendingPathComponent(chatID, isDirectory: true)
    }

    /// Lets the agent read what it was refused, and has it carry on.
    func allow(_ denials: [AgentDenial]) {
        guard var chat, !isRunning else { return }
        let folders = denials.compactMap(\.allowFolder)
        guard !folders.isEmpty else { return }
        for folder in folders where !chat.allowed.contains(folder) { chat.allowed.append(folder) }
        let things = folders.uniqued().joined(separator: ", ")
        let question = "You may now read in \(things). Carry on."
        chat.turns.append(.init(question: question))
        run(chat, question: question)
    }

    /// Stops the chat on screen's run.
    func cancel() {
        guard let chat else { return }
        runs[chat.id]?.process.terminate()
    }

    /// Asks the last question again, after a failure.
    func retry() {
        guard var chat, !isRunning, let last = chat.turns.indices.last else { return }
        let question = chat.turns[last].question
        let instruction = chat.turns[last].instruction
        chat.turns[last] = .init(question: question, instruction: instruction)
        run(chat, question: instruction ?? question)
    }

    /// Notes what the reader did with a proposal from this chat.
    func record(_ outcome: AgentChat.ProposalNote.Outcome, for proposalID: String) {
        guard var chat else { return }
        for turn in chat.turns.indices {
            for index in chat.turns[turn].proposals.indices where chat.turns[turn].proposals[index].id == proposalID {
                chat.turns[turn].proposals[index].outcome = outcome
            }
        }
        if runs[chat.id] != nil { runs[chat.id]?.chat = chat }
        finish(chat)
    }

    /// Who this chat's proposals are from, as the review centre shows it,
    /// and how a run tells its own proposals from another chat's.
    static func agentName(for chat: AgentChat) -> String {
        "Ask: \(chat.title.prefix(40)) [\(chat.id.prefix(4))]"
    }

    private func run(_ startingChat: AgentChat, question: String) {
        var chat = startingChat
        self.chat = chat
        guard let vaultRoot else { return }
        guard let executable = AgentLocator.find(command: command()) else {
            isMissing = true
            chat.turns[chat.turns.count - 1].failure = "missing"
            finish(chat)
            return
        }
        isMissing = false
        let scopeFolder = chat.scope.isEmpty
            ? vaultRoot
            : vaultRoot.appendingPathComponent(chat.scope, isDirectory: true)
        let resumes = chat.session != nil && chat.host == Self.host
        let invocation = AgentInvocation(
            executable: executable, model: model(),
            workingDirectory: scopeFolder, vaultRoot: vaultRoot,
            heftDirectory: heftDirectory(),
            prompt: resumes ? question : chat.prompt(continuing: question),
            resume: resumes ? chat.session : nil,
            allowed: chat.allowed,
            vaultInstructions: AgentInvocation.vaultInstructions(
                vaultRoot: vaultRoot, workingDirectory: scopeFolder
            ),
            heftAliases: heftAliases()
        )
        let started = Date()

        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = scopeFolder
        var environment = invocation.environment(base: ProcessInfo.processInfo.environment)
        environment[AgentCLI.agentNameVariable] = Self.agentName(for: chat)
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            chat.turns[chat.turns.count - 1].failure = error.localizedDescription
            finish(chat)
            return
        }
        runs[chat.id] = Run(process: process, chat: chat, started: started)
        activities[chat.id] = "Thinking"
        let limit = timeLimit
        Task { [weak self, weak process] in
            try? await Task.sleep(for: limit)
            guard let self, let process, process.isRunning, self.runs[chat.id]?.process === process else { return }
            self.timedOut.insert(chat.id)
            process.terminate()
        }

        let chatID = chat.id
        let handle = output.fileHandleForReading
        let errorHandle = errors.fileHandleForReading
        Task.detached { [weak self] in
            var parser = AgentStreamParser()
            var outcome: AgentOutcome?
            do {
                for try await line in handle.bytes.lines {
                    let events = parser.parse(line)
                    for case .finished(let found) in events { outcome = found }
                    guard !events.isEmpty else { continue }
                    await self?.apply(events, to: chatID)
                }
            } catch {}
            process.waitUntilExit()
            let stderr = String(decoding: errorHandle.readDataToEndOfFile(), as: UTF8.self)
            await self?.ended(
                chatID, outcome: outcome, status: process.terminationStatus,
                reason: process.terminationReason, stderr: stderr
            )
        }
    }

    private func apply(_ events: [AgentEvent], to chatID: String) {
        guard var chat = runs[chatID]?.chat else { return }
        for event in events {
            switch event {
            case .started(let session):
                chat.session = session
                chat.host = Self.host
            case .text(let text):
                chat.turns[chat.turns.count - 1].answer += text
            case .activity(let doing):
                activities[chatID] = doing
            case .finished:
                break
            }
        }
        runs[chatID]?.chat = chat
        if self.chat?.id == chatID { self.chat = chat }
    }

    private func ended(
        _ chatID: String, outcome: AgentOutcome?, status: Int32,
        reason: Process.TerminationReason, stderr: String
    ) {
        activities[chatID] = nil
        // The chat may have been closed while it ran; it is finished on disk
        // all the same.
        guard let run = runs.removeValue(forKey: chatID), let vaultRoot else { return }
        var chat = run.chat
        let last = chat.turns.count - 1
        if let outcome {
            chat.turns[last].denials = outcome.denials
            if outcome.isError {
                chat.turns[last].failure = Self.failure(outcome.message + "\n" + stderr)
            }
            if chat.turns[last].answer.isEmpty, !outcome.isError {
                chat.turns[last].answer = outcome.message
            }
        } else if timedOut.remove(chatID) != nil {
            chat.turns[last].failure = "The agent took longer than \(timeLimit.components.seconds / 60) minutes and was stopped."
        } else if reason == .uncaughtSignal {
            chat.turns[last].failure = "Stopped"
        } else {
            chat.turns[last].failure = Self.failure(stderr.isEmpty ? "The agent exited with status \(status)." : stderr)
        }
        // Its own proposals, by the name it was given and the time: another
        // chat running alongside leaves proposals in the same folder.
        let left = Self.own(ProposalStore.all(in: vaultRoot), chat: chat, since: run.started)
        chat.turns[last].proposals = Self.merged(chat.turns[last].proposals, with: left)
        finish(chat)
        if !left.isEmpty { onProposals(chat.turns[last].proposals) }
        if last == 0, chat.turns[0].failure == nil, !chat.turns[0].answer.isEmpty { nameChat(chat) }
    }

    /// Gives a chat a name after its first answer, unless the reader has
    /// already given it one.
    private func nameChat(_ chat: AgentChat) {
        let question = chat.turns[0].question
        let answer = chat.turns[0].answer
        Task { [weak self] in
            guard let self, let title = await self.titler(question, answer) else { return }
            let current = self.chats.first { $0.id == chat.id } ?? chat
            guard current.title == AgentChat.title(for: question) else { return }
            self.rename(current, to: title)
        }
    }

    /// Claims the proposals running chats have made so far, as they land on
    /// disk: an answer's cards appear while it is still being written, and
    /// an earlier card whose note was proposed again says so at once,
    /// rather than showing the new version until the run ends.
    func claim(_ proposals: [Proposal]) {
        for (id, run) in runs {
            let own = Self.own(proposals, chat: run.chat, since: run.started)
            guard !own.isEmpty else { continue }
            var chat = run.chat
            let last = chat.turns.count - 1
            let merged = Self.merged(chat.turns[last].proposals, with: own)
            guard merged != chat.turns[last].proposals else { continue }
            chat.turns[last].proposals = merged
            runs[id]?.chat = chat
            if self.chat?.id == id { self.chat = chat }
        }
    }

    static func own(_ proposals: [Proposal], chat: AgentChat, since started: Date) -> [Proposal] {
        let name = agentName(for: chat)
        return proposals.filter { $0.agent == name && $0.createdAt >= started }
    }

    /// What a turn already listed, then what is new, each once.
    static func merged(_ listed: [AgentChat.ProposalNote], with found: [Proposal]) -> [AgentChat.ProposalNote] {
        var result = listed
        for proposal in found where !result.contains(where: { $0.id == proposal.id }) {
            result.append(.init(id: proposal.id, notePath: proposal.notePath, headline: proposal.headline))
        }
        return result
    }

    /// Saves a turn that has ended, and shows it if its chat is on screen.
    private func finish(_ finished: AgentChat) {
        var chat = finished
        chat.updatedAt = Date()
        if self.chat?.id == chat.id { self.chat = chat }
        if let vaultRoot {
            try? AgentChatStore.save(chat, in: vaultRoot)
            chats = AgentChatStore.all(in: vaultRoot)
        }
    }

    /// A failure in the reader's words. A signed-out agent is the common one,
    /// and the fix is outside Heft.
    static func failure(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("log in") || lowered.contains("login") || lowered.contains("not logged")
            || lowered.contains("authenticat") || lowered.contains("api key") {
            return "signedOut"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The agent stopped without an answer." : String(trimmed.prefix(400))
    }

    /// A folder with a `heft` that runs this very app, so the agent's
    /// proposals go through the version on screen.
    /// The full paths a vault's guide may name `heft` by, that are this
    /// running app: the bundle's own binary, and links to it.
    static func ownHeftPaths() -> [String] {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return [] }
        let candidates = [
            own, "/Applications/Heft.app/Contents/MacOS/Heft", "/opt/homebrew/bin/heft", "/usr/local/bin/heft",
        ]
        return candidates.filter {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == own
        }.uniqued()
    }

    static func linkedHeftDirectory() -> URL? {
        guard let executable = Bundle.main.executableURL,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("Heft/agent-bin", isDirectory: true)
        let link = folder.appendingPathComponent("heft")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != executable.path {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        }
        return folder
    }
}
