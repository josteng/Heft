#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HeftCore

/// The colours behind the swatches, vivid and muted, and what each
/// formatting colour is when nothing was chosen.
///
/// Muted keeps each hue at roughly half its chroma, in OKLCH: lightness 0.52
/// on a light page and 0.78 on a dark one, so every swatch reads at 5:1 or
/// better on white and 8:1 on the dark editor. A colour picked with Custom
/// is never softened; only the swatches and the built-in defaults follow
/// the palette.
enum Palette {
    typealias Swatch = AppearancePreferences.Swatch
    typealias ColorPalette = AppearancePreferences.ColorPalette

    static func color(_ swatch: Swatch, _ palette: ColorPalette) -> NSColor {
        switch palette {
        case .vivid: vivid(swatch)
        case .muted: muted(swatch)
        }
    }

    private static func vivid(_ swatch: Swatch) -> NSColor {
        switch swatch {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .graphite: .systemGray
        }
    }

    /// The alpha goes into each appearance's colour: `withAlphaComponent`
    /// on a dynamic colour resolves it on the spot, outside the appearance
    /// it is drawn in.
    private static func muted(
        _ swatch: Swatch, alpha light: CGFloat = 1, dark: CGFloat? = nil
    ) -> NSColor {
        let pair: (Int, Int) = switch swatch {
        case .red: (0x945550, 0xE4A59F)
        case .orange: (0x8E5B36, 0xDEAB89)
        case .yellow: (0x7F6528, 0xCEB47E)
        case .green: (0x42774E, 0x95C69E)
        case .teal: (0x117878, 0x7AC7C6)
        case .blue: (0x466B99, 0x97BAE8)
        case .purple: (0x705D93, 0xBFADE2)
        case .graphite: (0x616A75, 0xB0B8C3)
        }
        return dynamic(
            light: rgb(pair.0).withAlphaComponent(light),
            dark: rgb(pair.1).withAlphaComponent(dark ?? light)
        )
    }

    // MARK: Built-in colours

    static func bold(_ palette: ColorPalette) -> NSColor { color(.red, palette) }
    static func italic(_ palette: ColorPalette) -> NSColor { color(.orange, palette) }

    /// Inline code: graphite unless chosen, as calm editors set code, in
    /// either palette; a chosen colour applies in both.
    static func code(_ palette: ColorPalette, chosen: NSColor?) -> NSColor {
        chosen ?? color(.graphite, palette)
    }

    /// The fill behind inline code.
    static func codeFill(_ palette: ColorPalette) -> NSColor {
        palette == .muted
            ? dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.08))
            : .quaternarySystemFill
    }

    /// h1 through h6: the hues the bars always had.
    static let headingSwatches: [Swatch] = [.red, .orange, .yellow, .green, .blue, .purple]

    static func heading(_ level: Int, _ palette: ColorPalette) -> NSColor {
        color(headingSwatches[min(max(level, 1), 6) - 1], palette)
    }

    /// Links and tags follow the accent unless chosen. The accent itself is
    /// the system's or the reader's and stays as it is for the caret and the
    /// checkboxes; text drawn in it is softened with the rest.
    static func followingAccent(_ accent: NSColor, _ palette: ColorPalette) -> NSColor {
        guard palette == .muted else { return accent }
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            softened(accent, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        #else
        return UIColor { traits in
            softened(accent.resolvedColor(with: traits), dark: traits.userInterfaceStyle == .dark)
        }
        #endif
    }

    /// A colour with the muted swatches' lightness and roughly their share
    /// of chroma, by hue.
    private static func softened(_ color: NSColor, dark: Bool) -> NSColor {
        #if os(macOS)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let hue = rgb.hueComponent, saturation = rgb.saturationComponent
        #else
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #endif
        return NSColor(
            hue: hue,
            saturation: saturation * (dark ? 0.35 : 0.55),
            brightness: dark ? 0.91 : 0.60,
            alpha: 1
        )
    }

    // MARK: Highlights and callouts

    /// `==text==`'s fill: its colour at 30% when vivid, the muted swatch at
    /// 18% when muted.
    static func highlightFill(_ color: HighlightColor?, _ palette: ColorPalette) -> NSColor {
        guard palette == .muted else { return Theme.highlightBackground(color) }
        return muted(highlightSwatch(color ?? .yellow), alpha: 0.18)
    }

    private static func highlightSwatch(_ color: HighlightColor) -> Swatch {
        switch color {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    /// A callout's tint: the system colour when vivid, its muted hue when
    /// muted. Grey stays grey.
    static func calloutTint(_ kind: CalloutKind?, _ palette: ColorPalette) -> NSColor {
        guard palette == .muted else { return Theme.calloutNSTint(kind) }
        return calloutSwatch(kind).map { muted($0) } ?? .secondaryLabelColor
    }

    /// The card behind a callout: its tint at 11% when vivid; when muted,
    /// the muted hue at 6% on a light page and 10% on a dark one.
    static func calloutFill(_ kind: CalloutKind?, _ palette: ColorPalette) -> NSColor {
        guard palette == .muted else { return Theme.calloutNSTint(kind).withAlphaComponent(0.11) }
        return calloutSwatch(kind).map { muted($0, alpha: 0.06, dark: 0.10) } ?? .quaternarySystemFill
    }

    private static func calloutSwatch(_ kind: CalloutKind?) -> Swatch? {
        switch kind {
        case .note, .info, .abstract: .blue
        case .todo, .question, .example: .purple
        case .tip: .teal
        case .success: .green
        case .warning: .orange
        case .failure, .danger, .bug: .red
        case .quote, .none: nil
        }
    }

    // MARK: Light and dark

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}
