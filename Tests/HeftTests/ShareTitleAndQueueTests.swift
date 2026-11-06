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
