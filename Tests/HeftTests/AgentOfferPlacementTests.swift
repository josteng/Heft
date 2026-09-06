import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The agent-setup offer lives in the review centre's slot at the top of the
/// sidebar, shown while nothing is waiting for review and the vault has no
/// guide; Not Now empties the slot again.
@MainActor
@Suite("The agent-setup offer's place", .serialized)
struct AgentOfferPlacementTests {
    private static let dismissedKey = "dev.stenglein.Heft.agentOfferDismissed"

    @Test("The review centre shows the offer for a fresh vault, and nothing after Not Now")
    func offerFillsTheEmptyReviewCentre() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-offer-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let previousDismissed = HeftDefaults.shared.stringArray(forKey: Self.dismissedKey)
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        defer {
            model.closeWorkspace()
            HeftDefaults.shared.set(previousDismissed, forKey: Self.dismissedKey)
            try? FileManager.default.removeItem(at: root)
        }
        try #require(GeneralSettings.shared.offersAgentSetup, "the offer is switched on by default")
        #expect(model.pendingProposals.isEmpty)
        #expect(model.shouldOfferAgentSetup)

        func height() -> CGFloat {
            let host = NSHostingView(rootView: ReviewCenter().environmentObject(model).frame(width: 260))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(height() > 40, "the offer takes the review centre's slot")

        model.dismissAgentSetupOffer()
        #expect(!model.shouldOfferAgentSetup)
        #expect(height() == 0, "Not Now leaves the slot empty")
    }
}
