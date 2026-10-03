import HeftCore
import SwiftUI

/// A chat with the reader's agent, in the search bar's place for its list.
///
/// The question, then the answer as it is written, with what the agent is
/// doing under it while it works. A proposal the answer left is a card here,
/// so it can be accepted, rejected with a word back to the agent, or opened
/// in review, without leaving the conversation that asked for it.
struct AgentConversationView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Closes the bar, after opening a note or a review.
    let onLeave: () -> Void

    var body: some View {
        if let chat = runner.chat {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(chat.turns.enumerated()), id: \.offset) { index, turn in
                            TurnView(
                                runner: runner, turn: turn,
                                isLast: index == chat.turns.count - 1,
                                onLeave: onLeave
                            )
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                // Follows the answer down as it is written, as a chat does.
                .onChange(of: chat.turns.last?.answer.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.turns.count) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: runner.isRunning) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct TurnView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    let turn: AgentChat.Turn
    let isLast: Bool
    let onLeave: () -> Void

    private var isAnswering: Bool { isLast && runner.isRunning }

    /// This turn's proposals still waiting, as they stand now.
    private var waiting: [Proposal] {
        turn.proposals.compactMap { note in model.proposals.first { $0.id == note.id } }
    }

    /// Accepts the turn's proposals together, as a group is accepted in the
    /// review centre: the text first, then moves and deletes, which would
    /// otherwise take away the file an edit was written against.
    private func acceptAll() {
        let all = waiting
        for proposal in all where !proposal.isStructural { model.acceptAll(proposal) }
        for proposal in all where proposal.isStructural { model.applyStructural(proposal) }
        for proposal in all where !model.proposals.contains(where: { $0.id == proposal.id }) {
            runner.record(.accepted, for: proposal.id)
        }
    }

    private func rejectAll() {
        for proposal in waiting {
            model.discard(proposal)
            runner.record(.rejected, for: proposal.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The question on the right, as the reader's side of a chat.
            HStack {
                Spacer(minLength: 60)
                Text(turn.question)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
            }
            if !turn.answer.isEmpty {
                AnswerText(text: turn.answer, onLeave: onLeave)
            }
            if isAnswering {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(runner.activity ?? "Thinking")
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    Spacer()
                    Button("Stop") { runner.cancel() }
                        .controlSize(.small)
                        .keyboardShortcut(".", modifiers: .command)
                }
                .font(.callout)
            }
            if let failure = turn.failure {
                FailureView(runner: runner, failure: failure, canRetry: isLast)
            }
            if waiting.count > 1 {
                HStack {
                    Text("\(waiting.count) changes").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reject All") { rejectAll() }
                    Button("Accept All") { acceptAll() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .disabled(runner.isRunning)
            }
            ForEach(turn.proposals) { note in
                ProposalCard(runner: runner, note: note, onLeave: onLeave)
            }
            if isLast, !runner.isRunning, !turn.denials.isEmpty {
                DenialsView(runner: runner, denials: turn.denials)
            }
        }
    }
}

/// The answer, with its wikilinks made into links that open the note.
private struct AnswerText: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let onLeave: () -> Void

    var body: some View {
        Text(Self.attributed(text))
            .textSelection(.enabled)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.noteScheme else { return .systemAction }
                let name = url.host(percentEncoded: false) ?? ""
                let target = name.removingPercentEncoding ?? name
                if let note = VaultIndex.match(target, among: model.index.notes) {
                    model.open(note)
                    onLeave()
                }
                return .handled
            })
    }

    static let noteScheme = "heft-note"

    /// Inline Markdown, with `[[Note]]` and `[[Note|shown]]` as links.
    static func attributed(_ text: String) -> AttributedString {
        let linked = linkingWikilinks(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }

    static func linkingWikilinks(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            result += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = (parts.first ?? "").split(separator: "#").first.map(String.init) ?? ""
            // A link written as a path shows the note's name, as the editor
            // draws it; one with its own text shows that.
            let named = (target as NSString).lastPathComponent
            let shown = parts.count > 1 ? parts[1] : (named.hasSuffix(".md") ? String(named.dropLast(3)) : named)
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
            result += target.isEmpty ? String(rest[open.lowerBound..<close.upperBound]) : "[\(shown)](\(noteScheme)://\(encoded))"
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

/// A proposal the agent left, decided here or in review.
private struct ProposalCard: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    let note: AgentChat.ProposalNote
    let onLeave: () -> Void
    @State private var showsDiff = false
    @State private var isRejecting = false
    @State private var reason = ""

    private var proposal: Proposal? { model.proposals.first { $0.id == note.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(proposal?.headline ?? note.headline).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                if let proposal {
                    if let counts = counts(proposal) {
                        Text(counts).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    Text(settledText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let proposal {
                if showsDiff, !proposal.isStructural {
                    DiffPreview(diff: proposal.diff(against: model.currentText(for: proposal)))
                }
                if isRejecting {
                    HStack(spacing: 6) {
                        TextField("Why? Optional, and goes back to the agent", text: $reason)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { reject(proposal) }
                        Button("Reject", role: .destructive) { reject(proposal) }
                        Button("Cancel") { isRejecting = false; reason = "" }
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        if !proposal.isStructural {
                            Button(showsDiff ? "Hide changes" : "Show changes") { showsDiff.toggle() }
                        }
                        Button("Review") { model.review(proposal); onLeave() }
                        Spacer()
                        Button("Reject") { isRejecting = true }
                        Button("Accept") { accept(proposal) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .disabled(runner.isRunning)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    private var symbol: String {
        switch proposal?.kind {
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .create: "doc.badge.plus"
        default: "doc.text"
        }
    }

    private var settledText: String {
        switch note.outcome {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case nil: "Settled in review"
        }
    }

    private func counts(_ proposal: Proposal) -> String? {
        guard !proposal.isStructural else { return nil }
        let diff = proposal.diff(against: model.currentText(for: proposal))
        let added = diff.hunks.reduce(0) { $0 + $1.added.count }
        let removed = diff.hunks.reduce(0) { $0 + $1.removed.count }
        return "+\(added) −\(removed)"
    }

    private func accept(_ proposal: Proposal) {
        if proposal.isStructural {
            model.applyStructural(proposal)
        } else {
            model.acceptAll(proposal)
        }
        if !model.proposals.contains(where: { $0.id == proposal.id }) {
            runner.record(.accepted, for: proposal.id)
        }
    }

    private func reject(_ proposal: Proposal) {
        model.discard(proposal)
        runner.record(.rejected, for: proposal.id)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        isRejecting = false
        reason = ""
        guard !why.isEmpty, let vaultRoot = model.vaultRoot else { return }
        runner.ask(
            "I rejected your proposal (\(proposal.headline)): \(why)",
            vaultRoot: vaultRoot, scope: runner.chat?.scope ?? ""
        )
    }
}

private struct DiffPreview: View {
    let diff: NoteDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(diff.hunks.prefix(6)) { hunk in
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, line in
                    Text("− " + line).foregroundStyle(.red)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).foregroundStyle(.green)
                }
                if hunk.id != diff.hunks.prefix(6).last?.id { Divider().padding(.vertical, 2) }
            }
            if diff.hunks.count > 6 {
                Text("and \(diff.hunks.count - 6) more").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}

/// What the agent was refused, and the reads the reader may allow.
private struct DenialsView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    let denials: [AgentDenial]

    /// A path as the reader knows it: inside the vault from its top,
    /// elsewhere from the home folder.
    private func shown(_ text: String) -> String {
        var result = text
        if let root = model.vaultRoot?.standardizedFileURL.path {
            result = result.replacingOccurrences(of: root + "/", with: "")
        }
        return result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("It was not allowed to", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            ForEach(denials, id: \.self) { denial in
                Text(shown(denial.summary))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            let folders = denials.compactMap(\.allowFolder).uniqued()
            if !folders.isEmpty {
                Button("Allow reading \(folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) and continue") {
                    runner.allow(denials)
                }
                .controlSize(.small)
                .help(folders.joined(separator: "\n"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// Why a run gave no answer, and what to do about it.
private struct FailureView: View {
    @ObservedObject var runner: AgentRunner
    @ObservedObject private var settings = GeneralSettings.shared
    let failure: String
    let canRetry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch failure {
            case "missing":
                Label("Ask runs Claude Code, which was not found", systemImage: "questionmark.circle")
                    .font(.callout.weight(.medium))
                Text("Install it, sign in once in Terminal, and ask again. Settings ▸ Search names another command.")
                    .foregroundStyle(.secondary)
                Text(Self.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            case "signedOut":
                Label("Claude Code is signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                Text("Run \(settings.agentCommand) once in Terminal to sign in, then ask again.")
                    .foregroundStyle(.secondary)
            case "Stopped":
                Text("Stopped").foregroundStyle(.secondary)
            default:
                Label("The agent stopped", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            if canRetry, failure != "Stopped" {
                Button("Try again") { runner.retry() }
                    .controlSize(.small)
                    .disabled(runner.isRunning)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
}
