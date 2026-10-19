import AppKit
import HeftCore

extension AppearanceSettings {
    /// The colours as the vault file holds them: a custom colour as its hex,
    /// a swatch by name, a default as nothing.
    var portable: AppearancePreferences {
        func stored(_ custom: NSColor?, _ slot: String) -> String? {
            custom.map(Self.hex) ?? swatches[slot]?.rawValue
        }
        var preferences = AppearancePreferences()
        preferences.accent = stored(customAccentColor, "accent")
        preferences.link = stored(customLinkColor, "link")
        preferences.tag = stored(customTagColor, "tag")
        preferences.code = stored(customCodeColor, "code")
        preferences.bold = stored(customBoldColor, "bold")
        preferences.italic = stored(customItalicColor, "italic")
        preferences.headings = (0..<6).map { stored(customHeadingColors[$0], Self.headingSlot($0)) }
        preferences.colorfulFormatting = colorfulFormattingEnabled
        preferences.palette = palette
        preferences.headingFont = headingFont
        preferences.headingColor = headingColor
        return preferences
    }

    func adopt(_ preferences: AppearancePreferences) {
        var swatches: [String: AppearancePreferences.Swatch] = [:]
        func custom(_ stored: String?, _ slot: String) -> NSColor? {
            switch AppearancePreferences.ColorChoice(stored: stored) {
            case .custom(let hex): return Self.color(hex)
            case .swatch(let swatch): swatches[slot] = swatch; return nil
            case nil: return nil
            }
        }
        customAccentColor = custom(preferences.accent, "accent")
        customLinkColor = custom(preferences.link, "link")
        customTagColor = custom(preferences.tag, "tag")
        customCodeColor = custom(preferences.code, "code")
        customBoldColor = custom(preferences.bold, "bold")
        customItalicColor = custom(preferences.italic, "italic")
        customHeadingColors = (0..<6).map { custom(preferences.headings[$0], Self.headingSlot($0)) }
        self.swatches = swatches
        colorfulFormattingEnabled = preferences.colorfulFormatting
        palette = preferences.palette
        headingFont = preferences.headingFont
        headingColor = preferences.headingColor
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
