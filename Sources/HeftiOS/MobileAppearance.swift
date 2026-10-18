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

    var accentColor: UIColor { Self.color(accent) ?? StyleDefaults.accentColor }
    var linkColor: UIColor { Self.color(link) ?? accentColor }
    var tagColor: UIColor { Self.color(tag) ?? accentColor }
    var codeColor: UIColor { Self.color(code) ?? StyleDefaults.codeColor }
    var boldColor: UIColor { Self.color(bold) ?? StyleDefaults.boldColor }
    var italicColor: UIColor { Self.color(italic) ?? StyleDefaults.italicColor }

    /// The tint for the whole app, or nil to keep the system's.
    var appTint: Color? { Self.color(accent).map(Color.init(uiColor:)) }

    /// 1-based, as written in Markdown.
    func headingColor(_ level: Int) -> UIColor {
        let index = min(max(level, 1), 6) - 1
        return Self.color(headings[index]) ?? StyleDefaults.headingColors[index]
    }
}
