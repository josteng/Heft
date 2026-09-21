import Foundation

/// Rewriting a note that already exists, which Heft proposes rather than
/// writes.
///
/// Every other way in only ever adds. `capture` puts a line in the inbox,
/// `NoteAppend` puts one at the end, a create makes a note that was not
/// there: none of them can lose a line already written. A rewrite can, and
/// afterwards nothing in the file would say so.
///
/// Asking for the edit is not seeing the result. Writing Tools rewriting a
/// selection needs no proposal because the suggestion is in front of the
/// reader before it is accepted; a rewrite asked for by voice is read back
/// by nobody, and the moment it is worth asking for is the moment the note
/// is not on screen. So it goes to the review centre with the note's current
/// text as the base, which is a diff to read and one click to take or drop.
public enum NoteUpdate {

    /// Nil when the rewrite is the text that is already there: an empty diff
    /// is a row in the review centre that wastes a decision.
    @discardableResult
    public static func propose(
        _ newText: String, to relativePath: String, in vaultRoot: URL, agent: String
    ) throws -> Proposal? {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard let base = try? String(contentsOf: url, encoding: .utf8) else {
            throw NoteAppend.Failure.missing(relativePath)
        }
        guard newText != base else { return nil }

        let name = ((relativePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let proposal = Proposal(
            notePath: relativePath,
            // The text it was written against, so the review centre can say
            // the note moved underneath rather than quietly clobbering an
            // edit made between the asking and the accepting.
            base: base,
            body: newText,
            agent: agent,
            summary: "Rewrote \(name)",
            kind: .edit
        )
        try ProposalStore.write(proposal, in: vaultRoot)
        // The asking happens in another process, so the window is told at
        // once rather than waiting on the file watcher.
        VaultContentChangeNotification.post(for: vaultRoot)
        return proposal
    }
}
