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
