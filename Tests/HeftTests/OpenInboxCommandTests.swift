import Foundation
import HeftCore
import Testing
@testable import Heft

/// Spotlight can open the inbox its capture writes to; the palette can too,
/// so the note is one command away inside the app as well. Creates the file
/// when the vault has none yet, the way the intent does.
@MainActor
@Suite("The Open Inbox palette command", .serialized)
struct OpenInboxCommandTests {
    @Test("Open Inbox creates Inbox.md when needed and shows it")
    func opensTheInbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-open-inbox-\(UUID().uuidString)", isDirectory: true)
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
        let command = try #require(AppCommand.registry.first { $0.id == "openInbox" })
        #expect(command.matches("inbox"))
        #expect(model.current?.relativePath == "Note.md")

        command.perform(on: model)
        #expect(model.current?.relativePath == "Inbox.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox.md").path))
    }
}
