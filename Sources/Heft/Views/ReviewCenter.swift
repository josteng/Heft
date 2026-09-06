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
        // The offer to set the vault up lives in this slot too, under the
        // list when there is one: a proposal in a vault with no guide means
        // an agent is already at work here without instructions, which is
        // the case the setup exists for, and the offer is gone for good
        // after Set Up or Not Now. It used to be a banner over the note,
        // which a half-width window truncated and which competed with the
        // text someone had come to read.
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
        if model.shouldOfferAgentSetup {
            AgentSetupOffer()
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
            MenuButton("Accept All \(group.proposals.count) Changes", symbol: "checkmark") {
                model.acceptGroup(group)
            }
            MenuButton("Discard", symbol: "xmark", role: .destructive) {
                model.discardGroup(group)
            }
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
            MenuButton("Review", symbol: "eye") { model.review(proposal) }
            MenuButton("Discard", symbol: "xmark", role: .destructive) {
                model.discard(proposal)
            }
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
                    description: Text(structuralDescription)
                )
                .frame(maxHeight: .infinity)
            }

            // Above the buttons rather than in the description, which is the
            // same grey the standard sentence is: a consequence written in
            // the same ink as the explanation is read as more explanation.
            if let warning = ReviewWarning.dailyDeparture(
                kind: proposal.kind, notePath: proposal.notePath,
                destination: proposal.destination, daily: model.dailyNotes
            ) {
                WarningBand(text: warning)
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
                // The button says the act, and is the *only* time it is
                // asked. This sheet has already named the file and described
                // what happens to it, so the alert that used to follow was a
                // second question about a decision just made deliberately —
                // the same thing that made a group of deletes ask four times.
                //
                // Which is why the label cannot stay "Apply": with no alert
                // behind it, this press is the whole commitment, and "Move to
                // Trash" is what it commits to. It also has to read clearly
                // against "Discard Proposal" beside it, which throws the
                // request away rather than carrying it out.
                Button(applyLabel) {
                    if proposal.kind == .create { model.acceptAll(proposal) }
                    else { model.applyStructural(proposal, confirmed: true) }
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

    private var structuralDescription: String {
        proposal.kind == .delete
            ? "The file is moved to the Trash."
            : "Every link pointing at it is repointed to the new path."
    }

    private var applyLabel: String {
        switch proposal.kind {
        case .create: "Create"
        case .delete: "Move to Trash"
        case .move: "Move"
        case .edit: "Apply"
        }
    }
}

/// Whether a proposal costs something the reader would not expect from its
/// summary, and what to say about it.
///
/// A value rather than a line of view code, so what raises a warning is
/// decided in one place and can be asked about without a window.
enum ReviewWarning {
    /// A move that takes a note out of the folder the calendar looks in.
    /// Deleting one is not this: a delete says what it is.
    static func dailyDeparture(
        kind: Proposal.Kind, notePath: String, destination: String?, daily: DailyNotes?
    ) -> String? {
        guard kind == .move, let daily, let destination,
              daily.leavesDailyFolder(notePath, movingTo: destination)
        else { return nil }
        return daily.departureNote(count: 1)
    }
}

/// A consequence worth stopping at, in the ink macOS uses for a caution:
/// enough to catch the eye above the button that carries it out, without
/// the alarm of a destructive red.
private struct WarningBand: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        // The same inset all round as the footer below it keeps, so the band
        // sits in the panel rather than against its divider.
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// The offer to teach this vault's agents to propose rather than write,
/// shown once per vault in the review centre's slot. Not Now is remembered
/// for the vault; the General pane can switch the offer off altogether.
struct AgentSetupOffer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appAccent) private var accent
    @State private var isHelpPresented = false

    private var isRefresh: Bool {
        if case .outdated = model.agentGuideStatus { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(isRefresh ? "Agent instructions out of date" : "Let agents propose changes")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                // A question mark rather than a tooltip: a hover hint on
                // plain text is found by accident or not at all, and what
                // the setup writes deserves more than one line.
                Button { isHelpPresented.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What Set Up writes, and how to start an agent here")
                .popover(isPresented: $isHelpPresented, arrowEdge: .trailing) { help }
            }
            Text(isRefresh
                 ? "Rewrites Heft's section of CLAUDE.md and AGENTS.md and leaves the rest of each file alone."
                 : "Writes CLAUDE.md and AGENTS.md, so the agent you bring proposes edits here instead of editing notes.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                // No `fixedSize(vertical: true)` here: the split view probes
                // its sidebar at zero width for a minimum, a text fixed
                // vertically answers with one character per line, and that
                // becomes the window's minimum height, taller than a screen.
            HStack(spacing: 6) {
                Button(isRefresh ? "Update" : "Set Up") { model.setUpAgentAccess() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Button("Not Now") { model.dismissAgentSetupOffer() }
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Set Up writes")
                .font(.headline)
            Text("CLAUDE.md and AGENTS.md at the top of the vault, carrying Heft's instructions: "
                + "read through the heft command's index, and propose changes for review here "
                + "instead of editing notes. Anything already in those files is kept.")
            Text("A .claude/settings.json beside them holds Claude Code to the rule: it denies "
                + "direct edits to notes in this vault and allows the heft command without asking. "
                + "Other agents follow the same instructions on their honour.")
            Text("Then start your agent in a terminal at the vault's folder, as you would in a "
                + "project; it reads the instructions from there. Written for Claude Code and "
                + "tested with it; any agent that reads AGENTS.md gets the same guide.")
        }
        .font(.system(size: 11))
        .frame(width: 320, alignment: .leading)
        .padding(14)
    }
}
