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

    /// Accepting hunks one at a time is the most deliberate attention a note
    /// can get: every change was read and answered. It counted for nothing,
    /// while opening a note and looking away counted fully.
    @Test("Reviewing a proposal counts as attention, once per proposal")
    @MainActor
    func reviewCountsAsAttention() async throws {
        let root = try disposableVault()
        defer {
            try? FileManager.default.removeItem(at: root)
            HeftDefaults.shared.removeObject(
                forKey: "dev.stenglein.Heft.frecency.notes.\(root.path)"
            )
        }

        let note = root.appendingPathComponent("Note.md")
        let original = "alpha\n\nbeta\n\ngamma\n"
        try original.write(to: note, atomically: true, encoding: .utf8)
        try ProposalStore.write(
            Proposal(
                notePath: "Note.md", base: original, body: "ALPHA\n\nbeta\n\nGAMMA\n",
                agent: "claude-code", summary: "Shout at both ends"
            ),
            in: root
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        model.refreshProposals()
        let pending = try #require(model.proposalsForCurrentNote.first)
        let hunks = pending.diff(against: model.currentText(for: pending)).hunks
        #expect(hunks.count == 2)

        // Opening the note already counted once; the review is what is being
        // measured here, so the comparison is against that.
        let opened = try #require(model.noteFrecency?.score("Note.md"))
        model.decide(pending, hunk: hunks[0].id, accept: true)
        let afterFirst = try #require(model.noteFrecency?.score("Note.md"))
        #expect(afterFirst > opened, "deciding a hunk is attention")

        // Once per proposal, not once per hunk: a ten-hunk proposal must not
        // outweigh ten mornings of opening the note. `settle` keeps the id.
        let remaining = try #require(model.proposalsForCurrentNote.first)
        #expect(remaining.id == pending.id)
        model.decide(remaining, hunk: remaining.diff(against: model.text).hunks[0].id, accept: false)
        // With a tolerance: the score decays continuously, so two reads a
        // moment apart differ far below the size of a use.
        let afterSecond = try #require(model.noteFrecency?.score("Note.md"))
        #expect(abs(afterSecond - afterFirst) < 0.01, "a second hunk must not count again")

        model.closeWorkspace()
    }

    // MARK: - The review centre

    @Test("A proposal for a note that does not exist can be reviewed and creates it")
    @MainActor
    func createProposalThroughTheEditor() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "anchor".write(
            to: root.appendingPathComponent("Anchor.md"), atomically: true, encoding: .utf8
        )
        try ProposalStore.write(
            Proposal(
                notePath: "Heft/Before Release.md", base: nil, body: "# TODO\n\n- one\n",
                agent: "claude-code", summary: "Add the release list", kind: .create
            ),
            in: root
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Anchor.md")
        )
        defer { model.closeWorkspace() }
        model.refreshProposals()

        // The bug this closes: it is not the open note's, so the banner never
        // showed it and there was no other way in.
        #expect(model.proposalsForCurrentNote.isEmpty)
        let waiting = try #require(model.pendingProposals.edits.first)
        #expect(waiting.kind == .create)

        model.review(waiting)
        #expect(model.reviewing?.id == waiting.id, "it is reviewed where it stands")
        model.acceptAll(waiting)

        let created = await waitUntil {
            (try? String(
                contentsOf: root.appendingPathComponent("Heft/Before Release.md"), encoding: .utf8
            )) == "# TODO\n\n- one\n"
        }
        #expect(created, "the folder it needed was made and the note written")
        #expect(model.proposals.isEmpty)
    }

    @Test("A banner over a note never offers to delete or move it")
    @MainActor
    func structuralProposalsStayOutOfTheBanner() throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "body\n".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )
        try ProposalStore.write(
            Proposal(
                notePath: "Note.md", base: nil, body: "",
                agent: "t", summary: "Drop it", kind: .delete
            ),
            in: root
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        defer { model.closeWorkspace() }
        model.refreshProposals()

        // It names the note being read, so it would land in the banner — a bar
        // over the page offering to delete the page. It belongs in the centre.
        #expect(model.proposalsForCurrentNote.isEmpty)
        #expect(model.pendingProposals.structural.count == 1)
    }

    @Test("A move proposal repoints the links into the file it moves")
    @MainActor
    func moveProposalRepointsLinks() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Old"), withIntermediateDirectories: true
        )
        try "target".write(
            to: root.appendingPathComponent("Old/Target.md"), atomically: true, encoding: .utf8
        )
        try "See [[Old/Target]]\n".write(
            to: root.appendingPathComponent("Pointer.md"), atomically: true, encoding: .utf8
        )
        try ProposalStore.write(
            Proposal(
                notePath: "Old/Target.md", base: nil, body: "",
                agent: "claude-code", summary: "Move it into New",
                kind: .move, destination: "New/Target.md"
            ),
            in: root
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Pointer.md")
        )
        defer { model.closeWorkspace() }
        // The links come from the index, so the scan has to have finished:
        // moving with an empty index moves the file and repoints nothing.
        // And the open note is rewritten from its *buffer*, so that has to
        // have arrived too, or the rewrite is skipped as a note that changed
        // between the plan and the write.
        // Wait for the exact precondition rather than for a note count: the
        // repointing comes from the link index, and the open note is rewritten
        // from its buffer, so both have to have arrived.
        #expect(await waitUntil {
            !model.index.backlinks(to: "Old/Target.md").isEmpty && !model.text.isEmpty
        })
        model.refreshProposals()

        // Structural changes are not the banner's business: a banner over the
        // note offering to delete or move it is the wrong place to decide.
        #expect(model.proposalsForCurrentNote.isEmpty)
        let move = try #require(model.pendingProposals.structural.first)
        model.applyStructural(move)

        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("New/Target.md").path
        ), "the folder it named was made")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Old/Target.md").path
        ))
        // The open note is repointed through its buffer, so the new text
        // reaches disk by the ordinary autosave rather than under the editor.
        #expect(model.text.contains("New/Target"), "got \(model.text)")
        let repointed = await waitUntil {
            ((try? String(
                contentsOf: root.appendingPathComponent("Pointer.md"), encoding: .utf8
            )) ?? "").contains("New/Target")
        }
        #expect(repointed)
        #expect(model.proposals.isEmpty)
    }

    @Test("A group is one change, and its edits land before its moves")
    @MainActor
    func groupAppliesInAWorkableOrder() async throws {
        let root = try disposableVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\n".write(
            to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8
        )
        try "one\n".write(
            to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8
        )
        let group = Proposal.Group(summary: "Rename the concept")
        try ProposalStore.write(
            Proposal(
                id: "move-b", notePath: "B.md", base: nil, body: "",
                agent: "t", summary: "Move B", kind: .move,
                destination: "Renamed.md", group: group
            ),
            in: root
        )
        try ProposalStore.write(
            Proposal(
                id: "edit-b", notePath: "B.md", base: "one\n", body: "two\n",
                agent: "t", summary: "Reword B", group: group
            ),
            in: root
        )
        try ProposalStore.write(
            Proposal(
                id: "edit-a", notePath: "A.md", base: "one\n", body: "two\n",
                agent: "t", summary: "Reword A", group: group
            ),
            in: root
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "A.md")
        )
        defer { model.closeWorkspace() }
        #expect(await waitUntil { model.index.notes.count == 2 && !model.text.isEmpty })
        model.refreshProposals()

        let waiting = try #require(model.pendingProposals.groups.first)
        #expect(waiting.proposals.count == 3)
        // The banner over A says its change is part of something larger,
        // rather than a second banner appearing above it.
        let here = try #require(model.proposalsForCurrentNote.first)
        #expect(model.group(of: here)?.summary == "Rename the concept")

        model.acceptGroup(waiting)

        // The move runs last, or the edit to B would have been written to a
        // path that no longer exists.
        let settled = await waitUntil {
            (try? String(contentsOf: root.appendingPathComponent("Renamed.md"), encoding: .utf8))
                == "two\n"
        }
        #expect(settled, "B was reworded and then moved")
        #expect(try String(contentsOf: root.appendingPathComponent("A.md"), encoding: .utf8)
            == "two\n")
        #expect(model.proposals.isEmpty)
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
