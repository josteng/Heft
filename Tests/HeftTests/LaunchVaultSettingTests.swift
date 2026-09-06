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
