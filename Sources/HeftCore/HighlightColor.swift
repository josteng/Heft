import Foundation

/// One of Obsidian's six highlight colours, written as an emoji right after
/// the opening `==`: `==🔴Important==`.
///
/// An emoji rather than a class or an attribute, so the file stays plain
/// Markdown and another editor shows the dot instead of losing the colour.
/// That also makes it markup Heft can collapse like any other: the emoji
/// keeps its place in the buffer and is hidden until the caret is inside.
public enum HighlightColor: String, Sendable, CaseIterable {
    case red = "🔴"
    case orange = "🟠"
    case yellow = "🟡"
    case green = "🟢"
    case blue = "🔵"
    case purple = "🟣"

    public var emoji: String { rawValue }

    public var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    /// The colour emoji starting at `location`, and how many UTF-16 units it
    /// takes. A trailing variation selector belongs to it, since some
    /// keyboards append one.
    public static func leading(in text: NSString, at location: Int) -> (color: Self, length: Int)? {
        // Every one of the six is a single astral scalar: two UTF-16 units.
        guard location + 2 <= text.length,
              let color = Self(rawValue: text.substring(with: NSRange(location: location, length: 2)))
        else { return nil }
        let selector = location + 2 < text.length && text.character(at: location + 2) == 0xFE0F
        return (color, selector ? 3 : 2)
    }

    /// `inner`, the text between a highlight's markers, split into its colour
    /// and the text that is actually highlighted.
    public static func split(_ inner: String) -> (color: Self?, text: String) {
        let ns = inner as NSString
        guard let leading = leading(in: ns, at: 0) else { return (nil, inner) }
        return (leading.color, ns.substring(from: leading.length))
    }
}
