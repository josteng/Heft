import HeftCore
import SwiftUI

/// Hunk-by-hunk resolution of a save conflict.
///
/// The alert behind this sheet can only answer the whole question — keep the
/// buffer or take the file — which loses one side's work whenever both changed
/// something different. The diff is the same machinery an agent proposal uses,
/// and for the same reason: another version of this note exists, and the user
/// decides it a change at a time.
///
/// Hunks are measured from the buffer, so `removed` is what the editor holds
/// and `added` is what disk says instead. Accepting a hunk therefore takes the
/// outside change, and accepting none is exactly "Keep My Changes".
struct ConflictReviewView: View {
    let conflict: SaveConflict
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    /// Which hunks take the disk version. Empty means the buffer wins
    /// throughout, which is the conservative default: nothing the user typed
    /// disappears unless they ask for it.
    @State private var accepted: Set<Int> = []

    private var diff: NoteDiff { conflict.diff() }

    private var merged: String {
        NoteDiff.apply(diff.hunks, to: conflict.mine, accepting: accepted)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if diff.isEmpty {
                ContentUnavailableView(
                    "The two versions match",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing has to be decided; saving is safe.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(diff.hunks) { hunk in
                            ConflictHunkCard(
                                hunk: hunk,
                                takesDisk: accepted.contains(hunk.id)
                            ) { takeDisk in
                                if takeDisk { accepted.insert(hunk.id) }
                                else { accepted.remove(hunk.id) }
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.trianglehead.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(conflict.noteName) changed on disk while you were editing")
                    .font(.system(size: 14, weight: .semibold))
                Text(conflict.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("Yours", systemImage: "minus")
                        .foregroundStyle(.red)
                    Label("On disk", systemImage: "plus")
                        .foregroundStyle(.green)
                    Text("\(diff.hunks.count) place(s) differ")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Keep All Mine") { accepted = [] }
                .disabled(accepted.isEmpty)
            Button("Take All From Disk") { accepted = Set(diff.hunks.map(\.id)) }
                .disabled(accepted.count == diff.hunks.count)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Merged") { model.applyMergedConflict(merged) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

/// A conflict hunk. Unlike a proposal's, its two buttons are a standing choice
/// rather than a one-shot decision: nothing is written until the whole merge is
/// saved, so every hunk has to show which way it currently leans.
private struct ConflictHunkCard: View {
    let hunk: NoteDiff.Hunk
    let takesDisk: Bool
    let choose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Keep Mine") { choose(false) }
                    .controlSize(.small)
                    .buttonStyle(takesDisk ? AnyButtonStyle(.bordered) : AnyButtonStyle(.borderedProminent))
                Button("Use Disk") { choose(true) }
                    .controlSize(.small)
                    .buttonStyle(takesDisk ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.leading.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .context)
                }
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .removed)
                        .opacity(takesDisk ? 0.4 : 1)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .added)
                        .opacity(takesDisk ? 1 : 0.4)
                }
                ForEach(Array(hunk.trailing.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .context)
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
        if hunk.isInsertion { return "Disk adds \(hunk.added.count) line(s) at line \(line)" }
        if hunk.isDeletion { return "Disk drops \(hunk.removed.count) line(s) at line \(line)" }
        return "Line \(line): \(hunk.removed.count) of yours, \(hunk.added.count) on disk"
    }
}

/// `buttonStyle` takes a concrete type, so the prominent/bordered pair cannot
/// be chosen inline with a ternary without erasing them to one type first.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
