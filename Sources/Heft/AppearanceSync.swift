import AppKit
import HeftCore

extension AppearanceSettings {
    /// The colours as the vault file holds them.
    var portable: AppearancePreferences {
        var preferences = AppearancePreferences()
        preferences.accent = customAccentColor.map(Self.hex)
        preferences.link = customLinkColor.map(Self.hex)
        preferences.tag = customTagColor.map(Self.hex)
        preferences.code = customCodeColor.map(Self.hex)
        preferences.bold = customBoldColor.map(Self.hex)
        preferences.italic = customItalicColor.map(Self.hex)
        preferences.headings = customHeadingColors.map { $0.map(Self.hex) }
        preferences.colorfulFormatting = colorfulFormattingEnabled
        return preferences
    }

    func adopt(_ preferences: AppearancePreferences) {
        customAccentColor = Self.color(preferences.accent)
        customLinkColor = Self.color(preferences.link)
        customTagColor = Self.color(preferences.tag)
        customCodeColor = Self.color(preferences.code)
        customBoldColor = Self.color(preferences.bold)
        customItalicColor = Self.color(preferences.italic)
        customHeadingColors = preferences.headings.map(Self.color)
        colorfulFormattingEnabled = preferences.colorfulFormatting
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return HexColor.format(
            red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent)
        )
    }

    private static func color(_ hex: String?) -> NSColor? {
        guard let hex, let parts = HexColor.components(hex) else { return nil }
        return NSColor(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }
}

/// Keeps the open vaults' `.heft/appearance.json` and the Mac's colours in
/// step, so the phone draws a vault the way this Mac does.
///
/// The colours stay app-wide, as they were: a vault's file is adopted when
/// the vault is read, and a change here is written to every open vault.
/// `AppearancePreferences.step` decides which.
enum AppearanceSync {
    /// Set by the registry: the roots of the vaults open now.
    nonisolated(unsafe) static var openVaults: () -> [URL] = { [] }
    nonisolated(unsafe) private static var adopting = false
    nonisolated(unsafe) private static var pendingWrite: DispatchWorkItem?

    /// After a colour changed here. Coalesced, since the colour picker
    /// reports every step of a drag.
    static func changed() {
        guard !adopting else { return }
        pendingWrite?.cancel()
        let write = DispatchWorkItem {
            let preferences = AppearanceSettings.shared.portable
            for root in openVaults() where AppearancePreferences.load(fromVault: root) != preferences {
                try? preferences.save(toVault: root)
            }
        }
        pendingWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: write)
    }

    /// What a scan of `root` found in its file.
    static func read(_ stored: AppearancePreferences?, in root: URL) {
        let settings = AppearanceSettings.shared
        switch AppearancePreferences.step(stored: stored, current: settings.portable) {
        case .nothing:
            break
        case .write:
            try? settings.portable.save(toVault: root)
        case .adopt(let preferences):
            adopting = true
            settings.adopt(preferences)
            adopting = false
        }
    }
}
