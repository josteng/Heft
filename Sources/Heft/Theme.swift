import AppKit
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

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 28, weight: .bold, design: .default)
        case 2: .system(size: 22, weight: .semibold)
        case 3: .system(size: 18, weight: .semibold)
        case 4: .system(size: 16, weight: .semibold)
        case 5: .system(size: 15, weight: .semibold)
        default: .system(size: 14, weight: .semibold)
        }
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
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Live mode reads as prose, so it uses a proportional face; raw source
    /// stays monospaced.
    static let liveFont = NSFont.systemFont(ofSize: 15)
    /// The focused block's source. Proportional at body size so swapping a
    /// rendered block for its source does not visibly reflow the page.
    static let blockEditorFont = NSFont.systemFont(ofSize: bodySize)

    static let linkColor = Color.accentColor
    /// Links pointing at a note that does not exist yet; clicking one creates it.
    static let unresolvedLinkColor = Color.orange
    static let codeBackground = Color(nsColor: .quaternarySystemFill)
    static let tagColor = Color.purple
    static let tagBackground = Color.purple.opacity(0.14)
    static let highlightBackground = Color.yellow.opacity(0.30)

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
