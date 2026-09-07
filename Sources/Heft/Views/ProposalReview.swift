import HeftCore
import SwiftUI

/// The bar that appears over the editor when an agent has proposed something
/// for the note on screen.
///
/// Above the text rather than in the toolbar: a proposal is about *this* note,
/// and a toolbar badge is a thing you learn to stop seeing.
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
                    // One banner per note, ever. A change that is part of
                    // something larger says so here rather than putting a
                    // second banner above this one.
                    if let group = model.group(of: proposal) {
                        Text("· part of “\(group.summary)”, \(group.proposals.count) changes")
                            .lineLimit(1)
                    }
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
                if let group = model.group(of: proposal) {
                    Text("Part of “\(group.summary)”, \(group.proposals.count) changes. "
                        + "The rest are in the sidebar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
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

    /// Every button says its style. Left to `.automatic`, the destructive role
    /// picked a different shape from the two beside it, so one footer held two
    /// corner radii.
    private var footer: some View {
        HStack {
            Button("Discard Proposal", role: .destructive) { model.discard(proposal) }
                .buttonStyle(.bordered)
            Spacer()
            Button("Later") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button("Accept All") { model.acceptAll(proposal) }
                .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Accept") { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))

            VStack(alignment: .leading, spacing: 0) {
                // Computed once for the card rather than per line: the two
                // sides are paired, so asking a line on its own what changed
                // would mean running the comparison twice for every pair.
                let inline = InlineDiff.spans(removed: hunk.removed, added: hunk.added)
                ForEach(Array(hunk.leading.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .context)
                }
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { index, text in
                    line(text, kind: .removed, spans: inline.removed[index])
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { index, text in
                    line(text, kind: .added, spans: inline.added[index])
                }
                ForEach(Array(hunk.trailing.enumerated()), id: \.offset) { _, text in
                    line(text, kind: .context)
                }
            }
            .padding(.vertical, 6)
        }
        .background(.background.secondary)
        // One rounded container with square content inside, rather than
        // rounded bands nested in a rounded card. Clipped rather than merely
        // backed by the shape, or a full-width row's corner sits outside it.
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 1)
        )
    }

    private var label: String { hunk.reviewLabel }

    typealias Kind = DiffLine.Kind

    @ViewBuilder
    private func line(
        _ text: String, kind: Kind, spans: [InlineDiff.Span]? = nil
    ) -> some View {
        DiffLine(text: text, kind: kind, spans: spans)
    }
}

/// One line of a diff. Shared so a save-conflict merge and an agent proposal
/// read as the same thing, because to the user they are: another version of
/// this note, decided a hunk at a time.
struct DiffLine: View {
    enum Kind { case context, removed, added }

    let text: String
    let kind: Kind
    /// Which words moved, when this line was compared with its counterpart.
    /// Nil where there was nothing to compare it against, or where the two
    /// lines had too little in common to mark up honestly.
    var spans: [InlineDiff.Span]?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(kind == .removed ? "−" : kind == .added ? "+" : " ")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(marker(kind))
            Text(marked)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(kind == .context ? .secondary : .primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(background(kind))
    }

    /// The line, with the words that moved carrying a stronger tint than the
    /// line's own.
    ///
    /// One `AttributedString` rather than concatenated `Text` runs: a line
    /// broken into views breaks selection and wrapping with it, and a diff
    /// line is something people copy out.
    private var marked: AttributedString {
        guard let spans, kind != .context else {
            return AttributedString(text.isEmpty ? " " : text)
        }
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if span.changed { piece.backgroundColor = emphasis(kind) }
            result.append(piece)
        }
        return result
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
        case .removed: .red.opacity(0.10)
        case .added: .green.opacity(0.10)
        }
    }

    /// The word-level tint, over the line's own. Strong enough to find at a
    /// glance and weak enough to read black text through, which rules out the
    /// full-strength colour the markers use.
    private func emphasis(_ kind: Kind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.40)
        case .added: .green.opacity(0.40)
        }
    }
}
