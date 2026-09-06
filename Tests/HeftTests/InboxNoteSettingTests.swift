import Foundation
import HeftCore
import Testing
@testable import Heft

/// The inbox is Inbox.md at the vault root until the reader names another
/// note for that vault; Spotlight, with no window open, reads the same answer
/// through the same core type the app uses.
@Suite("The inbox note setting", .serialized)
struct InboxNoteSettingTests {
    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-inbox-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Inbox.md until named, per vault, and only a path inside the vault counts")
    func resolvesPerVault() throws {
        let root = try vault()
        let other = try vault()
        defer {
            InboxNotePreference.set(nil, for: root)
            InboxNotePreference.set(nil, for: other)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        #expect(InboxNotePreference.path(for: root) == "Inbox.md")

        InboxNotePreference.set("Notes/Inbox", for: root)
        #expect(InboxNotePreference.path(for: root) == "Notes/Inbox.md", "a missing .md is added")
        #expect(InboxNotePreference.stored(for: root) == "Notes/Inbox", "what was typed is kept for the field")
        #expect(InboxNotePreference.path(for: other) == "Inbox.md", "another vault is untouched")

        InboxNotePreference.set("../Elsewhere.md", for: root)
        #expect(InboxNotePreference.path(for: root) == "Inbox.md", "a path outside the vault falls back")
        InboxNotePreference.set("/Absolute.md", for: root)
        #expect(InboxNotePreference.path(for: root) == "Inbox.md")
        InboxNotePreference.set("  ", for: root)
        #expect(InboxNotePreference.stored(for: root) == nil, "blank clears the setting")
    }

    @Test("A capture with no window, the way Spotlight does it, lands in the named note and makes its folder")
    func spotlightCaptureFollowsTheSetting() throws {
        let root = try vault()
        defer {
            InboxNotePreference.set(nil, for: root)
            try? FileManager.default.removeItem(at: root)
        }
        InboxNotePreference.set("Notes/Captures", for: root)

        let url = try InboxCapture(vaultRoot: root).capture("Remember the useful thing")
        #expect(url.path.hasSuffix("/Notes/Captures.md"))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("# Captures\n"), "a fresh inbox is titled after its file")
        #expect(written.contains("Remember the useful thing"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox.md").path))

        let opened = try InboxCapture(vaultRoot: root).ensureFile()
        #expect(opened == url, "Open Inbox and capture agree on the file")
    }
}
