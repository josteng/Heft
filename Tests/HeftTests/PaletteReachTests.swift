import Foundation
import HeftCore
import Testing
@testable import Heft

/// What the palette can reach.
///
/// A reader who has not learnt the keys has the palette and the menus, and
/// the menus are where the rest of an app's verbs hide. These are the ones
/// that were a key or a menu away and are now in the palette too, and the
/// two mechanisms that let a command act from inside a sheet that holds the
/// keyboard and covers the window.
@MainActor
@Suite("What the palette reaches")
struct PaletteReachTests {

    private func command(_ id: String) throws -> AppCommand {
        try #require(AppCommand.registry.first { $0.id == id }, "no command \(id)")
    }

    @Test("The panels that were only a keystroke away are commands")
    func panelsAreReachable() throws {
        for id in ["quickOpen", "searchVault", "findInNote"] {
            let command = try command(id)
            #expect(command.shortcut != nil, "\(id) should show its key")
        }
    }

    @Test("Every format the bar offers is a command")
    func formatsAreReachable() throws {
        let ids = ["formatBold", "formatItalic", "formatStrikethrough",
                   "formatHighlight", "formatCode", "formatLink"]
        for id in ids { _ = try command(id) }
        // The bar's own six, so neither list can grow without the other.
        #expect(ids.count == InlineFormat.allCases.count + 1, "a link is the sixth")
    }

    @Test("The window's own menus are reachable too")
    func menuVerbsAreReachable() throws {
        for id in ["newNote", "newVault", "saveNow", "settings",
                   "agentAccess", "focusEntireVault", "focusFolder",
                   "revealScopeInFinder"] {
            _ = try command(id)
        }
    }

    /// Both name a focused folder, and the model answers the vault itself
    /// when there is none, so both have to ask whether one is focused
    /// rather than whether there is a folder to point at.
    @Test("The focus verbs are offered only while a folder is focused")
    func focusVerbsNeedAFocus() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-reach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Work"), withIntermediateDirectories: true
        )
        try Data("note".utf8).write(to: root.appendingPathComponent("Work/Note.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path)
        )
        defer { model.closeWorkspace() }
        for _ in 0..<600 where model.tree == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tree != nil, "the vault never finished scanning")
        try #require(model.scopePath == nil, "nothing is focused yet")

        for id in ["focusEntireVault", "revealScopeInFinder", "focusHighlightedFolder"] {
            #expect(!(try command(id).isEnabled(on: model)), "\(id) with nothing in hand")
        }

        // Highlighting a folder in the sidebar is not focusing the window on
        // it, but it is what a command means by "this folder".
        model.highlightedFolder = "Work"
        #expect(try command("revealScopeInFinder").isEnabled(on: model))
        #expect(try command("focusHighlightedFolder").isEnabled(on: model))
        #expect(model.folderInHand?.lastPathComponent == "Work")
        #expect(
            !(try command("focusEntireVault").isEnabled(on: model)),
            "a highlight is not a focus to undo"
        )

        // Focusing on it is, and then the window has a folder of its own.
        model.focusOnFolderInHand()
        #expect(model.scopePath == "Work")
        for id in ["focusEntireVault", "revealScopeInFinder"] {
            #expect(try command(id).isEnabled(on: model), "\(id) with a folder focused")
        }

        // With nothing highlighted, the focused folder is the one in hand.
        model.highlightedFolder = nil
        #expect(model.folderInHand?.lastPathComponent == "Work")
    }

    /// A focus is felt in the tree, so the tree is where a reader looks to
    /// undo it, rather than in the menu under the window's title.
    @Test("The way out of a focused folder is in the tree's own menu")
    func unfocusIsInTheTree() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("MenuButton(\"Show the Entire Vault\""))
        #expect(AppCommand.registry.contains { $0.id == "focusEntireVault" })
    }

    /// The editor cannot be reached down the responder chain while the
    /// palette is open, so a format travels as a request on the model.
    @Test("A format asked for becomes a request the editor can answer")
    func formatBecomesARequest() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        #expect(model.pendingFormat == nil)

        model.applyFormat(.bold)
        #expect(model.pendingFormat?.format == .bold)
        let first = try? #require(model.pendingFormat?.generation)

        // The same format twice is two edits, not one.
        model.applyFormat(.bold)
        #expect(model.pendingFormat?.generation != first)

        // Nil is the one that makes a link, as on the formatting bar.
        model.applyFormat(nil)
        #expect(model.pendingFormat?.format == nil)
    }

    /// Both are sheets on one window, and the second would be refused.
    @Test("A panel waits for the palette to close")
    func panelWaitsForThePalette() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        model.isCommandPalettePresented = true

        var ran = false
        model.afterPalette { _ in ran = true }
        #expect(!ran, "it must not run while the palette is up")
        #expect(!model.isCommandPalettePresented, "the palette is asked to close")

        model.commandPaletteDidDismiss()
        #expect(ran)

        // With no palette open it runs at once.
        var direct = false
        model.afterPalette { _ in direct = true }
        #expect(direct)
    }
}
