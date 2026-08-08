import Foundation

/// The unfinished wikilink surrounding an insertion point.
///
/// Completion deliberately owns only source ranges. The macOS shell supplies
/// the popup, while this type keeps UTF-16 editing and bracket handling
/// deterministic and testable.
public struct WikiCompletionContext: Equatable, Sendable {
    public let query: String
    public let queryRange: NSRange
    public let isEmbed: Bool
    public let hasClosingBrackets: Bool

    public init(
        query: String, queryRange: NSRange, isEmbed: Bool,
        hasClosingBrackets: Bool
    ) {
        self.query = query
        self.queryRange = queryRange
        self.isEmbed = isEmbed
        self.hasClosingBrackets = hasClosingBrackets
    }

    /// Finds the nearest unmatched `[[` before a caret on the same line.
    /// Aliases and heading fragments end filename completion because they have
    /// their own value space and must not be replaced with another filename.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = min(selection.location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let beforeCaret = NSRange(location: line.location, length: caret - line.location)
        let opener = text.range(of: "[[", options: .backwards, range: beforeCaret)
        guard opener.location != NSNotFound else { return nil }

        let queryStart = NSMaxRange(opener)
        let queryRange = NSRange(location: queryStart, length: caret - queryStart)
        let query = text.substring(with: queryRange)
        guard !query.contains("]]"), !query.contains("|"), !query.contains("#"),
              !query.contains("[") && !query.contains("]")
        else { return nil }

        let closer = NSRange(location: caret, length: min(2, text.length - caret))
        let hasCloser = closer.length == 2 && text.substring(with: closer) == "]]"
        let isEmbed = opener.location > 0
            && text.substring(with: NSRange(location: opener.location - 1, length: 1)) == "!"
        return Self(
            query: query, queryRange: queryRange,
            isEmbed: isEmbed, hasClosingBrackets: hasCloser
        )
    }

    /// Replaces the typed query and puts the caret after the complete link.
    public func accepting(_ destination: String) -> MarkdownEditing.Edit {
        let suffix = hasClosingBrackets ? "" : "]]"
        return MarkdownEditing.Edit(
            range: queryRange,
            replacement: destination + suffix,
            selection: NSRange(
                location: queryRange.location + destination.utf16.count + 2,
                length: 0
            )
        )
    }
}
