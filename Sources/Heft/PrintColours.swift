import AppKit
import HeftCore

/// Makes the editor's palette work on white paper.
///
/// The alternative was mirroring every colour setting — a second Appearance
/// pane, twelve more controls, two palettes to keep in step — and it answers
/// the wrong question. Nobody wants a *different* scheme on paper; they want
/// the one they chose to be legible there. A yellow accent that reads well on
/// a dark editor has almost no contrast against white, and that is a
/// measurable property rather than a matter of taste.
///
/// So the hue is kept and only the brightness is taken down, far enough to
/// clear a contrast ratio against white. `#FFCC00` stays recognisably the
/// same colour, as a dark gold.
enum PrintColours {

    /// The floor, as a contrast ratio against white.
    ///
    /// 3:1, which is what WCAG asks of large text and interface components.
    /// These colours are used for emphasis, links, tags and headings, never
    /// for body text — body stays near-black — so holding them to the 4.5:1
    /// body-text ratio would darken every hue into mud for no one's benefit.
    static let minimumContrast: Double = 3

    static func adjusted(_ colour: NSColor, for mode: PDFExportOptions.Colours) -> NSColor {
        switch mode {
        case .editor:
            return colour
        case .monochrome:
            return greyed(colour)
        case .paper:
            return darkenedForWhite(colour)
        }
    }

    /// Relative luminance, as WCAG defines it: linearised, then weighted.
    static func luminance(_ colour: NSColor) -> Double {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }

    /// Contrast between `colour` and white.
    static func contrastWithWhite(_ colour: NSColor) -> Double {
        (1.05) / (luminance(colour) + 0.05)
    }

    /// The same hue, dark enough to clear `minimumContrast` against white.
    ///
    /// Brightness is stepped down rather than solved for, because luminance is
    /// not linear in HSB brightness and a closed form would need inverting the
    /// gamma curve per channel. Fifty steps is plenty for 8-bit colour and
    /// runs once per export.
    static func darkenedForWhite(_ colour: NSColor) -> NSColor {
        guard let hsb = colour.usingColorSpace(.sRGB) else { return colour }
        if contrastWithWhite(hsb) >= minimumContrast { return colour }

        var brightness = hsb.brightnessComponent
        for _ in 0..<50 {
            brightness -= 0.02
            guard brightness > 0 else { break }
            let candidate = NSColor(
                hue: hsb.hueComponent,
                saturation: hsb.saturationComponent,
                brightness: brightness,
                alpha: hsb.alphaComponent
            )
            if contrastWithWhite(candidate) >= minimumContrast { return candidate }
        }
        // A hue that cannot reach the floor at any brightness does not exist
        // in sRGB, but returning black rather than looping forever is the
        // right answer if one ever does.
        return NSColor(white: 0, alpha: hsb.alphaComponent)
    }

    /// The colour's own lightness, as a grey that clears the same floor.
    static func greyed(_ colour: NSColor) -> NSColor {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return colour }
        let level = min(luminance(rgb), 0.18)
        return NSColor(white: level, alpha: rgb.alphaComponent)
    }
}
