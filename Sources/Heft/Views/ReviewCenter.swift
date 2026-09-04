import HeftCore
import SwiftUI

/// Everything an agent is waiting on, at the top of the sidebar.
///
/// The per-note banner was the only way to review agent work, and two things
/// ran it out. A proposal for a note that does not exist has no note to draw a
/// banner above, so it could not be reached from the app at all. And a change
/// spanning several notes was several unrelated proposals: accepting seven of
/// twelve left the vault half-changed with nothing recording that they belonged
/// together.
///
/// At the top of the sidebar because the banner already trained the eye to look
/// near the top of the window, and because this is the one place that can show
/// a change with no note behind it.
///
/// **The banner stays.** Seeing a diff where you are reading it is the part
/// that already works, and centralising it would be a downgrade. The rule that
/// keeps the two from fighting is *one banner per note, ever*: a note whose
/// change belongs to a group gets a line saying so and a way in here, never a
/// second banner stacked on the first.
struct ReviewCenter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appAccent) private var accent
    @State private var isExpanded = true
    @State private var openGroups: Set<String> = []

    var body: some View {
        let pending = model.pendingProposals
        if !pending.isEmpty {
            VStack(spacing: 0) {
                header(pending)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(pending.groups) { group in
                            groupRow(group)
                            if openGroups.contains(group.id) {
                                ForEach(group.proposals) { proposal in
                                    row(proposal, depth: 1)
                                }
                                groupActions(group)
                            }
                        }
                        ForEach(pending.edits) { row($0, depth: 0) }
                        ForEach(pending.structural) { row($0, depth: 0) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                Divider()
            }
            .background(accent.opacity(0.06))
        }
    }

    private func header(_ pending: ProposalStore.Pending) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Waiting for Review")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(pending.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func groupRow(_ group: ProposalGroup) -> some View {
        HStack(spacing: 5) {
            Button {
                if openGroups.contains(group.id) { openGroups.remove(group.id) }
                else { openGroups.insert(group.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Text("\(group.proposals.count) changes · \(group.agent)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(openGroups.contains(group.id) ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Accept All \(group.proposals.count) Changes") { model.acceptGroup(group) }
            Button("Discard", role: .destructive) { model.discardGroup(group) }
        }
    }

    /// Accepting or discarding a whole group, under the group when it is open.
    ///
    /// These were reachable only by right-clicking the group's row, which is
    /// not an affordance: nobody found them, and the first thing a person does
    /// to a row with a chevron on it is click the row. That expands it, so this
    /// is where the eye already is.
    ///
    /// Not on the row itself. The row *is* the disclosure control, and hanging
    /// a destructive button off a control whose whole job is to toggle invites
    /// exactly the misclick it would be there to save.
    ///
    /// Accept All matters more than it looks. Applying a group is deliberately
    /// not atomic, so accepting members one at a time really can leave the
    /// vault half-changed — five new notes linking to each other, three of them
    /// created. This button is the answer to that, and it was invisible.
    private func groupActions(_ group: ProposalGroup) -> some View {
        HStack(spacing: 6) {
            // Named with its count, because "Accept All" already means
            // something else one sheet away: every *hunk* of the one proposal
            // in front of you. Two scopes under one label is a thing you only
            // learn by pressing the wrong one.
            Button("Accept All \(group.proposals.count) Changes") {
                model.acceptGroup(group)
            }
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
            Button("Discard", role: .destructive) { model.discardGroup(group) }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: 10.5))
        // Lined up with the member rows above it, which sit at depth 1.
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .padding(.top, 3)
        .padding(.bottom, 5)
    }

    private func row(_ proposal: Proposal, depth: Int) -> some View {
        Button {
            model.review(proposal)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol(for: proposal.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(proposal.kind == .delete ? Color.red : .secondary)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(proposal.summary)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Text(proposal.headline)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Review") { model.review(proposal) }
            Button("Discard", role: .destructive) { model.discard(proposal) }
        }
    }

    private func symbol(for kind: Proposal.Kind) -> String {
        switch kind {
        case .edit: "pencil"
        case .create: "doc.badge.plus"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        }
    }
}

/// The sheet for a change that has no hunks to answer.
///
/// A delete and a move happen or they do not; there is nothing to accept part
/// of. A create has a body but no note to diff it against, so what is worth
/// showing is the note itself rather than a diff whose every line is an
/// addition.
struct StructuralReviewView: View {
    let proposal: Proposal
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.summary).font(.system(size: 14, weight: .semibold))
                    Text("\(proposal.agent) · \(proposal.headline)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let group = proposal.group {
                        Text("Part of “\(group.summary)”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
            Divider()

            if proposal.kind == .create {
                ScrollView {
                    Text(proposal.body)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView(
                    proposal.headline,
                    systemImage: proposal.kind == .delete ? "trash" : "arrow.right.doc.on.clipboard",
                    description: Text(proposal.kind == .delete
                        ? "The file goes to the Trash, and Heft asks again before it does."
                        : "Every link pointing at it is repointed to the new path.")
                )
                .frame(maxHeight: .infinity)
            }

            Divider()
            // Every button says its style. Left to `.automatic`, the
            // destructive role picked a different shape from the two beside
            // it, so one footer held two corner radii.
            HStack {
                Button("Discard Proposal", role: .destructive) { model.discard(proposal) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Later") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(proposal.kind == .create ? "Create" : "Apply") {
                    if proposal.kind == .create { model.acceptAll(proposal) }
                    else { model.applyStructural(proposal) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 480)
        .onChange(of: model.reviewing) { _, reviewing in
            if reviewing == nil { dismiss() }
        }
    }
}
