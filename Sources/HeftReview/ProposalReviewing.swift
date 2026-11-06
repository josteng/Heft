import Foundation
import HeftCore

/// What reviewing an agent's proposals asks of an app, and the decisions made
/// on top of it, so the Mac and iOS settle a proposal the same way.
///
/// An app supplies the few things that differ: where the note's text is
/// right now (the Mac's open buffer, iOS's file once typing is saved), how an
/// accepted text reaches the note, and how a file is deleted or moved. The
/// rest, which hunks are kept, what is left as a smaller proposal, and in
/// which order a group is applied, is the extension below.
@MainActor
protocol ProposalReviewing: AnyObject {
    /// The vault the proposals are kept in, `.heft/proposals/` under it.
    var proposalVaultRoot: URL? { get }
    /// The proposal whose review is open.
    var reviewing: Proposal? { get set }
    /// Everything waiting, sorted the way the review list shows it.
    var pendingProposals: ProposalStore.Pending { get }
    /// The note a proposal is about, as it stands right now.
    func currentText(for proposal: Proposal) -> String
    /// Reads the proposals again after one was settled.
    func refreshProposals()
    /// Writes an accepted text, making the folders a new note needs.
    /// `original` is the note as the decision was made against it, nil for
    /// a new note; a note found holding something else is refused. Throws
    /// when the text did not reach the note, so the proposal is kept.
    func writeAccepted(_ text: String, to relativePath: String, replacing original: String?) throws
    /// Tells the reader what a decision did, or, as a problem, why it could
    /// not.
    func reportReview(_ message: String, isProblem: Bool)
    /// Counts a review as attention paid to the note.
    func recordReview(of proposal: Proposal)
    /// Carries out a delete or a move; true once the file has gone or moved.
    func carryOut(_ proposal: Proposal, confirmed: Bool) -> Bool
    /// One question for every file a group would delete; true to go ahead.
    func confirmDeletes(in group: ProposalGroup) -> Bool
    /// Shows the note at `relativePath`, which a review just changed.
    func openReviewed(_ relativePath: String)
    /// Whether accepting opens the note, as the reader has it set.
    var opensReviewedNotes: Bool { get }
}

extension ProposalReviewing {
    /// The group a proposal belongs to, if it belongs to one.
    ///
    /// One banner per note, ever: if the change is part of something larger,
    /// the banner says so and points at the list rather than a second banner
    /// appearing above it.
    func group(of proposal: Proposal) -> ProposalGroup? {
        guard let id = proposal.group?.id else { return nil }
        return pendingProposals.groups.first { $0.id == id }
    }

    /// Accepts or rejects one hunk. Either way the proposal is rewritten to
    /// hold only what is still undecided, so a half-reviewed proposal is a
    /// smaller proposal rather than a lost one.
    func decide(_ proposal: Proposal, hunk: Int, accept: Bool) {
        guard let root = proposalVaultRoot else { return }
        if accept, let refusal = refusal(of: proposal, in: root) {
            return reportReview(refusal, isProblem: true)
        }
        recordReview(of: proposal)
        let before = currentText(for: proposal)
        do {
            // Written before the proposal is settled: a hunk that never
            // reached the note must still be waiting.
            if accept {
                let diff = proposal.diff(against: before)
                let text = NoteDiff.apply(diff.hunks, to: before, accepting: [hunk])
                try writeAccepted(text, to: proposal.notePath, replacing: proposal.kind == .create ? nil : before)
            }
            let outcome = try ProposalStore.settle(
                proposal,
                currentText: before,
                accepted: accept ? [hunk] : [],
                rejected: accept ? [] : [hunk],
                in: root
            )
            reviewing = outcome.remaining
            refreshProposals()
            // The last change decided, with an accept: the note, changed.
            if accept, outcome.remaining == nil { openAccepted(proposal.notePath) }
            reportReview(accept
                ? "Applied one change to \(proposal.noteName)"
                : "Rejected one change to \(proposal.noteName)", isProblem: false)
        } catch {
            reportReview("Could not update the proposal: \(error.localizedDescription)", isProblem: true)
        }
    }

    /// `opening` is false inside a group, which changes several notes and
    /// opens none of them.
    func acceptAll(_ proposal: Proposal, opening: Bool = true) {
        guard let root = proposalVaultRoot else { return }
        if let refusal = refusal(of: proposal, in: root) {
            return reportReview(refusal, isProblem: true)
        }
        recordReview(of: proposal)
        let before = currentText(for: proposal)
        do {
            try writeAccepted(proposal.body, to: proposal.notePath,
                              replacing: proposal.kind == .create ? nil : before)
        } catch {
            return reportReview("Could not write \(proposal.noteName): \(error.localizedDescription)", isProblem: true)
        }
        ProposalStore.remove(proposal.id, in: root)
        reviewing = nil
        refreshProposals()
        if opening { openAccepted(proposal.notePath) }
        let diff = proposal.diff(against: before)
        reportReview("Applied \(diff.hunks.count) change(s) to \(proposal.noteName)", isProblem: false)
    }

    /// Why accepting `proposal` would write somewhere it must not, or
    /// nil. Each is kept for the reader to reject: a path outside the
    /// vault, which only a hand-written proposal file can hold; a new note
    /// whose path has been taken since, by a note it would replace whole;
    /// and an edit to a note renamed or deleted since, which would bring it
    /// back under its old name.
    func refusal(of proposal: Proposal, in root: URL) -> String? {
        let parts = proposal.notePath.split(separator: "/")
        guard !proposal.notePath.hasPrefix("/"), !parts.contains("..") else {
            return "\(proposal.noteName) is outside the vault, so it was not written."
        }
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(proposal.notePath).path)
        if proposal.kind == .create, exists {
            return "\(proposal.noteName) exists now, and accepting would replace it. Reject this and ask again."
        }
        if proposal.kind == .edit, !exists {
            return "\(proposal.noteName) was renamed or deleted since this was proposed."
        }
        return nil
    }

    /// Carries out a proposal that is not an edit.
    ///
    /// A create is already an edit with no note behind it, the same write
    /// path, which makes the folders it needs, so only delete and move are
    /// here. Both are answered whole: there are no hunks in "remove this
    /// file". The proposal is settled only once the file really went: a
    /// proposal dropped after a refusal would look like it had been applied.
    func applyStructural(_ proposal: Proposal, confirmed: Bool = false, opening: Bool = true) {
        guard let root = proposalVaultRoot, proposal.kind == .delete || proposal.kind == .move,
              carryOut(proposal, confirmed: confirmed)
        else { return }
        recordReview(of: proposal)
        ProposalStore.remove(proposal.id, in: root)
        reviewing = nil
        refreshProposals()
        // A moved note, where it went; a deleted one has nothing to show.
        if opening, proposal.kind == .move, let destination = proposal.destination { openAccepted(destination) }
    }

    /// Opens what a review changed, unless the reader turned it off.
    func openAccepted(_ relativePath: String) {
        guard opensReviewedNotes else { return }
        openReviewed(relativePath)
    }

    /// Accepts every proposal in a group, in an order that cannot trip over
    /// itself: the edits first, then the moves and deletes.
    ///
    /// A move renames the file every edit in the group was written against,
    /// so applying it first would leave the rest pointing at a path that is
    /// no longer there. Not atomic: refusing eleven changes because the
    /// twelfth is stale is worse than a half-applied group, and what is left
    /// unanswered stays in the list as a smaller change.
    func acceptGroup(_ group: ProposalGroup) {
        // Asked once, before anything is applied. Cancelling here cancels the
        // whole group rather than leaving its edits in and its deletes out.
        guard confirmDeletes(in: group) else { return }
        for proposal in group.proposals where !proposal.isStructural {
            acceptAll(proposal, opening: false)
        }
        for proposal in group.proposals where proposal.isStructural {
            applyStructural(proposal, confirmed: true, opening: false)
        }
        reportReview("Applied \(group.summary)", isProblem: false)
    }

    func discardGroup(_ group: ProposalGroup) {
        guard let root = proposalVaultRoot else { return }
        for proposal in group.proposals {
            ProposalStore.remove(proposal.id, in: root)
        }
        reviewing = nil
        refreshProposals()
        reportReview("Discarded \(group.summary)", isProblem: false)
    }

    func discard(_ proposal: Proposal) {
        guard let root = proposalVaultRoot else { return }
        ProposalStore.remove(proposal.id, in: root)
        reviewing = nil
        refreshProposals()
        reportReview("Discarded \(proposal.agent)'s proposal for \(proposal.noteName)", isProblem: false)
    }
}

enum ReviewQuestion {
    /// The names a group would delete, for the one question asked before it.
    /// Listed, not just counted: "Delete 4 files?" is not something anyone
    /// can answer. Long lists are cut, since a question that scrolls is worse
    /// than one that says how much it is not showing.
    static func deletes(in group: ProposalGroup) -> (title: String, message: String)? {
        let names = group.proposals
            .filter { $0.kind == .delete }
            .map { ($0.notePath as NSString).lastPathComponent }
        guard !names.isEmpty else { return nil }
        guard names.count > 1 else {
            return ("Delete \(names[0])?", "It will be moved to the Trash.")
        }
        let listed = names.count <= 8
            ? names.joined(separator: "\n")
            : names.prefix(7).joined(separator: "\n") + "\nand \(names.count - 7) more"
        return ("Delete \(names.count) files?", "They will be moved to the Trash.\n\n\(listed)")
    }
}
