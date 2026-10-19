#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The surface's colours when nothing is customised. The Mac's Appearance
/// settings fall back to these; the iOS app has no such pane and uses them
/// as they are.
enum StyleDefaults {
    static let accentColor = NSColor.controlAccentColor
    static let boldColor = NSColor.systemRed
    static let italicColor = NSColor.systemOrange
    /// Graphite, the vivid palette's; `Palette.code` is what draws it.
    static let codeColor = NSColor.systemGray
    /// h1 through h6, in order.
    static let headingColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
    ]
}
