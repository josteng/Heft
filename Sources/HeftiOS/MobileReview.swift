import Foundation
import HeftCore
import Observation

/// The agent proposals waiting in the vault, reviewed on the phone as on
/// the Mac: the decisions are `ProposalReviewing`'s, shared with the Mac,
/// and this supplies iOS's way of reading, writing, deleting and moving.
///
/// The proposals are the files the Mac's `heft propose` writes into
/// `.heft/proposals/` in the vault, which iCloud brings here like any note;
/// there is no store of their own.
@MainActor @Observable
final class MobileReview: ProposalReviewing {
    private(set) var proposals: [Proposal] = []
    private(set) var pendingProposals = ProposalStore.Pending()
    /// The proposal whose review sheet is open.
    var reviewing: Proposal?
    /// Why the last decision could not be carried out; what one did is
    /// seen in the list and the note, with no status bar to say it in.
    var problem: String?

    @ObservationIgnored weak var vault: MobileVault?
    #if DEBUG
    @ObservationIgnored private var launchReviewOpened = false
    #endif

    var proposalVaultRoot: URL? { vault?.root }

    /// The proposals for one note that its banner can decide: a move or a
    /// delete is a fact about the tree, and offering to delete the page
    /// being read belongs in the list, not over the text.
    func banner(for path: String) -> [Proposal] {
        proposals.filter { $0.notePath == path && !$0.isStructural }
    }

    /// Opens a proposal's review once any typing in its note is written,
    /// so what the hunks are measured against is the file as it is now.
    func begin(_ proposal: Proposal) async {
        await NoteDocument.saveOpen(proposal.notePath)
        reviewing = proposal
    }

    func refreshProposals() {
        guard let root = proposalVaultRoot else {
            proposals = []
            pendingProposals = ProposalStore.Pending()
            reviewing = nil
            return
        }
        Self.fetchMissing(in: root)
        let found = ProposalStore.all(in: root)
        guard found != proposals else { return }
        proposals = found
        pendingProposals = ProposalStore.sort(found)
        #if DEBUG
        // `HEFT_IOS_REVIEW=<note path>` opens the review of that note's
        // proposal once the proposals are read.
        if !launchReviewOpened, let path = ProcessInfo.processInfo.environment["HEFT_IOS_REVIEW"],
           let proposal = found.first(where: { $0.notePath == path }) {
            launchReviewOpened = true
            reviewing = proposal
            answerAtLaunch(proposal)
        }
        #endif
        if let open = reviewing {
            // Kept in step with its file, which a decision on the Mac can
            // have made smaller, or answered whole.
            reviewing = found.first { $0.id == open.id }
        }
    }

    #if DEBUG
    /// `HEFT_IOS_REVIEW_ANSWER` answers the review `HEFT_IOS_REVIEW`
    /// opened, as its buttons would, a moment after it shows:
    /// `accept:<hunk>`, `reject:<hunk>`, `all`, or `apply` for a create,
    /// delete or move.
    private func answerAtLaunch(_ proposal: Proposal) {
        guard let answer = ProcessInfo.processInfo.environment["HEFT_IOS_REVIEW_ANSWER"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            let parts = answer.split(separator: ":").map(String.init)
            switch parts.first {
            case "accept", "reject":
                guard parts.count == 2, let hunk = Int(parts[1]) else { return }
                decide(proposal, hunk: hunk, accept: parts[0] == "accept")
            case "all": acceptAll(proposal)
            case "apply": applyStructural(proposal, confirmed: true)
            default: break
            }
        }
    }
    #endif

    /// Asks iCloud for proposals it has listed but not yet brought down:
    /// until then they are `.name.json.icloud` placeholders, which nothing
    /// can read, and the next rescan finds them arrived.
    private static func fetchMissing(in root: URL) {
        let folder = ProposalStore.directory(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".json.icloud") {
            let real = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
        }
    }

    /// The note's file. Typing is written before a review begins and the
    /// open note is covered by the review while it lasts, so the file is
    /// what the reader last saw.
    func currentText(for proposal: Proposal) -> String {
        guard let url = proposalVaultRoot?.appendingPathComponent(proposal.notePath) else { return "" }
        return (try? MobileVault.read(url)) ?? ""
    }

    /// Through a file coordinator, as every write here goes, keeping the
    /// note's encoding as the Mac does, and then a rescan, on which an open
    /// note reads itself again.
    func writeAccepted(_ text: String, to relativePath: String) {
        guard let root = proposalVaultRoot else { return }
        let url = root.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            var coordinationError: NSError?
            var result: Result<Void, Error> = .success(())
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
                result = Result { try text.writeNote(to: coordinated) }
            }
            if let coordinationError { throw coordinationError }
            try result.get()
            vault?.noteWritten()
        } catch {
            problem = "Could not write \(relativePath): \(error.localizedDescription)"
        }
    }

    func reportReview(_ message: String, isProblem: Bool) {
        if isProblem { problem = message }
    }

    /// Nothing to count here: the Mac's attention ranking is its own.
    func recordReview(of proposal: Proposal) {}

    /// The same delete and move the reader's own menu does, which repoint
    /// links and follow pins as on the Mac. The review's own button is the
    /// confirmation, so nothing asks again.
    func carryOut(_ proposal: Proposal, confirmed: Bool) -> Bool {
        guard let vault else { return false }
        do {
            switch proposal.kind {
            case .delete:
                try vault.delete(proposal.notePath)
            case .move:
                guard let destination = proposal.destination else {
                    problem = "That move names nowhere to go"
                    return false
                }
                _ = try vault.move(proposal.notePath, to: destination)
            case .edit, .create:
                return false
            }
            return true
        } catch {
            // Kept, not dropped: a pending change thrown away because the
            // file could not be found is the failure review exists to avoid.
            problem = error.localizedDescription
            return false
        }
    }

    /// Asked by the list before it accepts a group, where a dialog can wait
    /// for an answer; by the time a group is accepted it has been given.
    func confirmDeletes(in group: ProposalGroup) -> Bool { true }
}
