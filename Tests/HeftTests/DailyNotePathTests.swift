import Foundation
import HeftCore
import Testing

/// Where a daily note may be written: inside the vault, wherever the system
/// says the vault is.
@Suite("Daily note paths")
struct DailyNotePathTests {

    /// A folder made for the test, and the same folder spelled through
    /// `/private`, as iOS hands over every vault: `/private/var/mobile/…`.
    private func vault() throws -> (made: URL, viaPrivate: URL) {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-daily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // Spelled out: `resolvingSymlinksInPath` drops the `/private` too.
        let path = made.path.hasPrefix("/private/") ? made.path : "/private" + made.path
        return (made, URL(fileURLWithPath: path, isDirectory: true))
    }

    @Test("A daily note not yet written is inside a vault reached through /private")
    func privatePrefix() throws {
        let (made, root) = try vault()
        defer { try? FileManager.default.removeItem(at: made) }
        #expect(root.path.hasPrefix("/private/"), "the test needs a /private path to mean anything")
        var settings = ObsidianSettings()
        settings.dailyNotesFolder = "Daily Notes"
        settings.dailyNotesFolderIsConfigured = true
        let daily = DailyNotes(vaultRoot: root, settings: settings)
        let day = Date(timeIntervalSince1970: 1_793_000_000)

        let url = try daily.ensureNote(for: day)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A folder setting that climbs out of the vault is still refused")
    func climbingOut() throws {
        let (made, root) = try vault()
        defer { try? FileManager.default.removeItem(at: made) }
        var settings = ObsidianSettings()
        settings.dailyNotesFolder = "../outside"
        settings.dailyNotesFolderIsConfigured = true
        let daily = DailyNotes(vaultRoot: root, settings: settings)

        #expect(throws: DailyNoteCaptureError.self) {
            try daily.checkedURL(for: Date(timeIntervalSince1970: 1_793_000_000))
        }
    }
}
