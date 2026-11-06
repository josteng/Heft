import Foundation
import Testing
@testable import HeftCore

/// Saving on iOS goes through `NoteSync` and `NoteFile`.
@MainActor
@Suite("iOS saving")
struct IOSSavingTests {
    private func folder(under base: String) throws -> URL {
        let root = URL(fileURLWithPath: base).appendingPathComponent("heft-hunt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `MobileVault.noteURL(at:)` exactly: the index first, else
    /// `NoteRef(url:vaultRoot:)`. The index no longer has a note deleted or
    /// renamed elsewhere, so only the fallback is modelled.
    @MainActor
    final class MobileLikeVault: NoteSyncVault {
        let folder: URL
        var indexed: Set<String> = ["Note.md"]
        init(_ folder: URL) { self.folder = folder }
        var root: URL? { folder }
        func noteURL(at path: String) -> URL? {
            if indexed.contains(path) { return folder.appendingPathComponent(path) }
            return NoteRef(url: folder.appendingPathComponent(path), vaultRoot: folder)?.url
        }
        func noteWritten() {}
    }

    /// On iOS a vault is `/private/var/…`; `/private/tmp` behaves the same on
    /// the Mac. A missing note's URL keeps `/private` when standardised and
    /// the existing root loses it, so `NoteRef(url:vaultRoot:)` is nil.
    @Test("Typing into a note deleted elsewhere is asked about, not kept only in memory")
    func deletedElsewhereIsSilentlyUnsaved() async throws {
        let root = try folder(under: "/private/tmp")
        defer {
            try? FileManager.default.removeItem(at: root)
            DraftStore.discard(vault: root, relativePath: "Note.md")
        }
        let url = root.appendingPathComponent("Note.md")
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let vault = MobileLikeVault(root)
        let sync = NoteSync(path: "Note.md")
        await sync.load(in: vault)
        #expect(sync.source == "old\n")

        // Deleted (or renamed) on the Mac; the next scan drops it from the index.
        try FileManager.default.removeItem(at: url)
        vault.indexed = []
        await sync.load(in: vault)

        sync.edited("old\nmine\n")
        await sync.saveNow()

        let drafted = DraftStore.draft(vault: root, relativePath: "Note.md")
        #expect(sync.conflict || sync.saveError != nil || drafted != nil,
                "the typing was kept only in memory")
    }

    /// The Mac opens a Latin-1 note and writes it back byte for byte; the
    /// iOS editor reads through `NoteFile.read`.
    @Test("A Latin-1 note opens on iOS as it does on the Mac")
    func latin1NoteOpens() async throws {
        let root = try folder(under: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Note.md")
        try Data([0x43, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)  // "Café\n" in Latin-1
        #expect(NoteEncoding.read(url) == "Café\n")

        let read = try? NoteFile.read(url)
        #expect(read == "Café\n", "NoteFile.read refuses a Latin-1 note")
    }
}
