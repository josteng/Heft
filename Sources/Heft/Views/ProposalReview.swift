import HeftCore
import SwiftUI

/// The bar that appears over the editor when an agent has proposed something
/// for the note on screen.
///
/// Above the text rather than in the toolbar: a proposal is about *this* note,
/// and a toolbar badge is a thing you learn to stop seeing.
/// Offers to teach this vault's agents to propose rather than write.
///
/// Shown once per vault, because the alternative is a feature nobody finds:
/// the verbs and the menu item existed for a while before this, and a Claude
/// Code session opened in a vault without the guide has no way to know any of
/// it is there — so it edits notes directly, which is exactly what proposals
/// exist to prevent.
struct AgentSetupBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appAccent) private var accent

    private var isRefresh: Bool {
        if case .outdated = model.agentGuideStatus { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(accent)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text(isRefresh
                     ? "This vault's agent instructions are out of date"
                     : "Let agents propose changes to this vault")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(isRefresh
                     ? "Rewrites Heft's section of CLAUDE.md and leaves the rest of the file alone."
                     : "Writes CLAUDE.md, so Claude Code proposes edits here for review instead of editing notes directly.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(isRefresh ? "Update" : "Set Up") { model.setUpAgentAccess() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button("Not Now") { model.dismissAgentSetupOffer() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ProposalBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appAccent) private var accent

    var body: some View {
        let pending = model.proposalsForCurrentNote
        if !pending.isEmpty {
            VStack(spacing: 0) {
                ForEach(pending) { proposal in
                    row(for: proposal)
                    Divider()
                }
            }
            .background(.regularMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func row(for proposal: Proposal) -> some View {
        let diff = proposal.diff(against: model.currentText(for: proposal))
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(accent)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.summary)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(proposal.agent)
                    Text("+\(diff.addedLines)").foregroundStyle(.green)
                    Text("−\(diff.removedLines)").foregroundStyle(.red)
                    Text("in \(diff.hunks.count) place\(diff.hunks.count == 1 ? "" : "s")")
                    if proposal.isStale(against: model.currentText(for: proposal)) {
                        Label("note changed since", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Review") { model.beginReview(of: proposal) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button("Discard") { model.discard(proposal) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The review sheet: every hunk the agent wants, each answered on its own.
struct ProposalReviewView: View {
    let proposal: Proposal
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    private var current: String { model.currentText(for: proposal) }
    private var diff: NoteDiff { proposal.diff(against: current) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if diff.isEmpty {
                ContentUnavailableView(
                    "Nothing left to review",
                    systemImage: "checkmark.circle",
                    description: Text("The note already reads the way \(proposal.agent) wanted.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(diff.hunks) { hunk in
                            HunkCard(hunk: hunk) { accept in
                                model.decide(proposal, hunk: hunk.id, accept: accept)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .onChange(of: model.reviewing) { _, reviewing in
            if reviewing == nil { dismiss() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.summary).font(.system(size: 14, weight: .semibold))
                Text("\(proposal.agent) · \(proposal.notePath)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if proposal.isStale(against: current) {
                    Label(
                        "The note has changed since \(proposal.agent) read it. "
                            + "The changes below are measured against the note as it is now.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Discard Proposal", role: .destructive) { model.discard(proposal) }
            Spacer()
            Button("Later") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Accept All") { model.acceptAll(proposal) }
                .keyboardShortcut(.defaultAction)
                .disabled(diff.isEmpty)
        }
        .padding(12)
    }
}

/// One change, shown the way a diff is: context in grey, the old lines struck
/// through in red, the new ones in green, with its own two buttons.
struct HunkCard: View {
    let hunk: NoteDiff.Hunk
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reject") { decide(false) }
                    .controlSize(.small)
                Button("Accept") { decide(true) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.leading.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .context)
                }
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .removed)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .added)
                }
                ForEach(Array(hunk.trailing.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .context)
                }
            }
            .padding(.vertical, 6)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 1)
        )
    }

    private var label: String {
        let line = hunk.originalRange.lowerBound + 1
        if hunk.isInsertion { return "Insert \(hunk.added.count) line(s) at line \(line)" }
        if hunk.isDeletion { return "Delete \(hunk.removed.count) line(s) at line \(line)" }
        return "Replace \(hunk.removed.count) with \(hunk.added.count) line(s) at line \(line)"
    }

    typealias Kind = DiffLine.Kind

    @ViewBuilder
    private func line(_ text: String, kind: Kind) -> some View {
        DiffLine(text: text, kind: kind)
    }
}

/// One line of a diff. Shared so a save-conflict merge and an agent proposal
/// read as the same thing, because to the user they are: another version of
/// this note, decided a hunk at a time.
struct DiffLine: View {
    enum Kind { case context, removed, added }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(kind == .removed ? "−" : kind == .added ? "+" : " ")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(marker(kind))
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(kind == .context ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(background(kind))
    }

    private func marker(_ kind: Kind) -> Color {
        switch kind {
        case .context: .secondary
        case .removed: .red
        case .added: .green
        }
    }

    private func background(_ kind: Kind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.12)
        case .added: .green.opacity(0.12)
        }
    }
}
