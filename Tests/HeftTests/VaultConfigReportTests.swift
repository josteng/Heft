import Foundation
import HeftCore
import Testing

/// `heft config` names today's note by the vault's own rule and says
/// whether it exists, so an agent asked to add to today's note neither
/// applies the date format itself nor creates the note by asking.
@Suite("The config report")
struct VaultConfigReportTests {
    @Test("Today's note is named by the vault's rule, and reported present only once it is")
    func todaysNote() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-config-\(UUID().uuidString)", isDirectory: true)
        let obsidian = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"folder": "Journal", "format": "YYYY-MM-DD"}"#
            .write(to: obsidian.appendingPathComponent("daily-notes.json"), atomically: true, encoding: .utf8)
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 6; parts.hour = 12
        let day = try #require(Calendar.current.date(from: parts))

        let before = VaultConfigReport.make(vaultRoot: root, noteCount: 0, on: day)
        #expect(before["todayNote"] as? String == "Journal/2026-09-06.md")
        #expect(before["todayNoteExists"] as? Bool == false)
        #expect(before["inboxNote"] as? String == "Inbox.md")

        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try "# Today\n".write(to: journal.appendingPathComponent("2026-09-06.md"), atomically: true, encoding: .utf8)
        let after = VaultConfigReport.make(vaultRoot: root, noteCount: 1, on: day)
        #expect(after["todayNoteExists"] as? Bool == true)
    }
}
