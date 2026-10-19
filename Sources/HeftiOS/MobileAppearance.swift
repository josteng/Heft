import HeftCore
import SwiftUI
import UIKit

/// The vault's colours as the editor draws them, each falling back as on the
/// Mac: link and tag to the accent, the rest to the built-in defaults.
extension AppearancePreferences {
    static func color(_ hex: String?) -> UIColor? {
        guard let hex, let parts = HexColor.components(hex) else { return nil }
        return UIColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }

    static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: .current).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return HexColor.format(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// A stored colour as drawn: a custom one exactly, a swatch through the
    /// palette, nothing as nil for the caller's default.
    func resolved(_ stored: String?) -> UIColor? {
        switch ColorChoice(stored: stored) {
        case .custom(let hex): Self.color(hex)
        case .swatch(let swatch): Palette.color(swatch, palette)
        case nil: nil
        }
    }

    /// The app's accent everywhere, its controls included: the system's, a
    /// swatch the palette draws, or a custom colour.
    var accentColor: UIColor { resolved(accent) ?? StyleDefaults.accentColor }

    /// Links and tags that follow the accent: the system's is softened for
    /// text under Muted; one picked here is used as it is.
    var accentForText: UIColor {
        accent == nil ? Palette.followingAccent(accentColor, palette) : accentColor
    }
    var linkColor: UIColor { resolved(link) ?? accentForText }
    var tagColor: UIColor { resolved(tag) ?? accentForText }
    var codeColor: UIColor { Palette.code(palette, chosen: resolved(code)) }
    var boldColor: UIColor { resolved(bold) ?? Palette.bold(palette) }
    var italicColor: UIColor { resolved(italic) ?? Palette.italic(palette) }

    /// Whether any formatting colour was picked with Custom, which Muted
    /// leaves as it is.
    var hasCustomFormattingColor: Bool {
        ([link, tag, code, bold, italic] + headings).contains {
            if case .custom = ColorChoice(stored: $0) { true } else { false }
        }
    }

    /// Every formatting colour back to the built-in one; the accent stays.
    func usingBuiltInColors() -> AppearancePreferences {
        var changed = self
        changed.link = nil
        changed.tag = nil
        changed.code = nil
        changed.bold = nil
        changed.italic = nil
        changed.headings = Array(repeating: nil, count: 6)
        return changed
    }

    /// The tint for the whole app, or nil to keep the system's.
    var appTint: Color? { resolved(accent).map(Color.init(uiColor:)) }

    /// 1-based, as written in Markdown.
    func headingColor(_ level: Int) -> UIColor {
        let index = min(max(level, 1), 6) - 1
        return resolved(headings[index]) ?? Palette.heading(level, palette)
    }
}
