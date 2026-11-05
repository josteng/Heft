import Foundation
import HeftCore
import Testing
@testable import Heft

/// A note or folder made in the sidebar is named in its own row, so the row
/// has to be on screen. Opening only its parent left it inside a shut folder
/// further up, where nothing showed that anything had been made.
@MainActor
@Suite("New items in the file tree", .serialized)
struct NewItemRevealTests {
    private func withModel(_ body: (AppModel, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-new-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects/Garden"), withIntermediateDirectories: true
        )
        try "Beds".write(to: root.appendingPathComponent("Projects/Garden/Beds.md"), atomically: true, encoding: .utf8)
        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Projects/Garden/Beds.md")
        )
        registry.register(model: model) { _ in }
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        try body(model, root)
    }

    @Test("A new note opens every folder above it")
    func noteOpensAncestors() throws {
        try withModel { model, root in
            #expect(!model.expandedFolders.contains("Projects"))
            let created = try #require(model.createUntitledNote(in: root.appendingPathComponent("Projects/Garden")))
            #expect(created.path == "Projects/Garden/Untitled.md")
            #expect(model.expandedFolders.isSuperset(of: ["Projects", "Projects/Garden"]))
            #expect(model.revealTarget == created.path)
        }
    }

    @Test("A new folder opens every folder above it")
    func folderOpensAncestors() throws {
        try withModel { model, root in
            let created = try #require(model.createUntitledFolder(in: root.appendingPathComponent("Projects/Garden")))
            #expect(created.path == "Projects/Garden/Untitled")
            #expect(model.expandedFolders.isSuperset(of: ["Projects", "Projects/Garden"]))
            #expect(model.revealTarget == created.path)
        }
    }
}
