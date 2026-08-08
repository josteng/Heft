import Foundation

/// An inline style that is applied by wrapping text in a marker pair.
public enum InlineFormat: String, Sendable, CaseIterable {
    case bold = "**"
    case italic = "*"
    case strikethrough = "~~"
    case highlight = "=="
    case code = "`"

    public var marker: String { rawValue }

    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Code"
        }
    }

    /// SF Symbol for the formatting bar.
    public var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Text edits the formatting bar and its keyboard shortcuts perform.
///
/// Pure: takes source and a selection, returns new source and where the
/// selection should end up. Keeping it out of the text view is what makes the
/// toggling behaviour — which has more edge cases than it looks — testable
/// without a window.
public enum MarkdownEditing {

    public struct Edit: Equatable, Sendable {
        public let text: String
        public let selection: NSRange

        public init(text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }
    }

    /// Adds `format` around the selection, or removes it when it is already
    /// there — checking both inside the selection and immediately around it,
    /// because whether the user selected the markers along with the words is
    /// an accident of how they dragged.
    public static func toggle(
        _ format: InlineFormat, in source: String, range: NSRange
    ) -> Edit {
        let text = source as NSString
        let marker = format.marker
        let markerLength = (marker as NSString).length
        guard range.location != NSNotFound,
              NSMaxRange(range) <= text.length
        else { return Edit(text: source, selection: range) }

        // The selection carries the markers: `**bold**` selected whole.
        if range.length >= markerLength * 2 {
            let body = text.substring(with: range)
            if body.hasPrefix(marker), body.hasSuffix(marker) {
                let inner = String(body.dropFirst(marker.count).dropLast(marker.count))
                return Edit(
                    text: text.replacingCharacters(in: range, with: inner),
                    selection: NSRange(location: range.location, length: (inner as NSString).length)
                )
            }
        }

        // The markers sit just outside it: `**bold**` with only `bold` selected.
        let before = NSRange(location: range.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(range), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker,
           text.substring(with: after) == marker {
            let outer = NSRange(
                location: before.location, length: range.length + markerLength * 2
            )
            return Edit(
                text: text.replacingCharacters(in: outer, with: text.substring(with: range)),
                selection: NSRange(location: before.location, length: range.length)
            )
        }

        // Otherwise wrap. An empty selection produces an empty pair with the
        // caret between the markers, ready to type into.
        let body = text.substring(with: range)
        return Edit(
            text: text.replacingCharacters(in: range, with: marker + body + marker),
            selection: NSRange(location: range.location + markerLength, length: range.length)
        )
    }

    /// Wraps the selection in a link, putting the caret where the destination
    /// goes so it can be typed or pasted straight away.
    public static func makeLink(in source: String, range: NSRange) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return Edit(text: source, selection: range) }

        let label = text.substring(with: range)
        let replacement = "[\(label)]()"
        return Edit(
            text: text.replacingCharacters(in: range, with: replacement),
            // Just inside the parentheses.
            selection: NSRange(
                location: range.location + (replacement as NSString).length - 1, length: 0
            )
        )
    }
}
