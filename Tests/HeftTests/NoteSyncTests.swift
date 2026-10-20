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
                    try NoteFile.write(text, to: url, replacing: original)
                },
                overwrite: { text, url in
                    await self.next("overwrite")?.pass()
                    try NoteFile.overwrite(text, at: url)
                }
            )
        }
    }

    @MainActor
    final class Vault: NoteSyncVault {
        let root: URL
        init(_ root: URL) { self.root = root }
        func noteURL(at path: String) -> URL? { root.appendingPathComponent(path) }
        func noteWritten() {}
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
        defer { try? FileManager.default.removeItem(at: vault.root) }
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
        defer { try? FileManager.default.removeItem(at: vault.root) }
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
        defer { try? FileManager.default.removeItem(at: vault.root) }
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
        defer { try? FileManager.default.removeItem(at: vault.root) }
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
}
