import Foundation
import Testing
@testable import HeftCore

/// Full-text search over the vault: which line of which note matched.
@Suite("Content search")
struct ContentSearchTests {

    /// A hit is opened at its line, which the editor counts as `lineRange`
    /// does: a Windows line break is one break, not two.
    @Test("Line numbers count a Windows line break once")
    func windowsLineBreaks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-content-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Title\r\nfirst\r\nthe needle\r\nlast\r\n"
        let url = root.appendingPathComponent("Note.md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let note = NoteRef(relativePath: "Note.md", url: url, name: "Note", kind: .markdown)

        let hit = try #require(ContentSearch.run(notes: [note], query: "needle").matches.first)
        #expect(hit.line == 3)
        #expect(hit.preview == "the needle")
        let revealed = try #require(NoteText.range(ofLine: hit.line, in: source))
        #expect((source as NSString).substring(with: revealed) == "the needle")
    }
}
