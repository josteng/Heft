import Foundation
import Testing
@testable import HeftCore

@Suite("Portable appearance preferences")
struct AppearancePreferencesTests {

    @Test("Hex colours round-trip, with alpha only when not opaque")
    func hex() throws {
        #expect(HexColor.format(red: 1, green: 0.5, blue: 0) == "#FF8000")
        #expect(HexColor.format(red: 0, green: 0, blue: 1, alpha: 0.5) == "#0000FF80")
        let parsed = try #require(HexColor.components("#FF8000"))
        #expect(parsed.red == 1 && parsed.blue == 0 && parsed.alpha == 1)
        #expect(abs(parsed.green - 128.0 / 255) < 0.0001)
        #expect(HexColor.components("#0000FF80")?.alpha == 128.0 / 255)
        #expect(HexColor.components("red") == nil)
        #expect(HexColor.components("#12345") == nil)
    }

    @Test("Saved preferences come back as they were")
    func roundTrip() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppearancePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(AppearancePreferences.load(fromVault: vault) == nil)
        var preferences = AppearancePreferences()
        preferences.accent = "#112233"
        preferences.headings[2] = "#445566"
        preferences.colorfulFormatting = false
        try preferences.save(toVault: vault)
        #expect(AppearancePreferences.load(fromVault: vault) == preferences)
    }

    @Test("Missing keys read as defaults; an old file's colourful formatting is on, a new vault's off")
    func partial() throws {
        let decoded = try JSONDecoder().decode(
            AppearancePreferences.self, from: Data(##"{"bold": "#FF0000", "headings": ["#00FF00"]}"##.utf8)
        )
        #expect(decoded.bold == "#FF0000")
        #expect(decoded.colorfulFormatting)
        #expect(decoded.headings.count == 6)
        #expect(decoded.headings[0] == "#00FF00" && decoded.headings[1] == nil)
        #expect(!AppearancePreferences().colorfulFormatting, "a vault set up now starts calm")
    }

    @Test("The vault's file wins; without one, only customised colours are written")
    func syncStep() {
        let defaults = AppearancePreferences()
        var mine = AppearancePreferences()
        mine.bold = "#FF0000"
        var theirs = AppearancePreferences()
        theirs.colorfulFormatting = false
        #expect(AppearancePreferences.step(stored: nil, current: defaults) == .nothing)
        #expect(AppearancePreferences.step(stored: nil, current: .legacy) == .nothing,
                "a Mac that kept the look it always had writes no file")
        var serif = AppearancePreferences()
        serif.headingFont = .newYork
        #expect(AppearancePreferences.step(stored: nil, current: serif) == .write)
        #expect(AppearancePreferences.step(stored: nil, current: mine) == .write)
        #expect(AppearancePreferences.step(stored: mine, current: mine) == .nothing)
        #expect(AppearancePreferences.step(stored: theirs, current: mine) == .adopt(theirs))
        #expect(AppearancePreferences.step(stored: defaults, current: mine) == .adopt(defaults))
    }

    /// Headings left colourful formatting for a setting of their own; a
    /// file written before that keeps the bar it had, and a new vault starts
    /// plain.
    @Test("Heading font and colour, and files from before them")
    func headings() throws {
        #expect(AppearancePreferences().headingColor == .none)
        #expect(AppearancePreferences().headingFont == .system)
        let colorful = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8))
        #expect(colorful.headingColor == .levelColors, "an old file drew the bar")
        let plain = try JSONDecoder().decode(
            AppearancePreferences.self, from: Data(#"{"colorfulFormatting": false}"#.utf8)
        )
        #expect(plain.headingColor == .none)
        let chosen = try JSONDecoder().decode(
            AppearancePreferences.self,
            from: Data(#"{"colorfulFormatting": true, "headingColor": "none", "headingFont": "newYork"}"#.utf8)
        )
        #expect(chosen.headingColor == .none, "a choice made stays, whatever colourful formatting says")
        #expect(chosen.headingFont == .newYork)

        var preferences = AppearancePreferences()
        preferences.headingFont = .newYork
        preferences.headingColor = .levelColors
        let again = try JSONDecoder().decode(
            AppearancePreferences.self, from: JSONEncoder().encode(preferences)
        )
        #expect(again == preferences)
    }
}

