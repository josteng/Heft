import Foundation
import Testing
@testable import Heft
@testable import HeftCore

@Suite("Agent proposals")
struct ProposalTests {

    // MARK: - Diff

    @Test("A rewritten paragraph is one hunk, not a rewritten file")
    func focusedHunk() {
        let before = "# Title\n\nOne.\n\nTwo.\n\nThree.\n"
        let after = "# Title\n\nOne.\n\nTwo, revised.\n\nThree.\n"
        let diff = NoteDiff.between(original: before, proposed: after)

        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].removed == ["Two."])
        #expect(diff.hunks[0].added == ["Two, revised."])
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
    }

    @Test("An append is an insertion at the end, removing nothing")
    func appendIsInsertion() {
        let diff = NoteDiff.between(original: "A\nB\n", proposed: "A\nB\nC\n")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].isInsertion)
        #expect(diff.hunks[0].added == ["C"])
        #expect(diff.hunks[0].originalRange == 2..<2)
    }

    @Test("Identical text has no hunks, trailing newline or not")
    func noChange() {
        #expect(NoteDiff.between(original: "A\nB\n", proposed: "A\nB\n").isEmpty)
        #expect(NoteDiff.between(original: "A\nB\n", proposed: "A\nB").isEmpty)
    }

    @Test("Applying every hunk reproduces the proposal exactly")
    func applyAllIsIdentity() {
        let cases: [(String, String)] = [
            ("A\nB\nC\n", "A\nB2\nC\n"),
            ("A\nB\nC\n", "C\nB\nA\n"),
            ("", "New note.\n"),
            ("Everything.\n", ""),
            ("A\nB\nC\nD\nE\n", "A\nX\nC\nY\nE\nF\n"),
            ("one\n\ntwo\n\nthree\n", "one\n\nthree\n"),
        ]
        for (before, after) in cases {
            let diff = NoteDiff.between(original: before, proposed: after)
            let all = Set(diff.hunks.map(\.id))
            let result = NoteDiff.apply(diff.hunks, to: before, accepting: all)
            #expect(result == NoteDiff.join(NoteDiff.lines(of: after)), "\(before) → \(after)")
        }
    }

    @Test("Accepting no hunks leaves the note alone")
    func applyNoneIsNoOp() {
        let before = "A\nB\nC\n"
        let diff = NoteDiff.between(original: before, proposed: "A\nX\nC\nD\n")
        #expect(NoteDiff.apply(diff.hunks, to: before, accepting: []) == before)
    }

    @Test("Accepting a later hunk does not disturb an earlier one")
    func hunksApplyBackToFront() {
        let before = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
        let after = "ONE\ntwo\nthree\nfour\nfive\nsix\nSEVEN\nextra\n"
        let diff = NoteDiff.between(original: before, proposed: after)
        #expect(diff.hunks.count == 2)

        let last = diff.hunks[1].id
        let result = NoteDiff.apply(diff.hunks, to: before, accepting: [last])
        #expect(result == "one\ntwo\nthree\nfour\nfive\nsix\nSEVEN\nextra\n")
    }

    // MARK: - Settling a half-reviewed proposal

    @Test("Accepting one hunk keeps the rest, and rejecting drops it for good")
    func settleSplitsTheProposal() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = "# Note\n\nalpha\n\nbeta\n\ngamma\n"
        let wanted = "# Note\n\nALPHA\n\nbeta\n\nGAMMA\n"
        let proposal = Proposal(
            notePath: "Note.md", base: before, body: wanted,
            agent: "test", summary: "Shout at both ends"
        )
        try ProposalStore.write(proposal, in: root)

        let diff = proposal.diff(against: before)
        #expect(diff.hunks.count == 2)

        // Accept the first, leaving the second undecided.
        let first = try ProposalStore.settle(
            proposal, currentText: before,
            accepted: [diff.hunks[0].id], rejected: [], in: root
        )
        #expect(first.noteText == "# Note\n\nALPHA\n\nbeta\n\ngamma\n")
        let remaining = try #require(first.remaining)
        #expect(remaining.id == proposal.id)

        // What is left is exactly the hunk nobody answered.
        let stillOpen = remaining.diff(against: first.noteText)
        #expect(stillOpen.hunks.count == 1)
        #expect(stillOpen.hunks[0].added == ["GAMMA"])

        // Rejecting it removes the proposal entirely and changes nothing.
        let second = try ProposalStore.settle(
            remaining, currentText: first.noteText,
            accepted: [], rejected: [stillOpen.hunks[0].id], in: root
        )
        #expect(second.noteText == first.noteText)
        #expect(second.remaining == nil)
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("A rejected hunk is never proposed again")
    func rejectionSticks() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = "a\nb\nc\n"
        let proposal = Proposal(
            notePath: "Note.md", base: before, body: "A\nb\nC\n",
            agent: "test", summary: "Two changes"
        )
        let diff = proposal.diff(against: before)
        #expect(diff.hunks.count == 2)

        let outcome = try ProposalStore.settle(
            proposal, currentText: before,
            accepted: [], rejected: [diff.hunks[0].id], in: root
        )
        let remaining = try #require(outcome.remaining)
        // Only the second change survives; the rejected one is gone from the
        // body, not merely unapplied.
        #expect(remaining.body == "a\nb\nC\n")
    }

    // MARK: - Store

    @Test("Proposals round-trip through disk and stay oldest first")
    func storeRoundTrip() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Proposal(
            notePath: "A.md", base: nil, body: "one\n", agent: "test",
            summary: "first", createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let new = Proposal(
            notePath: "B.md", base: nil, body: "two\n", agent: "test",
            summary: "second", createdAt: Date(timeIntervalSince1970: 2_000)
        )
        try ProposalStore.write(new, in: root)
        try ProposalStore.write(old, in: root)

        let all = ProposalStore.all(in: root)
        #expect(all.map(\.summary) == ["first", "second"])
        #expect(ProposalStore.forNote("B.md", in: root).count == 1)

        ProposalStore.remove(old.id, in: root)
        #expect(ProposalStore.all(in: root).map(\.summary) == ["second"])
    }

    @Test("A note edited after the agent read it is reported as stale")
    func staleness() {
        let proposal = Proposal(
            notePath: "A.md", base: "original\n", body: "proposed\n",
            agent: "test", summary: "s"
        )
        #expect(!proposal.isStale(against: "original\n"))
        #expect(proposal.isStale(against: "the user typed this instead\n"))
    }

    @Test("A corrupt proposal file does not hide the others")
    func corruptFileIsSkipped() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try ProposalStore.write(
            Proposal(notePath: "A.md", base: nil, body: "x\n", agent: "t", summary: "good"),
            in: root
        )
        try "{ not json".write(
            to: ProposalStore.directory(in: root).appendingPathComponent("broken.json"),
            atomically: true, encoding: .utf8
        )
        #expect(ProposalStore.all(in: root).map(\.summary) == ["good"])
    }

    // MARK: - Caret survival

    @Test("A caret keeps its place when the text changes around it")
    @MainActor
    func caretMapping() {
        func mapped(_ caret: Int, _ old: String, _ new: String) -> Int {
            LiveTextEditor.mapLocation(caret, from: old as NSString, to: new as NSString)
        }

        // An insertion above the caret pushes it down by exactly that much.
        #expect(mapped(10, "abc\ndef\n", "abc\nNEW\ndef\n") == 14)
        // An edit below the caret leaves it alone.
        #expect(mapped(2, "abc\ndef\n", "abc\ndefg\n") == 2)
        // A caret inside the rewritten part has nowhere true to go, so it goes
        // to where the change starts rather than somewhere arbitrary.
        #expect(mapped(5, "abc\ndef\n", "abc\nxyz\n") == 4)
        // Shrinking the document cannot leave the caret past its end.
        #expect(mapped(8, "abc\ndef\n", "ab") <= 2)
    }

    // MARK: - Through the app

    @Test("Accepting a hunk in the editor writes the note and keeps the rest")
    @MainActor
    func acceptThroughTheEditor() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        let original = "# Note\n\nalpha\n\nbeta\n\ngamma\n"
        try original.write(to: note, atomically: true, encoding: .utf8)

        let proposal = Proposal(
            notePath: "Note.md", base: original,
            body: "# Note\n\nALPHA\n\nbeta\n\nGAMMA\n",
            agent: "claude-code", summary: "Shout at both ends"
        )
        try ProposalStore.write(proposal, in: root)

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        #expect(model.current?.relativePath == "Note.md")

        model.refreshProposals()
        #expect(model.proposalsForCurrentNote.count == 1)

        let pending = try #require(model.proposalsForCurrentNote.first)
        let hunks = pending.diff(against: model.currentText(for: pending)).hunks
        #expect(hunks.count == 2)

        model.decide(pending, hunk: hunks[0].id, accept: true)

        // The accepted change goes through the buffer, so it lands on disk by
        // the ordinary autosave rather than by writing under the editor.
        let written = await waitUntil {
            (try? String(contentsOf: note, encoding: .utf8)) == "# Note\n\nALPHA\n\nbeta\n\ngamma\n"
        }
        #expect(written, "accepting one hunk saves the note with only that change")

        // The other change is still waiting, and still only the other one.
        let remaining = try #require(model.proposalsForCurrentNote.first)
        let left = remaining.diff(against: model.text).hunks
        #expect(left.count == 1)
        #expect(left[0].added == ["GAMMA"])

        model.discard(remaining)
        #expect(model.proposalsForCurrentNote.isEmpty)
        model.closeWorkspace()
    }

    @MainActor
    private func waitUntil(
        _ condition: () -> Bool, within seconds: Double = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func disposableVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftProposalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
