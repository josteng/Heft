import Foundation
import HeftCore
import Testing
@testable import Heft

/// What a window opens on when it comes back after the last one closed.
@MainActor
@Suite("Reopening a window", .serialized)
struct ReopenNoteTests {

    @Test("Its own answer, or the launch's own")
    func resolved() {
        let launch = StartupNote(choice: .note, text: "Home.md")
        #expect(ReopenNote(sameAsLaunch: true, note: .standard).resolved(launch: launch) == launch)
        let weekly = StartupNote(choice: .pattern, text: "Weeks/{{date:GGGG-[W]WW}}.md")
        #expect(ReopenNote(sameAsLaunch: false, note: weekly).resolved(launch: launch) == weekly)
        #expect(ReopenNote.standard.resolved(launch: launch).choice == .lastNote)
    }

    /// A choice made with the earlier four-word setting carries over.
    @Test("An earlier stored choice is still read")
    func legacy() throws {
        #expect(ReopenNote.decode(nil, legacy: "asLaunch").sameAsLaunch)
        #expect(ReopenNote.decode(nil, legacy: "dailyNote").note.choice == .dailyNote)
        #expect(ReopenNote.decode(nil, legacy: nil) == .standard)
        let stored = ReopenNote(sameAsLaunch: false, note: StartupNote(choice: .note, text: "A.md"))
        #expect(ReopenNote.decode(try JSONEncoder().encode(stored), legacy: nil) == stored)
    }

    private func vault(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in files { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        return root
    }

    private func settle(_ model: AppModel) async throws {
        for _ in 0..<600 where model.index.notes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Closed and reopened without a quit: back on the note it was on.
    @Test("A window reopened with none open goes back to the last note")
    func reopensLastNote() async throws {
        let root = try vault(["Alpha.md", "Beta.md"])
        let registry = VaultRegistry()
        let first = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        try await settle(first)
        first.open(try #require(first.index.notes.first { $0.name == "Beta" }))
        first.closeWorkspace()

        let reopened = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { reopened.closeWorkspace() }
        #expect(reopened.current?.name == "Beta")
    }

    /// Every launch answer is offered for a reopen, a named note included.
    @Test("A reopened window can open one note, always")
    func reopensNamedNote() async throws {
        let root = try vault(["Alpha.md", "Beta.md"])
        let registry = VaultRegistry()
        StartupSettings.shared.setReopen(
            ReopenNote(sameAsLaunch: false, note: StartupNote(choice: .note, text: "Alpha")), for: root
        )
        defer { StartupSettings.shared.setReopen(.standard, for: root) }
        let first = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        try await settle(first)
        first.open(try #require(first.index.notes.first { $0.name == "Beta" }))
        first.closeWorkspace()

        let reopened = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { reopened.closeWorkspace() }
        #expect(reopened.current?.name == "Alpha")
    }

    /// A second window beside an open one is not a reopen.
    @Test("A window opened beside another keeps what it was given")
    func secondWindowUntouched() async throws {
        let root = try vault(["Alpha.md", "Beta.md"])
        let registry = VaultRegistry()
        let first = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { first.closeWorkspace() }
        try await settle(first)
        first.open(try #require(first.index.notes.first { $0.name == "Beta" }))
        registry.register(model: first) { _ in }

        let second = AppModel(registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { second.closeWorkspace() }
        #expect(second.current == nil)
    }
}
