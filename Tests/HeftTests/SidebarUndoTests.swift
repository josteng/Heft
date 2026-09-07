import Foundation
import HeftCore
import Testing
@testable import Heft

/// Putting back what the tree just did.
@MainActor
@Suite("Sidebar undo", .serialized)
struct SidebarUndoTests {

    private func vaultRoot(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-undo-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func ready(_ model: AppModel) async throws -> AppModel {
        for _ in 0..<600 where model.tree == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.tree != nil, "the vault never finished scanning")
        return model
    }

    private func settled(_ model: AppModel, until path: String, exists: Bool = true) async {
        for _ in 0..<600 {
            let present = model.tree?.flattened().contains { $0.relativePath == path } == true
            if present == exists { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The stack itself

    @Test("Nothing to undo before anything has happened")
    func nothingAtFirst() {
        #expect(SidebarUndo().name == nil)
    }

    @Test("A step is offered by name")
    func stepsAreNamed() {
        var undo = SidebarUndo()
        undo.record(.renamed(to: "B.md", from: "A.md"))
        #expect(undo.name == "Rename")
        undo.record(.moved(to: ["F/A.md", "F/B.md"], from: ["A.md", "B.md"]))
        #expect(undo.name == "Move of 2 Items")
        undo.record(.pasted(["A copy.md"]))
        #expect(undo.name == "Paste")
    }

    @Test("Taking a step leaves nothing behind")
    func takingIsOnce() {
        // Undoing twice must not undo the same move twice, which on a file
        // that has since moved again would put back something that is gone.
        var undo = SidebarUndo()
        undo.record(.renamed(to: "B.md", from: "A.md"))
        #expect(undo.take() != nil)
        #expect(undo.take() == nil)
        #expect(undo.name == nil)
    }

    // MARK: - Against a real vault

    @Test("A move goes back where it came from")
    func undoesAMove() async throws {
        let root = try vaultRoot(["A.md": "a\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: ScriptedHost()
        ))
        defer { model.closeWorkspace() }

        model.move(
            [root.appendingPathComponent("A.md")],
            into: root.appendingPathComponent("Folder", isDirectory: true)
        )
        await settled(model, until: "Folder/A.md")
        #expect(model.sidebarUndoName == "Move")

        #expect(model.undoSidebarOperation())
        await settled(model, until: "A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.md").path))
    }

    @Test("A rename goes back to the old name")
    func undoesARename() async throws {
        let root = try vaultRoot(["A.md": "a\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Renamed"]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        let item = try #require(model.tree?.flattened().first { $0.relativePath == "A.md" })
        #expect(model.rename(item))
        await settled(model, until: "Renamed.md")
        #expect(model.sidebarUndoName == "Rename")

        #expect(model.undoSidebarOperation())
        await settled(model, until: "A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
    }

    @Test("A paste takes its copies away again")
    func undoesAPaste() async throws {
        let root = try vaultRoot(["A.md": "a\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("A.md")]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.paste(into: root.appendingPathComponent("Folder", isDirectory: true))
        await settled(model, until: "Folder/A.md")
        #expect(model.sidebarUndoName == "Paste")

        #expect(model.undoSidebarOperation())
        await settled(model, until: "Folder/A.md", exists: false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.md").path))
        // The original is untouched: undoing a paste removes the copy only.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
    }

    @Test("A trashed note comes back from the Trash")
    func undoesATrash() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        let item = try #require(model.tree?.flattened().first { $0.relativePath == "A.md" })
        model.delete(item)
        await settled(model, until: "A.md", exists: false)
        #expect(model.sidebarUndoName == "Move to Trash")

        #expect(model.undoSidebarOperation())
        await settled(model, until: "A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(try String(contentsOf: root.appendingPathComponent("A.md"), encoding: .utf8) == "a\n")
    }

    @Test("Trashing several is put back as one step")
    func undoesAGroupTrash() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.delete(model.items(for: ["A.md", "B.md"]))
        await settled(model, until: "A.md", exists: false)
        // One step for the group, not the last file of it.
        #expect(model.sidebarUndoName == "Move of 2 Items to Trash")

        #expect(model.undoSidebarOperation())
        await settled(model, until: "A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("B.md").path))
    }

    @Test("Undoing twice does not undo the same thing twice")
    func undoIsOffered_once() async throws {
        let root = try vaultRoot(["A.md": "a\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: ScriptedHost()
        ))
        defer { model.closeWorkspace() }

        model.move(
            [root.appendingPathComponent("A.md")],
            into: root.appendingPathComponent("Folder", isDirectory: true)
        )
        await settled(model, until: "Folder/A.md")
        #expect(model.undoSidebarOperation())
        await settled(model, until: "A.md")
        #expect(model.sidebarUndoName == nil)
        #expect(!model.undoSidebarOperation())
    }
}
