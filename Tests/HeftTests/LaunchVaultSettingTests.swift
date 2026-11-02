import Foundation
import HeftCore
import Testing
@testable import Heft

/// A start with nothing to restore opens the vault chosen in Settings ▸
/// Startup while it is there, else the vault opened last; and choosing where
/// captures go is a different question with a different answer. Each test
/// has its own store: the keys are app-wide, and suites sharing the real
/// one raced once the suite got fast enough for them to overlap.
@Suite("The launch vault setting")
struct LaunchVaultSettingTests {
    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-launch-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withStore(_ body: (UserDefaults, URL, URL) throws -> Void) throws {
        let name = "heft-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let opened = try vault()
        let chosen = try vault()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: opened)
            try? FileManager.default.removeItem(at: chosen)
        }
        defaults.set(opened.path, forKey: CaptureVaultPreference.defaultsKey)
        try body(defaults, opened, chosen)
    }

    @Test("The chosen vault opens while it is there, else the one opened last")
    func chosenVaultOpens() throws {
        try withStore { defaults, opened, chosen in
            #expect(LaunchVaultPreference.url(in: defaults) == opened.standardizedFileURL)
            LaunchVaultPreference.choose(chosen, in: defaults)
            #expect(LaunchVaultPreference.url(in: defaults) == chosen.standardizedFileURL)
            try FileManager.default.removeItem(at: chosen)
            #expect(LaunchVaultPreference.url(in: defaults) == opened.standardizedFileURL, "a chosen vault that is away is not opened")
            #expect(LaunchVaultPreference.chosenPath(in: defaults) != nil, "but the choice is kept for when it is back")
        }
    }

    @Test("A capture with no window goes to the chosen vault while it is there, else the one opened last")
    func chosenCaptureVaultOutranksTheLastOpened() throws {
        try withStore { defaults, opened, chosen in
            #expect(CaptureVaultPreference.url(in: defaults) == opened.standardizedFileURL)
            CaptureVaultPreference.choose(chosen, in: defaults)
            #expect(CaptureVaultPreference.url(in: defaults) == chosen.standardizedFileURL)
            #expect(CaptureVaultPreference.chosenPath(in: defaults) == chosen.standardizedFileURL.path)
            try FileManager.default.removeItem(at: chosen)
            #expect(CaptureVaultPreference.url(in: defaults) == opened.standardizedFileURL, "a chosen vault that is away is not captured into")
            #expect(CaptureVaultPreference.chosenPath(in: defaults) != nil, "but the choice is kept for when it is back")
        }
    }

    @Test("Choosing a capture vault does not change which vault a cold start opens, nor the reverse")
    func launchAndCaptureAreSeparate() throws {
        try withStore { defaults, opened, chosen in
            CaptureVaultPreference.choose(chosen, in: defaults)
            #expect(LaunchVaultPreference.url(in: defaults) == opened.standardizedFileURL)
            CaptureVaultPreference.choose(nil, in: defaults)
            LaunchVaultPreference.choose(chosen, in: defaults)
            #expect(CaptureVaultPreference.url(in: defaults) == opened.standardizedFileURL)
        }
    }
}

/// The phone has no capture-vault setting; it points the entity queries at
/// its bookmark. The Siri schema's note has to be found there too, or a
/// Spotlight result for it resolves to nothing and opens nothing.
@Suite("The Siri note query follows the host's vault", .serialized)
struct SiriNoteVaultTests {
    @available(macOS 27.0, *)
    @Test("A note is found in the vault the locator names")
    func followsLocator() async throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try "# Inbox\n".write(to: vault.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8)

        let previous = NoteEntityQuery.vaultLocator
        NoteEntityQuery.vaultLocator = { vault }
        defer { NoteEntityQuery.vaultLocator = previous }

        let found = try await SiriNoteQuery().entities(for: ["Inbox.md"])
        #expect(found.map(\.id) == ["Inbox.md"])
        let named = try await SiriNoteQuery().entities(matching: "Inbox")
        #expect(named.map(\.id).contains("Inbox.md"))
    }
}
