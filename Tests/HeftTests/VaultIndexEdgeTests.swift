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

    /// Latin-1 from an old editor: `é` is the lone byte E9, which is not
    /// UTF-8, and a strict read made the whole note unreadable.
    @Test("A note that is not UTF-8 keeps its links and tags")
    func notUTF8KeepsLinksAndTags() throws {
        let root = try makeVault(["B.md": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        try (Data([0x43, 0x61, 0x66, 0xE9]) + Data(" [[B]] #menu\n".utf8))
            .write(to: root.appendingPathComponent("Caf.md"))
        let index = build(root)

        #expect(index.backlinks(to: "B.md").map(\.source.relativePath) == ["Caf.md"])
        #expect(index.notes(taggedWith: "menu").map(\.relativePath) == ["Caf.md"])
    }

    /// A byte-order mark is not text: kept, it would stand before the
    /// frontmatter's opening fence.
    @Test("A byte-order mark does not hide the frontmatter")
    func byteOrderMark() throws {
        let root = try makeVault([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try (Data([0xEF, 0xBB, 0xBF]) + Data("---\ntags: [x]\n---\nbody\n".utf8))
            .write(to: root.appendingPathComponent("N.md"))
        #expect(build(root).notes(taggedWith: "x").map(\.relativePath) == ["N.md"])
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

/// Obsidian follows a symlinked folder, so a vault may be built on them.
@Suite("Symlinked folders")
struct SymlinkedFolderTests {

    @Test("A linked folder is scanned as a folder, and a loop is not followed")
    func linkedFolderIsAFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-linked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault")
        let outside = base.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("Linked #shared".utf8).write(to: outside.appendingPathComponent("Shared.md"))
        try Data("See [[Shared]]".utf8).write(to: vault.appendingPathComponent("Home.md"))
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("Projects"), withDestinationURL: outside
        )
        // Back up to the vault itself.
        try FileManager.default.createSymbolicLink(
            at: outside.appendingPathComponent("Up"), withDestinationURL: vault
        )

        let tree = VaultScanner.scan(root: vault)
        let projects = tree.children.first { $0.relativePath == "Projects" }
        #expect(projects?.kind == .folder)
        #expect(tree.flattened().map(\.relativePath).sorted() == [
            "", "Home.md", "Projects", "Projects/Shared.md",
        ])

        let index = VaultIndex.build(root: tree)
        #expect(index.backlinks(to: "Projects/Shared.md").count == 1)
        #expect(index.notes(taggedWith: "shared").map(\.relativePath) == ["Projects/Shared.md"])
    }
}
