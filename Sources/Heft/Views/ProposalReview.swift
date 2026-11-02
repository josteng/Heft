import HeftCore
import SwiftUI

// The Mac's side of the review: the shared views in `HeftReview`, fed from
// `AppModel`, which redraws them as it publishes.

/// The bar over the editor when an agent has proposed something for the note
/// on screen.
struct ProposalBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ProposalBannerCard(
            items: model.proposalsForCurrentNote.map { ProposalBannerItem($0, in: model) },
            review: { model.beginReview(of: $0) },
            discard: { model.discard($0) }
        )
    }
}

/// The review sheet for an edit.
struct ProposalReviewView: View {
    let proposal: Proposal
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ProposalReviewSheet(
            proposal: proposal,
            current: model.currentText(for: proposal),
            group: model.group(of: proposal),
            decide: { model.decide(proposal, hunk: $0, accept: $1) },
            acceptAll: { model.acceptAll(proposal) },
            discard: { model.discard(proposal) },
            later: { dismiss() }
        )
        .onChange(of: model.reviewing) { _, reviewing in
            if reviewing == nil { dismiss() }
        }
    }
}

/// The review sheet for a create, a delete or a move.
struct StructuralReviewView: View {
    let proposal: Proposal
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StructuralReviewSheet(
            proposal: proposal,
            daily: model.dailyNotes,
            apply: {
                if proposal.kind == .create { model.acceptAll(proposal) }
                else { model.applyStructural(proposal, confirmed: true) }
            },
            discard: { model.discard(proposal) },
            later: { dismiss() }
        )
        .onChange(of: model.reviewing) { _, reviewing in
            if reviewing == nil { dismiss() }
        }
    }
}
