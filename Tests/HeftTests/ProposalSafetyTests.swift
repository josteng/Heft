import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// Accepting, settling and storing proposals: each a way an accepted change
/// went somewhere it should not, or a decided one came back.
@Suite("Proposals reach the right note once")
struct ProposalSafetyTests {

    @MainActor
    private func waitUntil(_ condition: () -> Bool, within seconds: Double = 3) async -> Bool {
        for _ in 0..<max(1, Int(seconds * 1000 / 50)) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func disposableVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftProposalSafety-\(UUID().uuidString)/vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func model(_ root: URL) throws -> AppModel {
        try "anchor\n".write(
            to: root.appendingPathComponent("Anchor.md"), atomically: true, encoding: .utf8)
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Anchor.md")
        )
        model.refreshProposals()
        return model
    }

    @Test("Accepting a create does not replace a note that appeared since")
    @MainActor
    func createOverExistingNote() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ProposalStore.write(
            Proposal(notePath: "Daily/2026-11-06.md", base: nil,
                     body: "# 2026-11-06\n\n- agent line\n", agent: "claude-code",
                     summary: "Capture: agent line", kind: .create),
            in: root)
        // The reader makes today's note and writes in it before reviewing.
        let note = root.appendingPathComponent("Daily/2026-11-06.md")
        try FileManager.default.createDirectory(
            at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 2026-11-06\n\n- my own line\n".write(to: note, atomically: true, encoding: .utf8)

        let model = try model(root)
        defer { model.closeWorkspace() }
        let waiting = try #require(model.pendingProposals.edits.first)
        model.acceptAll(waiting)
        _ = await waitUntil { model.proposals.isEmpty }
        let now = try String(contentsOf: note, encoding: .utf8)
        #expect(now.contains("my own line"), "the reader's line survived: \(now)")
    }

    @Test("Accepting an edit for a note renamed since does not recreate it")
    @MainActor
    func editForRenamedNote() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = "# Old\n\nalpha\n"
        try original.write(to: root.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        try ProposalStore.write(
            Proposal(notePath: "Old.md", base: original, body: "# Old\n\nALPHA\n",
                     agent: "claude-code", summary: "Shout"),
            in: root)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("Old.md"), to: root.appendingPathComponent("New.md"))

        let model = try model(root)
        defer { model.closeWorkspace() }
        let waiting = try #require(model.pendingProposals.edits.first)
        model.acceptAll(waiting)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Old.md").path),
                "a renamed note was written back under its old name")
    }

    @Test("A proposal file naming a path outside the vault is not written there")
    @MainActor
    func proposalPathClimbsOut() async throws {
        let root = try disposableVault()
        let parent = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try ProposalStore.write(
            Proposal(notePath: "../Escaped.md", base: nil, body: "outside\n",
                     agent: "claude-code", summary: "climb", kind: .create),
            in: root)
        let model = try model(root)
        defer { model.closeWorkspace() }
        let waiting = try #require(model.proposals.first)
        model.acceptAll(waiting)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Escaped.md").path),
                "accepting wrote beside the vault")
    }

    @Test("A failed write keeps the proposal")
    @MainActor
    func failedWriteKeepsProposal() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = "# Note\n\nalpha\n\nbeta\n"
        try original.write(to: folder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try ProposalStore.write(
            Proposal(notePath: "Locked/Note.md", base: original, body: "# Note\n\nALPHA\n\nBETA\n",
                     agent: "claude-code", summary: "Shout"),
            in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let model = try model(root)
        defer { model.closeWorkspace() }
        let waiting = try #require(model.pendingProposals.edits.first)
        model.acceptAll(waiting)
        let text = try String(contentsOf: folder.appendingPathComponent("Note.md"), encoding: .utf8)
        #expect(text == original, "precondition: the write really failed")
        let left = ProposalStore.all(in: root).first
        let hunks = left.map { $0.diff(against: text).hunks.count } ?? 0
        #expect(hunks == 2, "the accepted hunk that never reached the note is still waiting (\(hunks) left)")
    }

    @Test("Accepting a hunk keeps a file's missing final newline")
    func noTrailingNewline() {
        let original = "a\nb\nc"
        let diff = NoteDiff.between(original: original, proposed: "A\nb\nc")
        let out = NoteDiff.apply(diff.hunks, to: original, accepting: [0])
        #expect(out == "A\nb\nc")
    }

    @Test("A CRLF note settles in CRLF")
    func crlfSettle() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = "a\r\nb\r\nc\r\n"
        let p = Proposal(notePath: "N.md", base: original, body: "A\r\nb\r\nC\r\n", agent: "x", summary: "s")
        let out = try ProposalStore.settle(p, currentText: original, accepted: [0], rejected: [], in: root)
        #expect(out.noteText == "A\r\nb\r\nc\r\n")
        #expect(out.remaining.map { $0.diff(against: out.noteText).hunks.count } == 1)
    }

    @Test("An iCloud conflict copy of a proposal goes when the proposal is accepted")
    @MainActor
    func conflictCopyOutlivesAccept() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = "# Note\n\nalpha\n"
        try original.write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let url = try ProposalStore.write(
            Proposal(id: "shout", notePath: "Note.md", base: original, body: "# Note\n\nALPHA\n",
                     agent: "claude-code", summary: "Shout"),
            in: root)
        try FileManager.default.copyItem(
            at: url, to: url.deletingLastPathComponent().appendingPathComponent("shout 2.json"))
        let model = try model(root)
        defer { model.closeWorkspace() }
        let waiting = try #require(model.pendingProposals.edits.first)
        model.acceptAll(waiting)
        model.refreshProposals()
        #expect(model.proposals.isEmpty, "still pending after accepting: \(model.proposals.map(\.id))")
    }

    @Test("Settling a proposal another device already answered does not bring it back")
    func settleResurrectsDropped() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = "# Note\n\nalpha\n\nbeta\n"
        let proposal = Proposal(id: "shout", notePath: "Note.md", base: original,
                                body: "# Note\n\nALPHA\n\nBETA\n", agent: "x", summary: "Shout")
        try ProposalStore.write(proposal, in: root)
        // The Mac discards it; the phone's sheet still holds it and rejects one hunk.
        ProposalStore.remove("shout", in: root)
        _ = try ProposalStore.settle(proposal, currentText: original, accepted: [], rejected: [0], in: root)
        #expect(ProposalStore.all(in: root).isEmpty, "the discarded proposal is back")
    }

    @Test("A move proposed without .md still lands as a note")
    @MainActor
    func moveWithoutExtension() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try "# A\n".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        // What `heft propose <vault> A.md --move Archive/A` stores.
        try ProposalStore.write(
            Proposal(notePath: "A.md", base: nil, body: "", agent: "x", summary: "archive a",
                     kind: .move, destination: "Archive/A"),
            in: root)
        let model = try model(root)
        defer { model.closeWorkspace() }
        _ = await waitUntil { model.tree != nil }
        let waiting = try #require(model.pendingProposals.structural.first)
        model.applyStructural(waiting, confirmed: true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/A.md").path),
                "moved to: \((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Archive").path)) ?? [])")
    }

    @Test("One proposal per note, however its path is spelled")
    func conflictIgnoresSpelling() {
        let waiting = Proposal(notePath: "Sub/Note.md", base: "a\n", body: "b\n", agent: "x", summary: "s")
        for spelling in ["sub/note.md", "Sub//Note.md", "./Sub/Note.md"] {
            #expect(ProposalStore.conflict(forNote: spelling, among: [waiting]) != nil, "\(spelling)")
        }
        #expect(ProposalStore.conflict(forNote: "Sub/Other.md", among: [waiting]) == nil)
    }
}
