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

    /// The smallest replacement that performs a formatting change.
    ///
    /// A range and a replacement rather than the whole new document. Handing
    /// back the entire text made the caller replace every character of the
    /// file to bold one word, which relaid the whole document out — the view
    /// jumped — and put the file's entire contents on the undo stack as a
    /// single step.
    public struct Edit: Equatable, Sendable {
        /// Range in the *original* source to replace.
        public let range: NSRange
        public let replacement: String
        /// Where the selection belongs once the replacement is in.
        public let selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }

        /// True when there is nothing to do, so callers can bail cheaply.
        public var isEmpty: Bool { range.length == 0 && replacement.isEmpty }

        public func applied(to source: String) -> String {
            (source as NSString).replacingCharacters(in: range, with: replacement)
        }

        static func nothing(keeping selection: NSRange) -> Edit {
            Edit(range: NSRange(location: 0, length: 0), replacement: "", selection: selection)
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
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }

        guard spansMultipleLines(in: source, range: range) else {
            return toggleSingle(format, in: text, range: range)
        }

        // Backticks are deliberately line-local. Wrapping each selected line
        // as code would silently turn a paragraph selection into several
        // unrelated snippets; a fenced block is a different command entirely.
        guard format != .code else { return .nothing(keeping: range) }

        let ranges = nonWhitespaceLineSegments(in: text, selection: range)
        guard !ranges.isEmpty else { return .nothing(keeping: range) }

        // "Toggle" across a mixed selection behaves like a native style
        // command: add the style everywhere unless every selected line already
        // has it, in which case remove it everywhere.
        let removals = ranges.map { removal(of: format, in: text, range: $0) }
        let removeEverywhere = removals.allSatisfy { $0 != nil }
        var edits: [Edit] = []
        for (index, segment) in ranges.enumerated() {
            if removeEverywhere {
                if let edit = removals[index] { edits.append(edit) }
            } else if removals[index] == nil {
                edits.append(wrapping(format, text.substring(with: segment), at: segment))
            }
        }
        guard !edits.isEmpty else { return .nothing(keeping: range) }

        // NSTextView applies one replacement so the whole operation remains a
        // single undo step. Include the original selection in the union so its
        // line breaks and any already-formatted lines stay selected afterward.
        let start = min(range.location, edits.map(\.range.location).min() ?? range.location)
        let end = max(NSMaxRange(range), edits.map { NSMaxRange($0.range) }.max() ?? NSMaxRange(range))
        let union = NSRange(location: start, length: end - start)
        var replacement = text.substring(with: union)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(
                location: edit.range.location - union.location,
                length: edit.range.length
            )
            replacement = (replacement as NSString).replacingCharacters(
                in: local, with: edit.replacement
            )
        }
        return Edit(
            range: union,
            replacement: replacement,
            selection: NSRange(location: union.location, length: (replacement as NSString).length)
        )
    }

    /// Whether a selection contains a hard line boundary. Shared with the UI
    /// so it can disable formats that Markdown cannot represent across lines.
    public static func spansMultipleLines(in source: String, range: NSRange) -> Bool {
        let text = source as NSString
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= text.length else { return false }
        return text.rangeOfCharacter(from: .newlines, options: [], range: range).location != NSNotFound
    }

    private static func toggleSingle(
        _ format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit {
        if let edit = removal(of: format, in: text, range: range) { return edit }
        return wrapping(format, text.substring(with: range), at: range)
    }

    private static func wrapping(_ format: InlineFormat, _ body: String, at range: NSRange) -> Edit {
        let marker = format.marker
        let markerLength = (marker as NSString).length
        return Edit(
            range: range,
            replacement: marker + body + marker,
            selection: NSRange(location: range.location + markerLength, length: range.length)
        )
    }

    /// Returns the unwrapping edit when the selected text either includes its
    /// markers or has a matching pair immediately outside it.
    private static func removal(
        of format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit? {
        let marker = format.marker
        let markerLength = (marker as NSString).length

        // The selection carries the markers: `**bold**` selected whole.
        if range.length >= markerLength * 2 {
            let body = text.substring(with: range)
            if body.hasPrefix(marker), body.hasSuffix(marker) {
                let inner = String(body.dropFirst(marker.count).dropLast(marker.count))
                return Edit(
                    range: range,
                    replacement: inner,
                    selection: NSRange(
                        location: range.location, length: (inner as NSString).length
                    )
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
                range: outer,
                replacement: text.substring(with: range),
                selection: NSRange(location: before.location, length: range.length)
            )
        }
        return nil
    }

    /// The nonempty piece of every selected line. Horizontal whitespace stays
    /// outside markers, because `** text **` is not valid emphasis Markdown.
    private static func nonWhitespaceLineSegments(
        in text: NSString, selection: NSRange
    ) -> [NSRange] {
        var result: [NSRange] = []
        let selectionEnd = NSMaxRange(selection)
        var segmentStart = selection.location

        while segmentStart <= selectionEnd {
            let remaining = NSRange(
                location: segmentStart, length: selectionEnd - segmentStart
            )
            let newline = text.rangeOfCharacter(from: .newlines, options: [], range: remaining)
            let segmentEnd = newline.location == NSNotFound ? selectionEnd : newline.location
            var lower = segmentStart
            var upper = segmentEnd
            while lower < upper, isHorizontalWhitespace(text.character(at: lower)) { lower += 1 }
            while upper > lower, isHorizontalWhitespace(text.character(at: upper - 1)) { upper -= 1 }
            if upper > lower {
                result.append(NSRange(location: lower, length: upper - lower))
            }
            guard newline.location != NSNotFound else { break }
            segmentStart = NSMaxRange(newline)
        }
        return result
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    /// Wraps the selection in a link, putting the caret where the destination
    /// goes so it can be typed or pasted straight away.
    public static func makeLink(in source: String, range: NSRange) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }
        guard !spansMultipleLines(in: source, range: range) else {
            return .nothing(keeping: range)
        }

        let replacement = "[\(text.substring(with: range))]()"
        return Edit(
            range: range,
            replacement: replacement,
            // Just inside the parentheses, ready for a destination.
            selection: NSRange(
                location: range.location + (replacement as NSString).length - 1, length: 0
            )
        )
    }
}
