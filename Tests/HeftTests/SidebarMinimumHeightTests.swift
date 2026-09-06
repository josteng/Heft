import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The split view probes its sidebar at zero width for a minimum, and the
/// window takes that minimum. A text fixed vertically answers with one
/// character per line, so a fresh vault once opened a window taller than a
/// screen that could not be shrunk, until Not Now removed the offer.
@MainActor
@Suite("The sidebar's minimum height", .serialized)
struct SidebarMinimumHeightTests {
    @Test("The window's content with the agent offer showing fits a laptop screen")
    func offerDoesNotStretchTheWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-min-height-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        registry.register(model: model) { _ in }
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        try #require(GeneralSettings.shared.offersAgentSetup, "the offer is switched on by default")
        try #require(model.shouldOfferAgentSetup, "a vault without a guide gets the offer")

        // The sidebar inside a split view, which is what probes it at zero
        // width; the window's other columns are not part of the question.
        let column = NSHostingView(
            rootView: SidebarProbe().environmentObject(model).environmentObject(registry)
        )
        column.layoutSubtreeIfNeeded()
        #expect(column.fittingSize.height < 700, "\(column.fittingSize)")

        // And the offer's text still wraps rather than running off one line.
        let offer = NSHostingView(
            rootView: AgentSetupOffer().environmentObject(model).frame(width: 258)
        )
        offer.layoutSubtreeIfNeeded()
        #expect(offer.fittingSize.height > 90, "\(offer.fittingSize)")
    }
}

private struct SidebarProbe: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            Color.clear
        }
    }
}
