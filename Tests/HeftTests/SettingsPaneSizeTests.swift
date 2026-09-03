import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The Settings window sizes itself to the pane showing, by measuring that pane
/// off screen. Two things have gone wrong with that and both looked the same —
/// a tab clipped halfway down a control.
@Suite("Settings pane sizes")
@MainActor
struct SettingsPaneSizeTests {

    private func withVault(_ body: @MainActor (VaultRegistry, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "note".write(
            to: root.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8
        )

        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path)
        )
        registry.register(model: model, openWindow: { _ in })
        defer {
            model.closeWorkspace()
            StartupSettings.shared.set(.standard, for: root)
        }
        try body(registry, root)
    }

    /// Choosing an option that needs a path adds a field, and the pattern option
    /// adds the token list as well. A window measured once per tab clips both.
    @Test("A pane that grows reports that it has grown")
    func paneGrowsWithItsChoice() throws {
        try withVault { registry, vault in
            @MainActor func height(_ choice: StartupNote.Choice) -> CGFloat {
                StartupSettings.shared.set(
                    StartupNote(choice: choice, text: "Inbox.md"), for: vault
                )
                return SettingsWindow.idealHeight(of: .startup, registry: registry)
            }
            let plain = height(.nothing)
            let named = height(.note)
            let pattern = height(.pattern)

            #expect(plain > 0)
            #expect(named > plain, "a path field should need room: \(named) vs \(plain)")
            // By a lot: the pattern option carries the whole token list, which
            // is worth a couple of hundred points. A few points more would be
            // satisfied by its longer sentence alone.
            #expect(
                pattern > named + 120,
                "the token list should need real room: \(pattern) vs \(named)"
            )
        }
    }

    /// The other failure: a pane that filled itself in on appear measured as its
    /// own empty placeholder, because `onAppear` never fires for a view that is
    /// never on screen.
    @Test("A pane measures at its real size, not its empty one")
    func paneMeasuresItsRealContent() throws {
        let empty = SettingsWindow.idealHeight(of: .startup, registry: VaultRegistry())
        try withVault { registry, _ in
            let real = SettingsWindow.idealHeight(of: .startup, registry: registry)
            #expect(
                real > empty,
                "with a vault open the pane has content: \(real) against \(empty) without"
            )
        }
    }

    /// Every pane has to be measurable: one that comes back at nothing would be
    /// a window with no height at all.
    @Test("Every tab measures to something")
    func everyTabMeasures() {
        let registry = VaultRegistry()
        for tab in SettingsWindow.Tab.allCases {
            #expect(
                SettingsWindow.idealHeight(of: tab, registry: registry) > 80,
                "\(tab.title) measured to nothing"
            )
        }
    }
}
