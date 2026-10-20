import Foundation
import Testing
@testable import HeftCore
@testable import HeftiOSVault

/// Shares the iOS share extension could not file itself, queued in the App
/// Group and filed by the app on its next scan.
@Suite("Share queue")
struct ShareQueueTests {

    private func folders(_ files: [String: String] = [:]) throws -> (queue: URL, vault: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-queue-\(UUID().uuidString)")
        let queue = base.appendingPathComponent("Pending", isDirectory: true)
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for (path, text) in files {
            try text.write(to: vault.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return (queue, vault)
    }

    private func queued(_ queue: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
    }

    /// Every rescan drains first, and rescans overlap.
    @Test("Drains running at once file each share once")
    func concurrentDrains() throws {
        let (queue, vault) = try folders(["Roof.md": "the roof\n"])
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<20 {
            try SharedVault.enqueue(.init(text: "line \(n)", destination: .note("Roof.md"),
                                          date: start.addingTimeInterval(Double(n))), in: queue)
        }

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            SharedVault.drainQueue(from: queue, into: vault)
        }

        let text = try String(contentsOf: vault.appendingPathComponent("Roof.md"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("line ") }
        #expect(lines.count == 20, "a share was filed more than once")
        #expect(queued(queue).isEmpty)
    }

    private func notes(in vault: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.filter { $0.hasSuffix(".md") }.map {
            ($0, (try? String(contentsOf: vault.appendingPathComponent($0), encoding: .utf8)) ?? "")
        })
    }

    /// Aimed at a note renamed or deleted since: it stayed queued for good,
    /// retried on every scan and never seen. The inbox is where a share
    /// with no other home goes.
    @Test("A share for a note that is gone is filed to the inbox")
    func missingNoteGoesToInbox() throws {
        let (queue, vault) = try folders(["Roof.md": "the roof\n"])
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        try SharedVault.enqueue(.init(text: "about the gutters", destination: .note("Gone.md"),
                                      date: Date()), in: queue)

        #expect(SharedVault.drainQueue(from: queue, into: vault) == 1)

        #expect(queued(queue).isEmpty, "the share stays queued")
        let filed = notes(in: vault).filter { $0.value.contains("about the gutters") }
        #expect(filed.count == 1)
        #expect(filed.keys.first != "Gone.md", "the gone note was made again")
        #expect(notes(in: vault)["Roof.md"] == "the roof\n")
    }

    /// On iOS a note iCloud has not brought down yet is a placeholder; the
    /// scan asks for it, and the share waits for it rather than moving.
    @Test("A share for a note still in iCloud waits for it")
    func evictedNoteWaits() throws {
        let (queue, vault) = try folders()
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        try Data().write(to: vault.appendingPathComponent(".Roof.md.icloud"))
        try SharedVault.enqueue(.init(text: "about the gutters", destination: .note("Roof.md"),
                                      date: Date()), in: queue)

        #expect(SharedVault.drainQueue(from: queue, into: vault) == 0)

        #expect(queued(queue).count == 1)
        #expect(notes(in: vault).isEmpty)
    }

    /// Filed when the app next runs, a share still belongs where it would
    /// have gone when it was made: its own day in the inbox, and its own
    /// time among the daily note's lines.
    @Test("A share filed late goes in by its day and time")
    func lateShareKeepsTimeOrder() throws {
        let inbox = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n\n## 2026-10-17\n- 10:00 b\n"
        let (queue, vault) = try folders(["Inbox.md": inbox])
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let shared = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 10, day: 18, hour: 12, minute: 0)))
        let settings = ObsidianSettings.load(vaultRoot: vault)
        let daily = vault.appendingPathComponent(
            DailyNotes(vaultRoot: vault, settings: settings).relativePath(for: shared))
        try FileManager.default.createDirectory(
            at: daily.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Day\n\n- 09:00 x\n- 15:00 y\n".write(to: daily, atomically: true, encoding: .utf8)
        try SharedVault.enqueue(.init(text: "the share", destination: .inbox, date: shared), in: queue)
        try SharedVault.enqueue(.init(text: "the share", destination: .today, date: shared), in: queue)

        #expect(SharedVault.drainQueue(from: queue, into: vault) == 2)

        let filed = try String(contentsOf: vault.appendingPathComponent("Inbox.md"), encoding: .utf8)
        let headings = filed.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## 2026-10-20", "## 2026-10-18", "## 2026-10-17"])
        let lines = try String(contentsOf: daily, encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines == ["- 09:00 x", "- 12:00 the share", "- 15:00 y"])
    }
}
