import Foundation
import Testing
@testable import HeftCore

/// What the index makes of vaults shaped the way real ones are rather than
/// the way a fixture usually is.
@Suite("Index edge cases")
struct VaultIndexEdgeTests {

    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-index-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func build(_ root: URL) -> VaultIndex {
        VaultIndex.build(root: VaultScanner.scan(root: root))
    }

    /// `xab/Note.md` is shallower, so it is first among the candidates and
    /// a plain suffix test let it answer for the folder `b`.
    @Test("A link's folder matches whole path components")
    func folderMatchesWholeComponents() throws {
        let root = try makeVault([
            "xab/Note.md": "a", "sub/b/Note.md": "b", "Links.md": "[[b/Note]] [[b/Note.md]]",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let index = build(root)
        let source = index.note(atRelativePath: "Links.md")

        #expect(index.resolve(WikiLink(target: "b/Note"), from: source)?.relativePath == "sub/b/Note.md")
        #expect(index.resolve(WikiLink(target: "b/Note.md"), from: source)?.relativePath == "sub/b/Note.md")
        #expect(index.backlinks(to: "sub/b/Note.md").count == 2)
        #expect(index.backlinks(to: "xab/Note.md").isEmpty)
    }
}

/// A vault synced from Windows ends every line in `\r\n`, frontmatter
/// fences included.
@Suite("Windows line breaks in frontmatter")
struct CRLFFrontmatterTests {
    private let note = "---\r\ntags: [work, plan]\r\naliases:\r\n  - Roadmap\r\n---\r\nBody #inline\r\n"

    @Test("The block is found and its fences keep their returns")
    func splitsAndRejoins() {
        let split = NoteText.splitFrontmatter(note)
        #expect(split.frontmatter == "tags: [work, plan]\r\naliases:\r\n  - Roadmap\r")
        #expect(split.body == "Body #inline\r\n")
        #expect("---\r\n" + (split.frontmatter ?? "") + "\n---\r\n" + split.body == note)
    }

    @Test("Tags and aliases come out without a return")
    func tagsAndAliases() {
        #expect(NoteTags.all(in: note) == ["work", "plan", "inline"])
        #expect(NoteAliases.all(in: note) == ["Roadmap"])
        #expect(Frontmatter.parse("title: X\r\nkind: y\r") == [
            NoteProperty(key: "title", value: .text("X")),
            NoteProperty(key: "kind", value: .text("y")),
        ])
    }

    @Test("The surface draws it as frontmatter")
    func decoratedAsFrontmatter() {
        let decoration = LiveDecorator.decorations(in: note).first { $0.style == .frontmatter }
        #expect(decoration?.range == NSRange(location: 0, length: 51))
    }
}
