import Foundation
import HeftCore
import Testing
@testable import Heft

/// The vault watcher ignores this process's own file events, so the files
/// Set Up writes would not reach the sidebar on their own; the action asks
/// for the rescan itself.
@MainActor
@Suite("Set Up refreshes the vault", .serialized)
struct AgentSetupRefreshTests {
    @Test("The guides Set Up writes appear in the tree without waiting on the watcher")
    func guidesAppearInTheTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-setup-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        let session = try #require(model.session)
        await session.awaitReload()
        let before = model.tree?.children.map(\.name) ?? []
        #expect(!before.contains("CLAUDE"))

        model.setUpAgentAccess()
        // The reload the action asks for is the one being tested; the watcher
        // would not deliver one for a write made by this process.
        await session.awaitReload()
        let after = model.tree?.children.map(\.name) ?? []
        #expect(after.contains("CLAUDE") && after.contains("AGENTS"), "\(after)")
    }
}
