#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HeftCore
import SwiftUI

/// Typography and spacing for the reading surface.
///
/// Colours are all semantic system colours so the app tracks light/dark and
/// the user's accent choice without a theme engine.
enum Theme {
    /// Measure cap. Long-form prose becomes hard to track past roughly 80
    /// characters, and a maximised window would otherwise stretch to 2000pt.
    static let contentMaxWidth: CGFloat = 760
    static let blockSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 40
    static let verticalPadding: CGFloat = 28

    static let bodySize: CGFloat = 15
    static let lineSpacing: CGFloat = 5.5
    /// Breathing room inside a quote or callout card, above the first line and
    /// below the last. Equal on both sides: the block is one painted rectangle,
    /// and uneven padding makes the text look like it has slipped upwards.
    static let quoteBlockPadding: CGFloat = 10

    static func headingPointSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        case 5: 15
        default: 14
        }
    }

    static func heading(
        _ level: Int, scale: CGFloat = 1, face: AppearancePreferences.HeadingFont = .system
    ) -> Font {
        Font(headingFont(level, size: headingPointSize(level) * scale, face: face))
    }

    static func headingCapHeight(
        _ level: Int, scale: CGFloat = 1, face: AppearancePreferences.HeadingFont = .system
    ) -> CGFloat {
        headingFont(level, size: headingPointSize(level) * scale, face: face).capHeight
    }

    /// A heading's font, from the size the system face has at its level.
    ///
    /// New York sits a step larger, since its x-height is lower than San
    /// Francisco's, and lighter at the top, where a bold serif shouts; from
    /// H4 down it is semibold, or a small serif disappears beside sans body
    /// text. The system face keeps the weights it always had.
    static func headingFont(
        _ level: Int, size: CGFloat, face: AppearancePreferences.HeadingFont
    ) -> NSFont {
        let index = min(max(level, 1), 6) - 1
        switch face {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        case .newYork:
            let scales: [CGFloat] = [30 / 28, 24 / 22, 19 / 18, 17 / 16, 1, 15 / 14]
            let weights: [NSFont.Weight] = [.regular, .regular, .medium, .semibold, .semibold, .medium]
            let system = NSFont.systemFont(ofSize: size * scales[index], weight: weights[index])
            guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
            #if os(macOS)
            return NSFont(descriptor: serif, size: size * scales[index]) ?? system
            #else
            return NSFont(descriptor: serif, size: size * scales[index])
            #endif
        }
    }

    /// The coloured bar beside a heading. All of it scales, not only its
    /// height: at a presentation's 2x a 3pt bar 12pt away read as a hairline
    /// pressed against a heading twice the size.
    static func headingBar(
        _ level: Int, scale: CGFloat = 1, face: AppearancePreferences.HeadingFont = .system
    ) -> (size: CGSize, gap: CGFloat, cornerRadius: CGFloat) {
        (
            CGSize(width: 3 * scale, height: headingCapHeight(level, scale: scale, face: face)),
            12 * scale,
            2 * scale
        )
    }

    static func headingTopPadding(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        default: 10
        }
    }

    static let body = Font.system(size: bodySize)
    static let mono = Font.system(size: bodySize - 1.5, design: .monospaced)
    static func body(scale: CGFloat) -> Font { .system(size: bodySize * scale) }
    static func mono(scale: CGFloat) -> Font {
        .system(size: (bodySize - 1.5) * scale, design: .monospaced)
    }
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Live mode reads as prose, so it uses a proportional face; raw source
    /// stays monospaced.
    /// 17 on a phone, which is what iOS sets body text at and what a thumb
    /// reads at arm's length; 15 at a Mac's distance.
    #if os(macOS)
    static let liveFont = NSFont.systemFont(ofSize: 15)
    #else
    static let liveFont = NSFont.systemFont(ofSize: 17)
    #endif
    /// The focused block's source. Proportional at body size so swapping a
    /// rendered block for its source does not visibly reflow the page.
    static let blockEditorFont = NSFont.systemFont(ofSize: bodySize)

    // Link, unresolved-link, bold, and italic colours are user-customisable
    // via the Appearance settings pane; see `AppearanceSettings` and
    // `RenderContext.accentColor`/`boldColor`/`italicColor` instead of a
    // fixed constant here.
    static let codeBackground = Color(nsColor: .quaternarySystemFill)
    /// How strongly a tag's own colour tints the pill behind it. Shared by
    /// the live surface and the reading view so the two match.
    static let tagBackgroundOpacity = 0.14
    /// Behind `==text==`: the colour its emoji names, or yellow for a plain
    /// one. Shared by the live surface and the reading view so the two match.
    static func highlightBackground(_ color: HighlightColor?) -> NSColor {
        highlightSwatch(color ?? .yellow).withAlphaComponent(0.30)
    }

    /// The colour itself, at full strength.
    static func highlightSwatch(_ color: HighlightColor) -> NSColor {
        switch color {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }

    // Heading accent colours are user-customisable via the Appearance
    // settings pane; see `AppearanceSettings.headingColor(_:)` and
    // `RenderContext.headingColor(_:)` instead of a fixed switch here.

    /// AppKit twin of `calloutTint`, for the editor's own drawing. A callout
    /// whose kind Obsidian does not know still gets a card, in grey.
    static func calloutNSTint(_ kind: CalloutKind?) -> NSColor {
        switch kind {
        case .note, .info, .abstract: .systemBlue
        case .todo, .question: .systemPurple
        case .tip: .systemTeal
        case .success: .systemGreen
        case .warning: .systemOrange
        case .failure, .danger, .bug: .systemRed
        case .example: .systemIndigo
        case .quote, .none: .secondaryLabelColor
        }
    }

    /// Callout tints live here rather than in the portable core, which stays
    /// free of any UI framework.
    static func calloutTint(_ kind: CalloutKind) -> Color {
        switch kind {
        case .note, .info, .abstract: .blue
        case .todo, .question: .purple
        case .tip: .teal
        case .success: .green
        case .warning: .orange
        case .failure, .danger, .bug: .red
        case .example: .indigo
        case .quote: .secondary
        }
    }
}
