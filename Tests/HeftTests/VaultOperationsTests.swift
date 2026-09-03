import Foundation
import HeftCore
import Testing

/// The decisions that used to be `guard` statements inside `AppModel`, where
/// reaching one meant running a window. Every case below was previously only
/// observable as a sentence in the status line.
@Suite("Vault operations")
struct VaultOperationsTests {

    private func item(
        _ path: String, isFolder: Bool = false
    ) -> VaultItem {
        let name = (path as NSString).lastPathComponent
        return VaultItem(
            url: URL(fileURLWithPath: "/vault/" + path),
            relativePath: path,
            kind: isFolder ? .folder : (name.hasSuffix(".md") ? .markdown : .other),
            name: isFolder || !name.hasSuffix(".md")
                ? name
                : (name as NSString).deletingPathExtension
        )
    }

    // MARK: - Names

    @Test("A typed name keeps its shape and loses what a filesystem will not take")
    func sanitising() {
        #expect(VaultOperations.sanitise("  Meeting notes  ") == "Meeting notes")
        // Both become a dash rather than being stripped: closing the gap up
        // would give "Notes 2026", which is a different title.
        #expect(VaultOperations.sanitise("Notes: 2026") == "Notes- 2026")
        #expect(VaultOperations.sanitise("a/b") == "a-b")
        #expect(VaultOperations.sanitise("   ").isEmpty)
    }

    @Test("The extension a note is displayed without is put back")
    func markdownSuffix() {
        #expect(VaultOperations.filename(for: "Ideas", isMarkdown: true) == "Ideas.md")
        // Someone who types it anyway does not get Ideas.md.md.
        #expect(VaultOperations.filename(for: "Ideas.md", isMarkdown: true) == "Ideas.md")
        #expect(VaultOperations.filename(for: "Ideas.MD", isMarkdown: true) == "Ideas.MD")
        // An attachment is shown with its extension, so nothing is added.
        #expect(VaultOperations.filename(for: "shot.png", isMarkdown: false) == "shot.png")
        #expect(VaultOperations.filename(for: "  ", isMarkdown: true) == nil)
    }

    @Test("An untitled name counts up past the ones already taken")
    func uniqueNames() {
        let taken: Set<String> = ["Untitled.md", "Untitled 1.md", "Untitled 2.md"]
        #expect(VaultOperations.uniqueName(
            base: "Untitled", extension: "md", isTaken: { taken.contains($0) }
        ) == "Untitled 3.md")
        // A folder has no extension, and must not gain a bare dot.
        #expect(VaultOperations.uniqueName(
            base: "Untitled", extension: "", isTaken: { _ in false }
        ) == "Untitled")
    }

    // MARK: - Destinations

    @Test("A bare name keeps the item where it is")
    func bareNameStaysPut() {
        let note = item("Journal/2026-01-01.md")
        #expect(VaultOperations.destination(for: note, named: "Kickoff")
            == "Journal/Kickoff.md")
    }

    @Test("A name holding a slash is a move as well as a rename")
    func pathMoves() {
        let note = item("Journal/2026-01-01.md")
        #expect(VaultOperations.destination(for: note, named: "Archive/Kickoff")
            == "Archive/Kickoff.md")
        // A leading slash is how a person spells "from the vault root", and
        // must not produce an empty first path component.
        #expect(VaultOperations.destination(for: note, named: "/Kickoff") == "Kickoff.md")
    }

    @Test("An item at the vault root has no parent to keep it in")
    func rootItem() {
        #expect(VaultOperations.destination(for: item("Inbox.md"), named: "Capture")
            == "Capture.md")
    }

    // MARK: - Renaming

    @Test("Renaming onto an existing name is refused by that name")
    func renameCollision() {
        let note = item("Notes/A.md")
        let result = VaultOperations.planRename(note, to: "B", exists: { $0 == "Notes/B.md" })
        #expect(result == .failure(.alreadyExists(name: "B.md")))
        #expect(VaultOperations.Refusal.alreadyExists(name: "B.md").message
            == "B.md already exists")
    }

    /// Return on an unchanged field is not a failure. It has to succeed
    /// rather than refuse, or the sidebar's inline edit reports an error for
    /// the commonest way of leaving it.
    @Test("Renaming something to the name it already has succeeds and moves nothing")
    func renameToSameName() throws {
        let note = item("Notes/A.md")
        let move = try VaultOperations.planRename(
            note, to: "A", exists: { _ in Issue.record("should not be asked"); return true }
        ).get()
        #expect(move.from == move.to)
        #expect(move.to == "Notes/A.md")
    }

    @Test("An empty name is refused before anything is looked up")
    func renameEmpty() {
        let result = VaultOperations.planRename(
            item("A.md"), to: "   ",
            exists: { _ in Issue.record("should not be asked"); return false }
        )
        #expect(result == .failure(.emptyName))
    }

    // MARK: - Moving

    @Test("A move into a folder lands under it")
    func moveIntoFolder() throws {
        let move = try VaultOperations.planMove(
            "Inbox/A.md", into: "Archive", isFolder: false, exists: { _ in false }
        ).get()
        #expect(move.to == "Archive/A.md")
        #expect(move.name == "A.md")
    }

    @Test("A move into the folder it is already in is refused, not repeated")
    func moveNoOp() {
        #expect(VaultOperations.planMove(
            "Archive/A.md", into: "Archive", isFolder: false, exists: { _ in false }
        ) == .failure(.alreadyThere(name: "A.md")))
    }

    /// Ordering, not just outcome. The destination of a folder dropped onto
    /// itself *is* that folder, so testing existence first would answer
    /// "already exists" — true, and no help at all in working out what
    /// happened.
    @Test("A folder dropped into itself is refused as that, not as a collision")
    func moveIntoItself() {
        #expect(VaultOperations.planMove(
            "Projects", into: "Projects", isFolder: true, exists: { _ in true }
        ) == .failure(.intoItself(name: "Projects")))
        #expect(VaultOperations.planMove(
            "Projects", into: "Projects/Sub", isFolder: true, exists: { _ in true }
        ) == .failure(.intoItself(name: "Projects")))
    }

    /// A *note* named the same as the folder it is dropped on is not the same
    /// thing and has to keep working: only a folder can contain itself.
    @Test("A note whose name prefixes the destination still moves")
    func noteIsNotAFolder() throws {
        let move = try VaultOperations.planMove(
            "Projects", into: "Archive", isFolder: false, exists: { _ in false }
        ).get()
        #expect(move.to == "Archive/Projects")
    }

    @Test("A move to the vault root needs no leading slash")
    func moveToRoot() throws {
        let move = try VaultOperations.planMove(
            "Archive/A.md", into: "", isFolder: false, exists: { _ in false }
        ).get()
        #expect(move.to == "A.md")
    }

    @Test("Only things already in the vault may be dragged within it")
    func insideTheVault() {
        let root = URL(fileURLWithPath: "/vault")
        #expect(VaultOperations.isInside(URL(fileURLWithPath: "/vault/A.md"), vaultRoot: root))
        #expect(VaultOperations.isInside(root, vaultRoot: root))
        #expect(!VaultOperations.isInside(
            URL(fileURLWithPath: "/Downloads/A.md"), vaultRoot: root
        ))
        // A sibling folder whose name merely starts with the vault's is not
        // inside it. Without the separator this is the classic prefix bug.
        #expect(!VaultOperations.isInside(
            URL(fileURLWithPath: "/vault-backup/A.md"), vaultRoot: root
        ))
    }

    // MARK: - Summaries

    @Test("The repoint summary counts and pluralises what actually happened")
    func summaries() {
        let one = VaultRename.Summary(links: 1, notes: 1)
        #expect(VaultOperations.repointSummary(one) == "repointed 1 link in 1 note")

        let many = VaultRename.Summary(links: 4, notes: 2)
        #expect(VaultOperations.repointSummary(many) == "repointed 4 links in 2 notes")

        // Nothing repointed says nothing at all, so a caller can append it
        // unconditionally to its own message.
        #expect(VaultOperations.repointSummary(VaultRename.Summary()).isEmpty)

        let skipped = VaultRename.Summary(skipped: 1)
        #expect(VaultOperations.repointSummary(skipped)
            == "1 note changed concurrently and was left untouched")

        let both = VaultRename.Summary(links: 2, notes: 1, skipped: 2)
        #expect(VaultOperations.repointSummary(both)
            == "repointed 2 links in 1 note; 2 notes changed concurrently and were left untouched")
    }
}
