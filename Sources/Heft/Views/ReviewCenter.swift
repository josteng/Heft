import HeftCore
import SwiftUI

/// The Mac's review card, fed from `AppModel`, with the offer to set the
/// vault up for agents in the same slot.
struct ReviewCenter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // A proposal in a vault with no guide means an agent is already at
        // work here without instructions, which is the case the setup
        // exists for; the offer is gone for good after Set Up or Not Now.
        // Above the review panel, which docks on the calendar.
        if model.shouldOfferAgentSetup {
            AgentSetupOffer()
        }
        ReviewCard(
            pending: model.pendingProposals,
            review: { model.review($0) },
            discard: { model.discard($0) },
            acceptGroup: { model.acceptGroup($0) },
            discardGroup: { model.discardGroup($0) }
        )
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
        // The same card as the review list above it, for the same reason.
        .background(accent.opacity(0.08), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
