import Foundation
import HeftCore
import Testing
@testable import Heft

/// Accepting a proposal for another note opens that note, unless turned off.
@MainActor
@Suite("Opening a note after accepting")
struct OpenAfterAcceptTests {
    private func setUp() throws -> (AppModel, URL, Proposal) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-open-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Open\n".write(to: root.appendingPathComponent("Open.md"), atomically: true, encoding: .utf8)
        try "# Other\n\nold\n".write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        let proposal = Proposal(notePath: "Other.md", base: "# Other\n\nold\n", body: "# Other\n\nnew\n",
                                agent: "x", summary: "s")
        try ProposalStore.write(proposal, in: root)
        let model = AppModel(registry: VaultRegistry(),
                             descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Open.md"))
        model.refreshProposals()
        return (model, root, proposal)
    }

    @Test("Accepting every change opens the note")
    func opens() throws {
        let (model, root, proposal) = try setUp()
        model.opensReviewedNotesSetting = { true }
        defer { model.closeWorkspace(); try? FileManager.default.removeItem(at: root) }
        model.acceptAll(proposal)
        #expect(model.current?.relativePath == "Other.md")
    }

    @Test("Turned off, the open note stays")
    func staysWhenOff() throws {
        let (model, root, proposal) = try setUp()
        model.opensReviewedNotesSetting = { false }
        defer { model.closeWorkspace(); try? FileManager.default.removeItem(at: root) }
        model.acceptAll(proposal)
        #expect(model.current?.relativePath == "Open.md")
    }

    @Test("Rejecting the last change opens nothing")
    func rejectingOpensNothing() throws {
        let (model, root, proposal) = try setUp()
        model.opensReviewedNotesSetting = { true }
        defer { model.closeWorkspace(); try? FileManager.default.removeItem(at: root) }
        model.decide(proposal, hunk: 0, accept: false)
        #expect(model.current?.relativePath == "Open.md")
    }
}
