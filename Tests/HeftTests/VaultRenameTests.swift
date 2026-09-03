import Foundation
import HeftCore
import Testing

/// Renaming a note, an attachment or a folder, and repointing what pointed at
/// it. The editor has done this from the sidebar since early on; this is the
/// same work with the window taken out, so the command line does it too.
@Suite("Renaming and repointing")
struct VaultRenameTests {

    private func withVault(
        _ files: [String: String], _ body: (URL, VaultIndex, VaultItem) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        let tree = VaultScanner.scan(root: root)
        try body(root, VaultIndex.build(root: tree), tree)
    }

    private func item(_ tree: VaultItem, _ path: String) throws -> VaultItem {
        try #require(tree.flattened().first { $0.relativePath == path }, "no \(path)")
    }

    /// The case this was built for: a folder whose name is misspelled, with a
    /// link written as a path into it.
    @Test("A folder rename moves its files and repoints the paths into it")
    func renamesAFolder() throws {
        try withVault([
            "Attachements/chart.png": "x",
            "Attachements/notes.pdf": "x",
            "Report.md": "See [[Attachements/chart.png]] and [[notes.pdf]].",
        ]) { root, index, tree in
            let folder = try item(tree, "Attachements")
            let summary = try VaultRename.perform(
                item: folder, to: "Attachments", index: index, vaultRoot: root
            )

            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Attachments/chart.png").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Attachements").path
            ))

            let report = try String(
                contentsOf: root.appendingPathComponent("Report.md"), encoding: .utf8
            )
            #expect(report.contains("[[Attachments/chart.png]]"))
            #expect(summary.links == 1)
            #expect(summary.notes == 1)

            // A link by bare name still resolves after the folder moves, so it
            // is left exactly as the reader wrote it.
            #expect(report.contains("[[notes.pdf]]"), "a bare link should not be rewritten")
        }
    }

    @Test("A note rename repoints the links to it")
    func renamesANote() throws {
        try withVault([
            "Ideas.md": "a note",
            "Index.md": "See [[Ideas]] and [[Ideas|my ideas]].",
        ]) { root, index, tree in
            let note = try item(tree, "Ideas.md")
            let summary = try VaultRename.perform(
                item: note, to: "Thoughts.md", index: index, vaultRoot: root
            )
            let indexNote = try String(
                contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8
            )
            #expect(indexNote.contains("[[Thoughts]]"))
            #expect(indexNote.contains("[[Thoughts|my ideas]]"), "the alias is the reader's words")
            #expect(summary.links == 2)
        }
    }

    /// A folder contributes one change per file inside it, because a link
    /// points at a file rather than at a folder.
    @Test("A folder expands to the files under it")
    func folderExpandsToFiles() throws {
        try withVault([
            "Old/a.md": "a", "Old/deep/b.png": "b", "Keep.md": "k",
        ]) { _, _, tree in
            let folder = try item(tree, "Old")
            let changes = VaultRename.changes(for: folder, movingTo: "New")
            #expect(changes == ["Old/a.md": "New/a.md", "Old/deep/b.png": "New/deep/b.png"])
        }
    }

    @Test("Renaming onto something that exists is refused")
    func refusesToOverwrite() throws {
        try withVault(["A.md": "a", "B.md": "b"]) { root, index, tree in
            let note = try item(tree, "A.md")
            #expect(throws: VaultRename.Failure.alreadyExists("B.md")) {
                try VaultRename.perform(item: note, to: "B.md", index: index, vaultRoot: root)
            }
            // And nothing moved.
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        }
    }

    /// A note edited between the plan and the write is somebody's work. Half of
    /// it plus half of this is worse than neither.
    @Test("A note that changed in between is left alone")
    func skipsANoteThatMovedOn() throws {
        try withVault([
            "Old.md": "a", "Links.md": "[[Old]]",
        ]) { root, index, tree in
            let note = try item(tree, "Old.md")
            let changes = VaultRename.changes(for: note, movingTo: "New.md")
            let planned = try VaultRename.rewrites(for: changes, in: index) {
                try String(contentsOf: $0.url, encoding: .utf8)
            }
            #expect(planned.count == 1)

            // Somebody types in it before the write lands.
            try "[[Old]] and more".write(
                to: root.appendingPathComponent("Links.md"), atomically: true, encoding: .utf8
            )
            let summary = VaultRename.apply(planned, after: changes, vaultRoot: root)
            #expect(summary.skipped == 1)
            #expect(summary.notes == 0)
            let after = try String(
                contentsOf: root.appendingPathComponent("Links.md"), encoding: .utf8
            )
            #expect(after == "[[Old]] and more", "the newer edit survived")
        }
    }
}
