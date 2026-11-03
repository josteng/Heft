import HeftCore
import SwiftUI

/// What agents are waiting on, at the top of the phone's Recent; the iPad
/// has the Mac's card at the foot of its sidebar instead. The place
/// for a change with no note to show a banner over, and for a change across
/// several notes. A row opens the review; a swipe accepts or discards it
/// whole.
struct ReviewSection: View {
    @Environment(MobileVault.self) private var vault
    /// A group about to be accepted that deletes files, asked about once.
    @State private var confirming: ProposalGroup?

    var body: some View {
        let review = vault.review
        let pending = review.pendingProposals
        if !pending.isEmpty {
            Section {
                ForEach(pending.groups) { group in
                    DisclosureGroup {
                        ForEach(group.proposals) { row($0) }
                        // Named with its count: "Accept All" in the review
                        // means every hunk of one proposal.
                        Button("Accept All \(group.proposals.count) Changes", systemImage: "checkmark") {
                            accept(group)
                        }
                        // Red symbol and all: the role colours the words, and
                        // the list's tint was left on the symbol.
                        Button("Discard All", systemImage: "xmark", role: .destructive) {
                            review.discardGroup(group)
                        }
                        .tint(.red)
                    } label: {
                        ProposalGroupLabel(group: group)
                    }
                }
                ForEach(pending.edits) { row($0) }
                ForEach(pending.structural) { row($0) }
            } header: {
                Label("Waiting for Review", systemImage: "sparkles")
            }
            .confirmationDialog(
                confirming.flatMap(ReviewQuestion.deletes(in:))?.title ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { group in
                Button("Delete", role: .destructive) { review.acceptGroup(group) }
            } message: { group in
                Text(ReviewQuestion.deletes(in: group)?.message ?? "")
            }
        }
    }

    private func row(_ proposal: Proposal) -> some View {
        let review = vault.review
        return Button {
            Task { await review.begin(proposal) }
        } label: {
            ProposalRowLabel(proposal: proposal)
        }
        // Accepted whole from the list only where nothing goes: a delete or
        // a move is carried out from its review, whose button names the act.
        .swipeActions(edge: .leading) {
            if !proposal.isStructural {
                Button("Accept", systemImage: "checkmark") {
                    Task {
                        await NoteDocument.saveOpen(proposal.notePath)
                        review.acceptAll(proposal)
                    }
                }
                .tint(vault.appearance.appTint ?? .accentColor)
            }
        }
        // Destructive, as a rejected hunk is: a discarded proposal cannot
        // be had back.
        .swipeActions(edge: .trailing) {
            Button("Discard", systemImage: "xmark", role: .destructive) { review.discard(proposal) }
                .tint(.red)
        }
        .contextMenu {
            Button("Review", systemImage: "eye") { Task { await review.begin(proposal) } }
            Button("Discard", systemImage: "xmark", role: .destructive) { review.discard(proposal) }
        }
    }

    /// Asked once before a group that deletes files, as on the Mac; one
    /// that deletes nothing is accepted at once.
    private func accept(_ group: ProposalGroup) {
        if ReviewQuestion.deletes(in: group) != nil {
            confirming = group
        } else {
            Task {
                for proposal in group.proposals { await NoteDocument.saveOpen(proposal.notePath) }
                vault.review.acceptGroup(group)
            }
        }
    }
}

/// The Mac's review card at the foot of the iPad's sidebar, shared, over
/// the iOS review. Accepting a group that deletes files asks once first.
struct PadReviewCard: View {
    /// How far the month's card is laid over the panel's foot.
    var tuckedUnder: CGFloat = 0
    @Environment(MobileVault.self) private var vault
    @State private var confirming: ProposalGroup?

    var body: some View {
        let review = vault.review
        ReviewCard(
            pending: review.pendingProposals,
            review: { proposal in Task { await review.begin(proposal) } },
            discard: { review.discard($0) },
            acceptGroup: accept,
            discardGroup: { review.discardGroup($0) },
            tuckedUnder: tuckedUnder
        )
        .confirmationDialog(
            confirming.flatMap(ReviewQuestion.deletes(in:))?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { group in
            Button("Delete", role: .destructive) { review.acceptGroup(group) }
        } message: { group in
            Text(ReviewQuestion.deletes(in: group)?.message ?? "")
        }
    }

    private func accept(_ group: ProposalGroup) {
        if ReviewQuestion.deletes(in: group) != nil {
            confirming = group
        } else {
            Task {
                for proposal in group.proposals { await NoteDocument.saveOpen(proposal.notePath) }
                vault.review.acceptGroup(group)
            }
        }
    }
}

/// The review of whichever proposal is open, in a sheet over the app: the
/// Mac's review, shared, sized for a phone.
struct ReviewSheet: View {
    @Environment(MobileVault.self) private var vault

    var body: some View {
        let review = vault.review
        // Read from the review rather than handed in: a decided hunk makes
        // the proposal smaller under the same id, and the sheet shows that.
        if let proposal = review.reviewing {
            Group {
                if proposal.isStructural || proposal.kind == .create {
                    StructuralReviewSheet(
                        proposal: proposal,
                        daily: vault.dailyNotes,
                        apply: {
                            if proposal.kind == .create { review.acceptAll(proposal) }
                            else { review.applyStructural(proposal, confirmed: true) }
                        },
                        discard: { review.discard(proposal) },
                        later: { review.reviewing = nil }
                    )
                } else {
                    ProposalReviewSheet(
                        proposal: proposal,
                        current: review.currentText(for: proposal),
                        group: review.group(of: proposal),
                        decide: { review.decide(proposal, hunk: $0, accept: $1) },
                        acceptAll: { review.acceptAll(proposal) },
                        discard: { review.discard(proposal) },
                        later: { review.reviewing = nil }
                    )
                }
            }
            .presentationDragIndicator(.visible)
            .environment(\.reviewAccent, vault.appearance.appTint ?? .accentColor)
        }
    }
}

extension View {
    /// The review sheet, and what went wrong carrying a decision out.
    func reviewSheet(_ vault: MobileVault) -> some View {
        @Bindable var review = vault.review
        return sheet(item: $review.reviewing) { _ in ReviewSheet() }
            .alert("Couldn't Apply the Change", isPresented: Binding(
                get: { review.problem != nil }, set: { if !$0 { review.problem = nil } }
            )) {
                Button("OK") { review.problem = nil }
            } message: {
                Text(review.problem ?? "")
            }
    }
}
