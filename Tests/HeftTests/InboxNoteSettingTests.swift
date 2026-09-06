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

    @Test("A capture with no window goes to the chosen vault while it is there, else the one opened last")
    func chosenVaultOutranksTheLastOpened() throws {
        let opened = try vault()
        let chosen = try vault()
        let defaults = HeftDefaults.shared
        let previousLast = defaults.string(forKey: CaptureVaultPreference.defaultsKey)
        let previousChosen = defaults.string(forKey: CaptureVaultPreference.chosenKey)
        defer {
            defaults.set(previousLast, forKey: CaptureVaultPreference.defaultsKey)
            defaults.set(previousChosen, forKey: CaptureVaultPreference.chosenKey)
            try? FileManager.default.removeItem(at: opened)
            try? FileManager.default.removeItem(at: chosen)
        }
        defaults.set(opened.path, forKey: CaptureVaultPreference.defaultsKey)
        CaptureVaultPreference.choose(nil)
        #expect(CaptureVaultPreference.url == opened.standardizedFileURL)

        CaptureVaultPreference.choose(chosen)
        #expect(CaptureVaultPreference.url == chosen.standardizedFileURL)
        #expect(CaptureVaultPreference.chosenPath == chosen.standardizedFileURL.path)

        try FileManager.default.removeItem(at: chosen)
        #expect(CaptureVaultPreference.url == opened.standardizedFileURL, "a chosen vault that is away is not captured into")
        #expect(CaptureVaultPreference.chosenPath != nil, "but the choice is kept for when it is back")
    }

    @Test("Choosing a capture vault does not change which vault a cold start opens")
    @MainActor
    func chosenVaultDoesNotBecomeTheLaunchVault() throws {
        let opened = try vault()
        let chosen = try vault()
        let defaults = HeftDefaults.shared
        let previousLast = defaults.string(forKey: CaptureVaultPreference.defaultsKey)
        let previousChosen = defaults.string(forKey: CaptureVaultPreference.chosenKey)
        defer {
            defaults.set(previousLast, forKey: CaptureVaultPreference.defaultsKey)
            defaults.set(previousChosen, forKey: CaptureVaultPreference.chosenKey)
            try? FileManager.default.removeItem(at: opened)
            try? FileManager.default.removeItem(at: chosen)
        }
        defaults.set(opened.path, forKey: CaptureVaultPreference.defaultsKey)
        CaptureVaultPreference.choose(chosen)
        #expect(VaultRegistry().lastVaultURL == opened.standardizedFileURL)
    }
}
