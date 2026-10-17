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

/// A `==` that has just been typed to open a highlight, and what picking a
/// colour for it writes.
///
/// Shaped like `CalloutCompletionContext`, so the editor drives it through the
/// same panel. Unlike a callout there is nothing to filter: the menu is
/// offered only while the caret sits right after the opener, and the first
/// character of the highlighted text closes it, so typing on is never taken
/// over by a colour.
public struct HighlightCompletionContext: Equatable, Sendable {
    /// Where the colour goes: right after the opening `==`.
    public let location: Int
    /// Whether a `==` already follows on the line, as when an existing run
    /// of text is being highlighted rather than a fresh one typed.
    public let hasClosingMarker: Bool

    public init(location: Int, hasClosingMarker: Bool) {
        self.location = location
        self.hasClosingMarker = hasClosingMarker
    }

    /// Detects an opening `==` immediately before the caret, or nil.
    ///
    /// Not a closer, not part of a longer `===` run, and not inside code,
    /// where `a == b` is a comparison and a menu would be in the way.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = selection.location
        guard caret >= 2, caret <= text.length else { return nil }
        let equals = UInt16(61)
        guard text.character(at: caret - 1) == equals, text.character(at: caret - 2) == equals
        else { return nil }
        if caret >= 3, text.character(at: caret - 3) == equals { return nil }
        if caret < text.length, text.character(at: caret) == equals { return nil }

        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: caret - 2 - line.location))
        // An odd number of markers before this one leaves a highlight open,
        // so this pair closes it.
        guard before.components(separatedBy: "==").count % 2 == 1 else { return nil }
        // An odd number of backticks leaves an inline code span open.
        guard before.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        guard !isInsideFence(line.location, in: source) else { return nil }
        let after = text.substring(with: NSRange(location: caret, length: NSMaxRange(line) - caret))
        return Self(location: caret, hasClosingMarker: after.contains("=="))
    }

    /// The edit that gives the highlight `color`, or none for the theme's
    /// default, which is a highlight written without an emoji.
    ///
    /// Writes the closing `==` too, with the caret between, as Obsidian does:
    /// picking a colour is starting a highlight, and what follows is its text.
    public func accepting(_ color: HighlightColor?) -> MarkdownEditing.Edit {
        let emoji = color?.emoji ?? ""
        return MarkdownEditing.Edit(
            range: NSRange(location: location, length: 0),
            replacement: hasClosingMarker ? emoji : emoji + "==",
            selection: NSRange(location: location + (emoji as NSString).length, length: 0)
        )
    }

    /// Whether the line starting at `lineStart` sits inside a fenced code
    /// block, by the same open-and-close reading as `NoteText.forEachProseLine`.
    private static func isInsideFence(_ lineStart: Int, in source: String) -> Bool {
        var inside = false
        for line in (source as NSString).substring(to: lineStart).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inside.toggle() }
        }
        return inside
    }
}

/// One `==highlight==` in a note, found from a location inside it, and the
/// edit that recolours it. What the colour dot and the context menu act on.
public struct HighlightSpan: Equatable, Sendable {
    /// The whole span, markers included.
    public let range: NSRange
    /// The colour emoji, when it has one.
    public let dot: NSRange?
    public let color: HighlightColor?

    public init(range: NSRange, dot: NSRange?, color: HighlightColor?) {
        self.range = range
        self.dot = dot
        self.color = color
    }

    /// The highlight that `location` falls in, its markers counting, or nil.
    /// Read by the decorator, so what is found is what is drawn.
    public static func at(_ location: Int, in source: String) -> Self? {
        let text = source as NSString
        guard location >= 0, location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let local = location - line.location
        for decoration in LiveDecorator.decorations(in: text.substring(with: line)) {
            guard case .highlight(let color) = decoration.style,
                  local >= decoration.range.location, local <= NSMaxRange(decoration.range)
            else { continue }
            // The emoji is the one piece of syntax between the two markers.
            let dot = decoration.syntax.count == 3 ? decoration.syntax[1] : nil
            return Self(
                range: NSRange(location: decoration.range.location + line.location, length: decoration.range.length),
                dot: dot.map { NSRange(location: $0.location + line.location, length: $0.length) },
                color: dot == nil ? nil : color
            )
        }
        return nil
    }

    /// Gives the highlight `color`, or the default for nil, which is no
    /// emoji. The caret goes just after the new colour, at the start of the
    /// words, so the highlight stays revealed with its dot under the pointer.
    public func recoloring(_ color: HighlightColor?) -> MarkdownEditing.Edit {
        let emoji = color?.emoji ?? ""
        let target = dot ?? NSRange(location: range.location + 2, length: 0)
        return MarkdownEditing.Edit(
            range: target,
            replacement: emoji,
            selection: NSRange(location: target.location + (emoji as NSString).length, length: 0)
        )
    }
}
