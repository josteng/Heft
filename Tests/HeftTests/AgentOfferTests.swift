import Foundation
import HeftCore
import Testing
@testable import Heft

/// The agent-setup offer is a question asked once. It can be switched off,
/// and a vault that said no is not asked again because the instructions it
/// declined were revised; only a vault that opted in is told about a change.
@MainActor
@Suite("The agent-setup offer", .serialized)
struct AgentOfferTests {
    private static let dismissedKey = "dev.stenglein.Heft.agentOfferDismissed"

    /// A model over a fresh vault. The shared setting is never written: a
    /// change to it reaches every open window, and another suite may be
    /// counting what its window hears. Each check passes the setting in.
    private func withVault(_ body: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-offer-\(UUID().uuidString)", isDirectory: true)
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
        await model.session?.awaitReload()
        try await body(model, root)
    }

    @Test("The setting switches the offer off")
    func settingSilencesTheOffer() async throws {
        try await withVault { model, _ in
            let version = AgentGuide.version
            #expect(
                model.shouldOfferAgentSetup(guideVersion: version, offered: true),
                "a vault without a guide is offered one"
            )
            #expect(
                !model.shouldOfferAgentSetup(guideVersion: version, offered: false),
                "switched off, nothing is asked"
            )
            #expect(
                model.shouldOfferAgentSetup == GeneralSettings.shared.offersAgentSetup,
                "the banner follows the shared setting"
            )
        }
    }

    @Test("A vault that declined is not asked again when the guide is revised")
    func declinedVaultStaysDeclined() async throws {
        try await withVault { model, _ in
            model.dismissAgentSetupOffer()
            #expect(!model.shouldOfferAgentSetup(guideVersion: AgentGuide.version, offered: true))
            #expect(
                !model.shouldOfferAgentSetup(guideVersion: AgentGuide.version + 1, offered: true),
                "declining the feature is not per revision of instructions never wanted"
            )
        }
    }

    @Test("A vault that opted in is told once per revision")
    func optedInVaultIsAskedPerRevision() async throws {
        try await withVault { model, root in
            model.setUpAgentAccess()
            #expect(
                !model.shouldOfferAgentSetup(guideVersion: AgentGuide.version, offered: true),
                "a current guide asks nothing"
            )
            // Age the stamp, as a guide written by the previous Heft would be.
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let url = root.appendingPathComponent(name)
                let aged = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
                    of: "version: \(AgentGuide.version) -->",
                    with: "version: \(AgentGuide.version - 1) -->"
                )
                try aged.write(to: url, atomically: true, encoding: .utf8)
            }
            #expect(model.agentGuideStatus == .outdated(found: AgentGuide.version - 1))
            #expect(
                model.shouldOfferAgentSetup(guideVersion: AgentGuide.version, offered: true),
                "an out-of-date guide is offered a refresh"
            )
            model.dismissAgentSetupOffer()
            #expect(
                !model.shouldOfferAgentSetup(guideVersion: AgentGuide.version, offered: true),
                "and Not Now silences this revision"
            )
            #expect(
                model.shouldOfferAgentSetup(guideVersion: AgentGuide.version + 1, offered: true),
                "the next revision is a new question for a vault that opted in"
            )
        }
    }

    @Test("A refusal remembered by an earlier build still counts")
    func earlierRefusalStillCounts() async throws {
        try await withVault { model, root in
            HeftDefaults.shared.set(
                ["\(root.standardizedFileURL.path)#\(AgentGuide.version)"],
                forKey: Self.dismissedKey
            )
            #expect(
                !model.shouldOfferAgentSetup(guideVersion: AgentGuide.version, offered: true),
                "an update must not ask once more"
            )
        }
    }
}
