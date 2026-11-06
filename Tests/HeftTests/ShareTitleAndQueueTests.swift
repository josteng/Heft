import Foundation
import Testing
@testable import HeftCore
@testable import HeftiOSVault
import HeftShareShared

@Suite("Share sheet text and queue")
struct ShareTitleAndQueueTests {
    @Test("Retitling keeps a comment with brackets before the link")
    func retitleKeepsEarlierBrackets() {
        let url = URL(string: "https://example.com/page")!
        let text = "Read [later] [Old](https://example.com/page)"
        let out = SharedContent.retitled(text, url: url, title: "New")
        #expect(out == "Read [later] [New](https://example.com/page)", "got: \(out)")
    }

    @Test("Retitling keeps an earlier link on the same line")
    func retitleKeepsEarlierLink() {
        let url = URL(string: "https://example.com/b")!
        let text = "Compare [A](https://example.org/a) with [B](https://example.com/b)"
        let out = SharedContent.retitled(text, url: url, title: "New")
        #expect(out == "Compare [A](https://example.org/a) with [New](https://example.com/b)", "got: \(out)")
    }

    @Test("A label with a blank line still makes one link, and retitles")
    func multiParagraphLabel() {
        let url = URL(string: "https://example.com/p")!
        let linked = SharedContent.link("First para\n\nSecond para", url)
        #expect(!linked.contains("\n\n"), "got: \(linked.debugDescription)")
        let out = SharedContent.retitled(linked, url: url, title: "T")
        #expect(out == "[T](https://example.com/p)", "got: \(out.debugDescription)")
    }

    @Test("A share for a daily folder outside the vault goes to the inbox, not queued forever")
    func queuedForeverSilently() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hunt-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Vault")
        let queue = base.appendingPathComponent("Pending")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try #"{"folder": "../outside"}"#.write(
            to: root.appendingPathComponent(".obsidian/daily-notes.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        try SharedVault.enqueue(.init(text: "shared", destination: .today, date: Date()), in: queue)
        for _ in 0..<3 { _ = SharedVault.drainQueue(from: queue, into: root) }
        let left = try FileManager.default.contentsOfDirectory(atPath: queue.path)
        #expect(left.isEmpty, "still queued after three drains: \(left)")
    }
}

@Suite("Sharing into a new note, or as the address")
struct ShareNewNoteTests {
    @Test("A share for a new note makes it where Obsidian puts new notes, then adds to it")
    func newNoteIsMadeThenAddedTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try #"{"newFileLocation": "folder", "newFileFolderPath": "Notes"}"#
            .write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        try SharedVault.file("[Page](https://example.com)", to: .newNote("Reading: later"), in: root)
        try SharedVault.file("second", to: .newNote("Reading: later"), in: root)
        let text = try String(contentsOf: root.appendingPathComponent("Notes/Reading- later.md"), encoding: .utf8)
        #expect(text.hasPrefix("[Page](https://example.com)\n"), "\(text.debugDescription)")
        #expect(text.contains("second"))
    }

    @Test("Address only keeps the comment and writes the bare address")
    func unlinkedKeepsTheComment() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(SharedContent.unlinked("see [Title](https://example.com/a) later", url: url)
                == "see https://example.com/a later")
    }
}
