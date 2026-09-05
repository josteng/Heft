import Foundation
import Testing
@testable import HeftCore

/// A rebuild reads only the notes whose file changed, and still answers
/// exactly what a build from nothing would.
///
/// The vault watcher rebuilds on every event, and on an iCloud vault most
/// events change no note at all. What makes the reuse safe is that only the
/// *parse* of a note is carried over; resolution is redone against the whole
/// vault every time, which the "target appears later" case below pins down.
@Suite("Index reuse across reloads")
struct IndexReuseTests {

    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-index-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try write(text, to: root.appendingPathComponent(path)) }
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Two writes inside one clock tick would share a modification time.
    private func settle() { Thread.sleep(forTimeInterval: 0.02) }

    private func build(_ root: URL, reusing previous: VaultIndex? = nil) -> VaultIndex {
        VaultIndex.build(root: VaultScanner.scan(root: root), reusing: previous)
    }

    @Test("An unchanged vault is rebuilt without reading a note")
    func unchangedVaultReadsNothing() throws {
        let root = try makeVault(["A.md": "Links to [[B]] #tag", "B.md": "body"])
        defer { try? FileManager.default.removeItem(at: root) }

        let first = build(root)
        #expect(first.notesRead == 2)

        let second = build(root, reusing: first)
        #expect(second.notesRead == 0)
        #expect(second.backlinks(to: "B.md").count == 1)
        #expect(second.notes(taggedWith: "tag").map(\.relativePath) == ["A.md"])
    }

    /// Same length, different link: only the modification time tells.
    @Test("A note rewritten to the same size is read again")
    func sameSizeRewriteIsRead() throws {
        let root = try makeVault(["A.md": "See [[B]]", "B.md": "b", "C.md": "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = build(root)

        settle()
        try write("See [[C]]", to: root.appendingPathComponent("A.md"))
        let second = build(root, reusing: first)

        #expect(second.notesRead == 1)
        #expect(second.backlinks(to: "B.md").isEmpty)
        #expect(second.backlinks(to: "C.md").count == 1)
    }

    /// Same modification time, different length: only the size tells.
    @Test("A note that changed size under a preserved date is read again")
    func sizeChangeIsRead() throws {
        let root = try makeVault(["A.md": "See [[B]]", "B.md": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("A.md")
        // One date, set the same way both times. Reading the date back and
        // setting it again does not reproduce it to the nanosecond, which
        // would let the date do the work this test wants the size to do.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: noteURL.path)
        let first = build(root)

        try write("See [[B]] and #later", to: noteURL)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: noteURL.path)
        let second = build(root, reusing: first)

        #expect(second.notesRead == 1)
        #expect(second.notes(taggedWith: "later").count == 1)
    }

    /// The cached parse of A is a link to a name; where it points is decided
    /// per build, so the target can arrive after A was last read.
    @Test("A cached note's link resolves to a note that appeared later")
    func laterTargetResolves() throws {
        let root = try makeVault(["A.md": "Waiting for [[Later]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = build(root)
        #expect(first.backlinks(to: "Later.md").isEmpty)

        try write("here now", to: root.appendingPathComponent("Later.md"))
        let second = build(root, reusing: first)

        #expect(second.notesRead == 1, "only the new note is read")
        #expect(second.backlinks(to: "Later.md").map(\.source.relativePath) == ["A.md"])
    }

    @Test("A removed note takes its links with it")
    func removedNoteDropsItsLinks() throws {
        let root = try makeVault(["A.md": "See [[B]]", "B.md": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = build(root)
        #expect(first.backlinks(to: "B.md").count == 1)

        try FileManager.default.removeItem(at: root.appendingPathComponent("A.md"))
        let second = build(root, reusing: first)

        #expect(second.notesRead == 0)
        #expect(second.backlinks(to: "B.md").isEmpty)
    }

    /// Attachment habits come from the same cached parse, and count against
    /// the attachments present now rather than when the note was read.
    @Test("Attachment usage survives the reuse")
    func attachmentUsageIsCarried() throws {
        let root = try makeVault([
            "Notes/A.md": "![[chart.png]]",
            "Files/chart.png": "not really a picture",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = build(root)
        #expect(first.attachmentDestination(near: "Notes") == "Files")

        let second = build(root, reusing: first)
        #expect(second.notesRead == 0)
        #expect(second.attachmentDestination(near: "Notes") == "Files")
    }

    /// Nothing to fingerprint means nothing to trust.
    @Test("An item built by hand rather than scanned is always read")
    func handBuiltItemIsRead() throws {
        let root = try makeVault(["A.md": "text"])
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("A.md")
        let byHand = VaultItem(url: root, relativePath: "", kind: .folder, name: "v", children: [
            VaultItem(url: noteURL, relativePath: "A.md", kind: .markdown, name: "A"),
        ])

        // Both builds lack a fingerprint, so a match of nothing against
        // nothing is the mistake this guards against.
        let first = VaultIndex.build(root: byHand)
        #expect(first.notesRead == 1)
        #expect(VaultIndex.build(root: byHand, reusing: first).notesRead == 1)
    }

    /// The tree the sidebar shows has not changed when a file's date has.
    @Test("A scanned tree compares equal across a touched file")
    func treeEqualityIgnoresFingerprints() throws {
        let root = try makeVault(["A.md": "text"])
        defer { try? FileManager.default.removeItem(at: root) }
        let before = VaultScanner.scan(root: root)

        settle()
        try write("text", to: root.appendingPathComponent("A.md"))
        let after = VaultScanner.scan(root: root)

        #expect(before.children.first?.fingerprint != after.children.first?.fingerprint)
        #expect(before == after)
        #expect(before.hashValue == after.hashValue)
    }

    /// An evicted file cannot be read, and there is no point trying again
    /// until it changes.
    @Test("A note that could not be read is not retried while unchanged")
    func unreadableNoteIsNotRetried() throws {
        let root = try makeVault(["A.md": "fine"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Bytes that are not UTF-8, so the read fails the way an eviction does.
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: root.appendingPathComponent("Broken.md"))

        let first = build(root)
        #expect(first.notesRead == 2)
        let second = build(root, reusing: first)
        #expect(second.notesRead == 0)
    }
}
