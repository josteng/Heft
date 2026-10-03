import Foundation
import HeftCore
import Testing
@testable import Heft

/// A whole run against a fake agent: a script that prints what `claude -p`
/// would, records how it was called, and can leave a proposal behind.
@MainActor
@Suite("Agent runner", .serialized)
struct AgentRunnerTests {

    private struct Fixture {
        let vault: URL
        let script: URL
        let calls: URL
        let runner: AgentRunner

        func calledArguments() -> [[String]] {
            let text = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return text.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
        }
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// - Parameters:
    ///   - stdout: lines the fake prints.
    ///   - stderr: what it prints to standard error before exiting.
    ///   - status: its exit status.
    ///   - leavesProposal: whether it drops a proposal into the vault, as
    ///     `heft propose` would.
    private func fixture(
        stdout: [String], stderr: String = "", status: Int32 = 0, leavesProposal: Bool = false,
        delay: Double = 0
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-runner-\(UUID().uuidString)", isDirectory: true)
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Work"), withIntermediateDirectories: true
        )
        try "# Plan\nFriday.\n".write(
            to: vault.appendingPathComponent("Work/Plan.md"), atomically: true, encoding: .utf8
        )
        let output = root.appendingPathComponent("stdout.jsonl")
        try (stdout.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        let staged = root.appendingPathComponent("Staged", isDirectory: true)
        if leavesProposal {
            _ = try ProposalStore.write(Proposal(
                id: "plan", notePath: "Work/Plan.md", base: "# Plan\nFriday.\n",
                body: "# Plan\nMonday.\n", agent: "claude-code", summary: "Move to Monday",
                // Stamped as heft stamps it, when the run proposes: after it started.
                createdAt: Date().addingTimeInterval(60)
            ), in: staged)
        }
        let calls = root.appendingPathComponent("calls")
        let script = root.appendingPathComponent("fake-agent")
        // Arguments joined with unit separators, calls with record ones, so
        // an empty argument survives.
        try """
        #!/bin/sh
        { printf '%s\\037' "$PWD"; for a in "$@"; do printf '%s\\037' "$a"; done; printf '\\036'; } >> "\(calls.path)"
        sleep \(delay)
        \(leavesProposal ? "mkdir -p \"\(vault.path)/.heft/proposals\" && for f in \"\(staged.path)\"/.heft/proposals/*.json; do sed -e \"s|\\\"claude-code\\\"|\\\"$HEFT_AGENT_NAME\\\"|\" -e \"s|\\\"plan\\\"|\\\"plan-$$\\\"|\" \"$f\" > \"\(vault.path)/.heft/proposals/$(basename \"$f\" .json)-$$.json\"; done" : "")
        cat "\(output.path)"
        printf '%s' '\(stderr)' >&2
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = AgentRunner()
        runner.command = { script.path }
        runner.model = { "haiku" }
        runner.heftDirectory = { nil }
        runner.titler = { _, _ in nil }
        runner.load(vaultRoot: vault)
        return Fixture(vault: vault, script: script, calls: calls, runner: runner)
    }

    private func settle(_ runner: AgentRunner) async throws {
        for _ in 0..<500 where runner.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!runner.isBusy, "the run never ended")
    }

    private var answering: [String] {
        [
            line(["type": "system", "subtype": "init", "session_id": "s-1"]),
            line(["type": "stream_event", "event": ["type": "message_start", "message": [:]]]),
            line(["type": "stream_event", "event": [
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "Due "],
            ]]),
            line(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/v/Work/Plan.md"]],
            ]]]),
            line(["type": "stream_event", "event": [
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "Friday, see [[Plan]]."],
            ]]),
            line(["type": "result", "is_error": false, "result": "Due Friday, see [[Plan]].",
                  "permission_denials": [["tool_name": "Read", "tool_input": ["file_path": "/elsewhere/Secret.md"]]]]),
        ]
    }

    @Test("A question streams its answer, starts in its scope, and is saved with its proposals")
    func ask() async throws {
        let fixture = try fixture(stdout: answering, leavesProposal: true)
        var reported: [AgentChat.ProposalNote] = []
        fixture.runner.onProposals = { reported = $0 }
        fixture.runner.ask("What is due?", vaultRoot: fixture.vault, scope: "Work")
        #expect(fixture.runner.isRunning)
        try await settle(fixture.runner)

        let chat = try #require(fixture.runner.chat)
        #expect(chat.turns.count == 1)
        #expect(chat.turns[0].answer == "Due Friday, see [[Plan]].")
        #expect(chat.session == "s-1")
        #expect(chat.turns[0].proposals.map(\.id).allSatisfy { $0.hasPrefix("plan-") })
        #expect(chat.turns[0].proposals.count == 1)
        #expect(reported.map(\.notePath) == ["Work/Plan.md"])
        #expect(chat.turns[0].denials.map(\.target) == ["/elsewhere/Secret.md"])
        #expect(chat.turns[0].failure == nil)
        #expect(fixture.runner.activity == nil)
        // Saved as shown; dates are stored to the second.
        let saved = AgentChatStore.all(in: fixture.vault)
        #expect(saved.map(\.id) == [chat.id])
        #expect(saved.first?.turns.map(\.answer) == chat.turns.map(\.answer))
        #expect(saved.first?.turns.first?.proposals == chat.turns[0].proposals)
        #expect(saved.first?.session == "s-1")

        let call = try #require(fixture.calledArguments().first)
        #expect(URL(fileURLWithPath: call[0]).resolvingSymlinksInPath().lastPathComponent == "Work", "starts in the scope")
        #expect(call.contains("What is due?"))
        #expect(!call.contains("--resume"))
    }

    /// The agent's own session holds what it read, so a reply goes back
    /// into it rather than starting over.
    @Test("A reply resumes the session, and an allowed read is passed on")
    func replyAndAllow() async throws {
        let fixture = try fixture(stdout: answering)
        fixture.runner.ask("What is due?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        let denials = try #require(fixture.runner.chat?.turns.last?.denials)
        fixture.runner.allow(denials)
        try await settle(fixture.runner)
        fixture.runner.ask("And after?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)

        let calls = fixture.calledArguments()
        #expect(calls.count == 3)
        let allowedRun = calls[1]
        #expect(allowedRun.contains("--resume") && allowedRun.contains("s-1"))
        #expect(allowedRun.contains("/elsewhere"), "the refused file's folder, added")
        let reply = calls[2]
        #expect(reply.contains("And after?"), "the plain question, the session holds the rest")
        #expect(reply.contains("/elsewhere"), "an allowance lasts the chat")
        #expect(fixture.runner.chat?.turns.count == 3)
        #expect(fixture.runner.chats.count == 1, "one chat, three turns")
    }

    /// "Draft a note" sends the agent a page of instructions; the chat
    /// shows the reader's own words.
    @Test("The agent is sent the instruction, the chat shows the question")
    func instruction() async throws {
        let fixture = try fixture(stdout: answering)
        fixture.runner.ask(
            "Draft a note from \u{201C}lunch\u{201D}", instruction: "Full drafting instructions",
            vaultRoot: fixture.vault, scope: ""
        )
        try await settle(fixture.runner)
        #expect(fixture.runner.chat?.turns[0].question == "Draft a note from \u{201C}lunch\u{201D}")
        let call = try #require(fixture.calledArguments().first)
        #expect(call.contains("Full drafting instructions"))
        #expect(!call.contains("Draft a note from \u{201C}lunch\u{201D}"))
        fixture.runner.retry()
        try await settle(fixture.runner)
        #expect(fixture.calledArguments().last?.contains("Full drafting instructions") == true, "a retry sends it again")
    }

    /// A second question while the first is answered starts its own run,
    /// and each chat keeps only the proposals its own agent made.
    @Test("Two chats answer at once, each with its own proposals")
    func twoAtOnce() async throws {
        let fixture = try fixture(stdout: answering, leavesProposal: true, delay: 0.3)
        fixture.runner.ask("First?", vaultRoot: fixture.vault, scope: "")
        let first = try #require(fixture.runner.chat)
        #expect(fixture.runner.isRunning)
        fixture.runner.close()
        #expect(!fixture.runner.isRunning, "nothing on screen is answering")
        fixture.runner.ask("Second?", vaultRoot: fixture.vault, scope: "")
        let second = try #require(fixture.runner.chat)
        #expect(second.id != first.id)
        #expect(fixture.runner.isRunning(first.id) && fixture.runner.isRunning(second.id))
        try await settle(fixture.runner)

        let chats = Dictionary(uniqueKeysWithValues: fixture.runner.chats.map { ($0.id, $0) })
        let firstProposals = chats[first.id]?.turns[0].proposals ?? []
        let secondProposals = chats[second.id]?.turns[0].proposals ?? []
        #expect(firstProposals.count == 1 && secondProposals.count == 1)
        #expect(firstProposals.first?.id != secondProposals.first?.id, "each its own")
        #expect(chats[first.id]?.turns[0].answer == "Due Friday, see [[Plan]].")
    }

    /// A file named by path is the reader's consent to reading it: a copy,
    /// so naming one file does not open the folder it is in.
    @Test("A named file is lent as a copy, a named folder as it is")
    func namedFiles() async throws {
        let fixture = try fixture(stdout: answering)
        let outside = fixture.vault.deletingLastPathComponent().appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let paper = outside.appendingPathComponent("Draft paper.md")
        try "annotations".write(to: paper, atomically: true, encoding: .utf8)

        fixture.runner.ask(
            "Summarise \(paper.path) please", files: AgentFiles.paths(in: "Summarise \(paper.path) please"),
            vaultRoot: fixture.vault, scope: ""
        )
        try await settle(fixture.runner)
        let chat = try #require(fixture.runner.chat)
        let lent = AgentRunner.lendingFolder(for: chat.id)
        #expect(chat.allowed == [lent.path], "the copy's folder, not the original's")
        let call = try #require(fixture.calledArguments().first)
        #expect(call.contains(lent.path))
        #expect(!call.contains(outside.path), "the folder it came from stays closed")
        let sent = call.first { $0.contains("you may read them") } ?? ""
        #expect(sent.contains(paper.path) && sent.contains(lent.path))
        #expect(chat.turns[0].question == "Summarise \(paper.path) please", "the chat shows what was typed")
        let copies = try FileManager.default.subpathsOfDirectory(atPath: lent.path).filter { $0.hasSuffix("Draft paper.md") }
        #expect(copies.count == 1)

        fixture.runner.close()
        fixture.runner.ask("Look in \(outside.path)", files: [outside], vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        #expect(fixture.runner.chat?.allowed == [outside.path])
    }

    /// A window closing or the app quitting will not be here when the
    /// process ends, so the chat is saved as far as it got, and nothing is
    /// left running.
    @Test("Stopping everything ends the processes and saves the chats as stopped")
    func stopAll() async throws {
        let fixture = try fixture(stdout: answering, delay: 5)
        fixture.runner.ask("Slow?", vaultRoot: fixture.vault, scope: "")
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.runner.isBusy)
        fixture.runner.stopAll()
        #expect(!fixture.runner.isBusy)
        let saved = try #require(AgentChatStore.all(in: fixture.vault).first)
        #expect(saved.turns[0].failure == "Stopped")
        // The script was killed, so it never got to print its answer.
        try await Task.sleep(for: .milliseconds(500))
        #expect(AgentChatStore.all(in: fixture.vault).first?.turns[0].answer == "")
    }

    @Test("A run past its time limit is stopped and says why")
    func timeLimit() async throws {
        let fixture = try fixture(stdout: answering, delay: 5)
        fixture.runner.timeLimit = .milliseconds(300)
        fixture.runner.ask("Slow?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        let failure = try #require(fixture.runner.chat?.turns[0].failure)
        #expect(failure.contains("longer than"), "got \(failure)")
    }

    /// The on-device model names a chat after its first answer; the agent
    /// is never asked to. A name the reader gave is never replaced.
    @Test("The first answer names the chat, unless the reader named it")
    func onDeviceTitle() async throws {
        let fixture = try fixture(stdout: answering)
        var asked: [(String, String)] = []
        fixture.runner.titler = { question, answer in
            asked.append((question, answer))
            return "Parser deadline"
        }
        fixture.runner.ask("When is it due?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.runner.chat?.title == "Parser deadline")
        #expect(asked.count == 1 && asked.first?.0 == "When is it due?" && asked.first?.1 == "Due Friday, see [[Plan]].")
        #expect(!(fixture.calledArguments().first ?? []).contains { $0.contains("Title") }, "the agent is not asked")

        fixture.runner.ask("And after?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.count == 1, "only the first answer names it")

        // Renamed by the reader before the name arrives: theirs stays.
        fixture.runner.close()
        fixture.runner.titler = { _, _ in
            try? await Task.sleep(for: .milliseconds(200))
            return "Model name"
        }
        fixture.runner.ask("Another?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        fixture.runner.rename(try #require(fixture.runner.chat), to: "Mine")
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.runner.chats.first { $0.turns[0].question == "Another?" }?.title == "Mine")
    }

    /// Claimed as they land, so an earlier card whose note was proposed
    /// again says "Replaced below" at once, not when the answer ends.
    @Test("A running chat claims its proposals as they land, same id included")
    func claimsWhileRunning() async throws {
        let fixture = try fixture(stdout: answering, delay: 2)
        fixture.runner.ask("Draft it", vaultRoot: fixture.vault, scope: "")
        let chat = try #require(fixture.runner.chat)
        let name = AgentRunner.agentName(for: chat)
        func proposal(_ id: String, agent: String, at date: Date) -> Proposal {
            Proposal(id: id, notePath: "Work/Plan.md", base: nil, body: "x", agent: agent, summary: "s", createdAt: date)
        }
        fixture.runner.claim([
            proposal("plan", agent: name, at: Date()),
            proposal("other", agent: "Ask: another chat", at: Date()),
            proposal("old", agent: name, at: Date().addingTimeInterval(-3600)),
        ])
        #expect(fixture.runner.isRunning, "still answering")
        #expect(fixture.runner.chat?.turns[0].proposals.map(\.id) == ["plan"], "its own, new, and only those")
        fixture.runner.claim([proposal("plan", agent: name, at: Date())])
        #expect(fixture.runner.chat?.turns[0].proposals.count == 1, "listed once")
        fixture.runner.stopAll()
    }

    @Test("Turned off, the on-device model is not asked for a name")
    func namingOff() async {
        let naming = GeneralSettings.shared.namesChats
        GeneralSettings.shared.namesChats = false
        defer { GeneralSettings.shared.namesChats = naming }
        let title = await AgentRunner().titler("When is the parser due?", "Friday.")
        #expect(title == nil)
    }

    @Test("A chat is named by its first question until the reader renames it")
    func rename() async throws {
        let fixture = try fixture(stdout: answering)
        fixture.runner.ask("When is it due?", vaultRoot: fixture.vault, scope: "")
        try await settle(fixture.runner)
        let chat = try #require(fixture.runner.chat)
        #expect(chat.title == "When is it due?")
        fixture.runner.rename(chat, to: "  Parser deadline  ")
        #expect(AgentChatStore.all(in: fixture.vault).first?.title == "Parser deadline")
        fixture.runner.rename(chat, to: "   ")
        #expect(AgentChatStore.all(in: fixture.vault).first?.title == "Parser deadline", "an empty name is no name")
    }

    @Test("A closed chat keeps answering, and is complete when opened again")
    func closedWhileRunning() async throws {
        let fixture = try fixture(stdout: answering)
        fixture.runner.ask("What is due?", vaultRoot: fixture.vault, scope: "")
        fixture.runner.close()
        try await settle(fixture.runner)
        #expect(fixture.runner.chat == nil)
        let saved = try #require(fixture.runner.chats.first)
        #expect(saved.turns[0].answer == "Due Friday, see [[Plan]].")
    }

    @Test("A missing agent and a signed-out one each say so")
    func failures() async throws {
        let missing = try fixture(stdout: [])
        missing.runner.command = { "/nowhere/claude" }
        missing.runner.ask("Hello?", vaultRoot: missing.vault, scope: "")
        try await settle(missing.runner)
        #expect(missing.runner.isMissing)
        #expect(missing.runner.chat?.turns[0].failure == "missing")

        let signedOut = try fixture(stdout: [], stderr: "Invalid API key. Please run /login", status: 1)
        signedOut.runner.ask("Hello?", vaultRoot: signedOut.vault, scope: "")
        try await settle(signedOut.runner)
        #expect(signedOut.runner.chat?.turns[0].failure == "signedOut")
        #expect(!signedOut.runner.isMissing)

        let broken = try fixture(stdout: [], stderr: "Something else broke", status: 2)
        broken.runner.ask("Hello?", vaultRoot: broken.vault, scope: "")
        try await settle(broken.runner)
        #expect(broken.runner.chat?.turns[0].failure == "Something else broke")
    }
}

@Suite("Chat cards")
struct ChatCardTests {

    /// A proposal proposed again later, by id or by note, is decided on its
    /// newest card; the older one says it was replaced.
    @Test("A proposal a later turn replaced is marked on the earlier turn only")
    func replaced() {
        var chat = AgentChat(question: "Draft the feedback", scope: "")
        chat.turns[0].proposals = [
            .init(id: "feedback", notePath: "Paper/Feedback.md", headline: "New note"),
            .init(id: "plan", notePath: "Plan.md", headline: "Edit Plan"),
        ]
        chat.turns.append(.init(question: "Make that shorter"))
        chat.turns[1].proposals = [.init(id: "feedback", notePath: "Paper/Feedback.md", headline: "New note")]
        chat.turns.append(.init(question: "And the plan"))
        chat.turns[2].proposals = [.init(id: "plan-2", notePath: "Plan.md", headline: "Edit Plan")]
        #expect(AgentConversationView.replaced(in: chat, before: 0) == ["feedback", "plan"])
        #expect(AgentConversationView.replaced(in: chat, before: 1).isEmpty)
        #expect(AgentConversationView.replaced(in: chat, before: 2).isEmpty)
    }

    @Test("A model's title is cut to its first line, without quotes or a full stop")
    func cleaned() {
        #expect(ChatTitler.cleaned("\"Parser deadline.\"\nMore") == "Parser deadline")
        #expect(ChatTitler.cleaned("Title: Week review") == "Week review")
        #expect(ChatTitler.cleaned("  \n") == nil)
        #expect((ChatTitler.cleaned(String(repeating: "a", count: 90)) ?? "").count == 60)
    }
}

@Suite("Suggested names")
struct NameSuggesterTests {

    @Test("A model's names are cleaned into names a file can have, three at most")
    func cleaned() {
        let names = NameSuggester.cleaned("""
        1. Parser Deadline
        - "Parser: Ship Friday."
        * parser deadline
        Plan.md
        Plan
        Weekly Plan
        Fourth one
        """, current: "Plan")
        #expect(names == ["Parser Deadline", "Parser- Ship Friday", "Weekly Plan"], "got \(names)")
    }
}
