import Foundation
import Testing
@testable import HeftCore

/// The iOS editor's loading and saving, with reads and writes held back so
/// that what overtakes them can be arranged rather than hoped for.
@MainActor
@Suite("Note sync")
struct NoteSyncTests {

    /// Suspends whoever passes until it is opened.
    actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func pass() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                watchers.forEach { $0.resume() }
                watchers = []
            }
        }

        /// Returns once someone is held at the gate.
        func arrival() async {
            guard waiting.isEmpty, !opened else { return }
            await withCheckedContinuation { watchers.append($0) }
        }

        func open() {
            opened = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// Real files, with chosen calls held at a gate: a read is held after it
    /// has read, as one waiting on iCloud returns what it found earlier; a
    /// write is held before it writes.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String: Int] = [:]
        private var gates: [String: Gate] = [:]
        private var failing = false

        /// Makes writes fail, as a full disk would, or work again.
        func failWrites(_ fail: Bool = true) { lock.withLock { failing = fail } }
        private var fails: Bool { lock.withLock { failing } }

        func hold(_ kind: String, call: Int) -> Gate {
            let gate = Gate()
            lock.withLock { gates["\(kind)#\(call)"] = gate }
            return gate
        }

        private func next(_ kind: String) -> Gate? {
            lock.withLock {
                calls[kind, default: 0] += 1
                return gates["\(kind)#\(calls[kind]!)"]
            }
        }

        var storage: NoteSync.Storage {
            NoteSync.Storage(
                read: { url in
                    let gate = self.next("read")
                    let text = try NoteFile.read(url)
                    await gate?.pass()
                    return text
                },
                write: { text, url, original in
                    await self.next("write")?.pass()
                    if self.fails { throw CocoaError(.fileWriteOutOfSpace) }
                    try NoteFile.write(text, to: url, replacing: original)
                },
                overwrite: { text, url in
                    await self.next("overwrite")?.pass()
                    if self.fails { throw CocoaError(.fileWriteOutOfSpace) }
                    try NoteFile.overwrite(text, at: url)
                }
            )
        }
    }

    @MainActor
    final class Vault: NoteSyncVault {
        init(_ folder: URL) { self.folder = folder }
        var root: URL? { folder }
        let folder: URL
        func noteURL(at path: String) -> URL? { folder.appendingPathComponent(path) }
        private(set) var writes = 0
        func noteWritten() { writes += 1 }
    }

    private func vault(_ text: String) throws -> (Vault, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Note.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (Vault(root), url)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Leaving the app asks for a save on inactive and again on background;
    /// the second must not start from the base the first is replacing.
    @Test("A save started during another waits for it")
    func overlappingSaves() async throws {
        let (vault, url) = try vault("old\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        let first = probe.hold("write", call: 1)

        sync.edited("one\n")
        let firstSave = Task { await sync.saveNow() }
        await first.arrival()
        sync.edited("one two\n")
        let secondSave = Task { await sync.saveNow() }
        await Task.yield()
        await first.open()
        await firstSave.value
        await secondSave.value

        #expect(!sync.conflict, "the second save took the first's text for a change from elsewhere")
        #expect(try contents(url) == "one two\n")
    }

    /// A rescan's read can wait on iCloud for seconds; typing that starts
    /// meanwhile is based on the text on screen, not on what the read finds.
    @Test("A read that typing overtook is not taken as the base")
    func readOvertakenByTyping() async throws {
        let (vault, url) = try vault("old\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        let slow = probe.hold("read", call: 2)

        let rescan = Task { await sync.load(in: vault) }
        await slow.arrival()
        sync.edited("old mine\n")
        await slow.open()
        await rescan.value
        await sync.saveNow()

        #expect(sync.source == "old\n", "the late read replaced the text being typed into")
        #expect(sync.conflict, "the typing was saved over a file it never saw")
        #expect(try contents(url) == "theirs\n")
    }

    /// Two rescans in a row: the older read finishing last must not put
    /// its text back.
    @Test("An older read finishing last is dropped")
    func readsOutOfOrder() async throws {
        let (vault, url) = try vault("first\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        let slow = probe.hold("read", call: 1)

        let older = Task { await sync.load(in: vault) }
        await slow.arrival()
        try "second\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.load(in: vault)
        await slow.open()
        await older.value

        #expect(sync.source == "second\n")
    }

    /// A read begun before a save holds the text the save replaced.
    @Test("A read begun before a save does not undo it")
    func readBeforeSave() async throws {
        let (vault, url) = try vault("old\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        let slow = probe.hold("read", call: 2)

        let rescan = Task { await sync.load(in: vault) }
        await slow.arrival()
        sync.edited("mine\n")
        await sync.saveNow()
        await slow.open()
        await rescan.value

        #expect(sync.source == "mine\n", "the old read put the saved text back")
        #expect(try contents(url) == "mine\n")
        sync.edited("mine more\n")
        await sync.saveNow()
        #expect(!sync.conflict)
        #expect(try contents(url) == "mine more\n")
    }

    /// Settling a conflict writes what was typed when Keep Mine was tapped;
    /// typing during that write is still to be saved.
    @Test("Typing during Keep Mine is saved after it")
    func typingDuringKeepMine() async throws {
        let (vault, url) = try vault("old\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("mine\n")
        await sync.saveNow()
        #expect(sync.conflict)
        // The refused save, then Keep Mine's.
        let slow = probe.hold("write", call: 2)

        let keep = Task { await sync.keepMine() }
        await slow.arrival()
        sync.edited("mine more\n")
        await slow.open()
        await keep.value
        await sync.saveNow()

        #expect(!sync.conflict)
        #expect(try contents(url) == "mine more\n", "the typing made during Keep Mine was dropped")
    }

    /// A note renamed or deleted on another device: saving stops and asks,
    /// rather than failing on every pause in typing, and the typing stays
    /// for Keep Mine to write back.
    @Test("A note gone from disk is a conflict, not a failed save")
    func noteGoneFromDisk() async throws {
        let (vault, url) = try vault("old\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try FileManager.default.removeItem(at: url)

        sync.edited("old mine\n")
        await sync.saveNow()

        #expect(sync.conflict)
        #expect(sync.saveError == nil, "every pause in typing reported a failed save")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await sync.keepMine()
        #expect(try contents(url) == "old mine\n")
    }

    // MARK: Captures

    /// A line filed into the note from elsewhere, a capture from the Mac,
    /// a share, Siri, while it is being typed in: different lines, so the
    /// save merges them rather than stopping for the reader.
    @Test("A capture landing before a save is merged into it")
    func captureMergedIntoSave() async throws {
        let (vault, url) = try vault("a\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        let before = sync.revision
        try "a\ncaptured\n".write(to: url, atomically: true, encoding: .utf8)

        sync.edited("a typed\n")
        await sync.saveNow()

        #expect(!sync.conflict, "a capture on another line stopped saving")
        #expect(try contents(url) == "a typed\ncaptured\n")
        #expect(sync.source == "a typed\ncaptured\n")
        #expect(sync.revision == before + 1, "the editor was not given the merged text")
        #expect(!sync.hasUnsavedText)
        #expect(draft(vault) == nil)
    }

    /// The file can change again between the merge's read and its write;
    /// that write is compared too, and merges again rather than replacing it.
    @Test("A capture landing during a merge is merged as well")
    func captureDuringMerge() async throws {
        let (vault, url) = try vault("a\n")
        defer { try? FileManager.default.removeItem(at: vault.folder) }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        try "a\none\n".write(to: url, atomically: true, encoding: .utf8)
        let mergeRead = probe.hold("read", call: 2)

        sync.edited("a typed\n")
        let save = Task { await sync.saveNow() }
        await mergeRead.arrival()
        try "a\none\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        await mergeRead.open()
        await save.value

        #expect(!sync.conflict)
        #expect(try contents(url) == "a typed\none\ntwo\n", "the second capture was written over")
    }

    /// Typing goes on while the merge is written; it is on top of the
    /// buffer that was merged, so the capture is carried into it.
    @Test("Typing during a merged save keeps the capture")
    func typingDuringMergedSave() async throws {
        let (vault, url) = try vault("a\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        try "a\ncaptured\n".write(to: url, atomically: true, encoding: .utf8)
        let mergedWrite = probe.hold("write", call: 2)

        sync.edited("a typed\n")
        let save = Task { await sync.saveNow() }
        await mergedWrite.arrival()
        sync.edited("a typed more\n")
        await mergedWrite.open()
        await save.value

        #expect(sync.source == "a typed more\ncaptured\n", "the editor lost the capture or the typing")
        #expect(sync.hasUnsavedText)
        await sync.saveNow()
        #expect(!sync.conflict)
        #expect(try contents(url) == "a typed more\ncaptured\n")
    }

    /// Changes to the same line are a choice only the reader can make.
    @Test("A change on the line being typed still asks")
    func overlappingChangeAsks() async throws {
        let (vault, url) = try vault("a\nb\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "a\nb theirs\n".write(to: url, atomically: true, encoding: .utf8)

        sync.edited("a\nb mine\n")
        await sync.saveNow()

        #expect(sync.conflict)
        #expect(try contents(url) == "a\nb theirs\n")
    }

    /// The reader decides against the version the banner was raised for;
    /// a capture filed while they decided is not part of that choice.
    @Test("A capture landing while the conflict is up survives Keep Mine")
    func captureDuringConflictKept() async throws {
        let (vault, url) = try vault("a\nb\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "a\nb theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("a\nb mine\n")
        await sync.saveNow()
        #expect(sync.conflict)

        try "a\nb theirs\ncaptured\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.keepMine()

        #expect(!sync.conflict)
        #expect(try contents(url) == "a\nb mine\ncaptured\n", "Keep Mine wrote over the capture")
        #expect(sync.source == "a\nb mine\ncaptured\n")
    }

    /// A newer change to the same lines is one the reader has not seen.
    @Test("A change to the same lines after the banner asks again")
    func newerConflictAsksAgain() async throws {
        let (vault, url) = try vault("a\nb\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "a\nb theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("a\nb mine\n")
        await sync.saveNow()

        try "a\nb theirs again\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.keepMine()

        #expect(sync.conflict, "Keep Mine wrote over a version the reader never saw")
        #expect(try contents(url) == "a\nb theirs again\n")
        try "a\nb theirs again\nlater\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.keepMine()
        #expect(try contents(url) == "a\nb mine\nlater\n")
    }

    /// The editor takes a new revision on its next update, and a keystroke
    /// can come first: it is typed into the text that revision replaced.
    /// Taken as it was, it put that text back and its save dropped the
    /// capture from the file, compared against the merge that held it.
    @Test("A keystroke before the editor took a merge is carried onto it")
    func keystrokeBeforeMergeTaken() async throws {
        let (vault, url) = try vault("a\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        let shown = sync.revision
        try "a\ncaptured\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("a typed\n", at: shown)
        await sync.saveNow()
        #expect(sync.revision == shown + 1)

        sync.edited("a typed!\n", at: shown)
        #expect(sync.source == "a typed!\ncaptured\n", "the keystroke put the unmerged text back")
        #expect(sync.revision == shown + 2, "the editor was not given the carried text")
        await sync.saveNow()
        #expect(!sync.conflict)
        #expect(try contents(url) == "a typed!\ncaptured\n")
    }

    /// The same for a plain reload: a line the Mac wrote is not dropped
    /// by a keystroke on the text from before it.
    @Test("A keystroke before the editor took a reload is carried onto it")
    func keystrokeBeforeReloadTaken() async throws {
        let (vault, url) = try vault("a\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        let shown = sync.revision
        try "a\nfrom the Mac\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.load(in: vault)

        sync.edited("a!\n", at: shown)
        await sync.saveNow()

        #expect(try contents(url) == "a!\nfrom the Mac\n", "the reloaded line was written over")
        #expect(sync.source == "a!\nfrom the Mac\n")
    }

    /// Use Theirs drops what was typed; a keystroke on the dropped text
    /// before the editor takes theirs carries only itself.
    @Test("A keystroke before the editor took Use Theirs carries only itself")
    func keystrokeBeforeUseTheirsTaken() async throws {
        let (vault, url) = try vault("a\nb\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        let shown = sync.revision
        try "a\nb theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("a\nb mine\n", at: shown)
        await sync.saveNow()
        await sync.useTheirs()

        sync.edited("a!\nb mine\n", at: shown)
        await sync.saveNow()

        #expect(try contents(url) == "a!\nb theirs\n", "Use Theirs brought the dropped typing back")
    }

    @Test("A keystroke on a line the reload changed asks")
    func keystrokeOnReloadedLineAsks() async throws {
        let (vault, url) = try vault("a\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        let shown = sync.revision
        try "a mac\n".write(to: url, atomically: true, encoding: .utf8)
        await sync.load(in: vault)

        sync.edited("a!\n", at: shown)
        await sync.saveNow()

        #expect(sync.conflict, "the keystroke was saved over the reloaded line unasked")
        #expect(sync.source == "a!\n", "the keystroke vanished from the screen")
        #expect(try contents(url) == "a mac\n")
        await sync.keepMine()
        #expect(try contents(url) == "a!\n")
    }

    // MARK: Caret

    /// A capture filed above the caret moves the reader's line down; the
    /// caret goes with it rather than staying at an offset now on another
    /// line.
    @Test("The caret follows its text when lines arrive above it")
    func caretFollowsText() {
        let old = "top\ntyping here\n"
        let caret = ("top\ntyping" as NSString).length
        #expect(NoteSync.caret(caret, from: old, to: "top\ncaptured\ntyping here\n")
                == ("top\ncaptured\ntyping" as NSString).length)
        #expect(NoteSync.caret(caret, from: old, to: old + "captured\n") == caret)
        #expect(NoteSync.caret(caret, from: old, to: "other\n") == ("other\n" as NSString).length)
    }

    // MARK: Drafts

    private func draft(_ vault: Vault) -> String? {
        DraftStore.draft(vault: vault.folder, relativePath: "Note.md")
    }

    /// Saving stops in a conflict, and leaving the note or the app being
    /// ended in the background then lost the typing: it was only in memory.
    @Test("Typing in a conflict is kept as a draft until it is settled")
    func conflictKeepsDraft() async throws {
        let (vault, url) = try vault("old\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)

        sync.edited("mine\n")
        await sync.saveNow()
        #expect(sync.conflict)
        #expect(draft(vault) == "mine\n")
        sync.edited("mine more\n")
        await sync.saveNow()
        #expect(draft(vault) == "mine more\n", "typing after the conflict was not kept")

        await sync.keepMine()
        #expect(draft(vault) == nil, "the draft outlived Keep Mine")
    }

    @Test("Use Theirs drops the draft with the typing")
    func useTheirsDropsDraft() async throws {
        let (vault, url) = try vault("old\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("mine\n")
        await sync.saveNow()
        #expect(draft(vault) != nil)

        await sync.useTheirs()
        #expect(draft(vault) == nil)
        #expect(sync.source == "theirs\n")
    }

    @Test("A failed save keeps a draft, and the next good one drops it")
    func failedSaveKeepsDraft() async throws {
        let (vault, url) = try vault("old\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let probe = Probe()
        let sync = NoteSync(path: "Note.md", storage: probe.storage)
        await sync.load(in: vault)
        probe.failWrites()

        sync.edited("mine\n")
        await sync.saveNow()
        #expect(sync.saveError != nil)
        #expect(draft(vault) == "mine\n", "a failed save left the typing only in memory")

        probe.failWrites(false)
        await sync.saveNow()
        #expect(try contents(url) == "mine\n")
        #expect(draft(vault) == nil, "the draft outlived the save")
    }

    /// The next time the note opens, the draft is put where notes are, as
    /// the Mac recovers one, and the note itself is left alone.
    @Test("A leftover draft becomes a recovery note beside the note")
    func draftRecovered() async throws {
        let (vault, url) = try vault("theirs\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        DraftStore.write("mine\n", vault: vault.folder, relativePath: "Note.md")

        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)

        let recovery = vault.folder.appendingPathComponent("Note (Heft Recovery).md")
        #expect(try contents(recovery) == "mine\n")
        #expect(try contents(url) == "theirs\n")
        #expect(sync.source == "theirs\n")
        #expect(draft(vault) == nil)
        #expect(vault.writes == 1, "the vault was not told of the recovery note")
    }

    @Test("A leftover draft that matches the note is only dropped")
    func matchingDraftDropped() async throws {
        let (vault, _) = try vault("same\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        DraftStore.write("same\n", vault: vault.folder, relativePath: "Note.md")

        await NoteSync(path: "Note.md", storage: Probe().storage).load(in: vault)

        #expect(vault.writes == 0, "a rescan was asked for with nothing written")
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.folder.path)
        #expect(names == ["Note.md"])
        #expect(draft(vault) == nil)
    }

    /// A note being deleted keeps nothing, or its draft would come back as
    /// a recovery note when another note takes the name.
    @Test("Abandoned typing leaves no draft")
    func abandonDropsDraft() async throws {
        let (vault, url) = try vault("old\n")
        defer {
            try? FileManager.default.removeItem(at: vault.folder)
            DraftStore.discard(vault: vault.folder, relativePath: "Note.md")
        }
        let sync = NoteSync(path: "Note.md", storage: Probe().storage)
        await sync.load(in: vault)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        sync.edited("mine\n")
        await sync.saveNow()
        #expect(draft(vault) != nil)

        sync.abandon()
        #expect(draft(vault) == nil)
    }
}
