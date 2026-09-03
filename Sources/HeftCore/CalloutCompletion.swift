import Foundation

/// A `> [!` being typed, and what completing it would write.
///
/// Callouts are the one construct in a note whose vocabulary is closed and
/// unguessable: thirteen kinds with three spellings each, none of which the
/// editor shows you until you have already typed one correctly. That makes
/// them exactly what completion is for.
///
/// Pure, and shaped like `WikiCompletionContext` on purpose: the editor drives
/// both through the same panel, and two differently-shaped answers to "what is
/// being typed here" would be two code paths through it.
public struct CalloutCompletionContext: Equatable, Sendable {
    /// What has been typed after `[!`, which may be empty.
    public let query: String
    /// The span of `query` in the document, so accepting replaces it.
    public let queryRange: NSRange
    /// Whether a `]` already sits after the query, as it does when editing a
    /// callout that is already written rather than typing a fresh one.
    public let hasClosingBracket: Bool

    public init(query: String, queryRange: NSRange, hasClosingBracket: Bool) {
        self.query = query
        self.queryRange = queryRange
        self.hasClosingBracket = hasClosingBracket
    }

    /// Detects a callout being typed at `selection`, or nil.
    ///
    /// Only on the *first* line of a quote block, because that is the only
    /// line where Obsidian reads `[!kind]` — offering it on a body line would
    /// complete into something that renders as literal text.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        guard selection.location <= text.length else { return nil }

        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard isFirstLineOfQuote(line, in: text) else { return nil }
        guard let marker = quoteMarker(in: line, text) else { return nil }

        // `[!` has to be the first thing after the quote markers, allowing the
        // spaces Obsidian tolerates there.
        var index = NSMaxRange(marker)
        let end = NSMaxRange(line)
        while index < end, isSpace(text.character(at: index)) { index += 1 }
        guard index + 1 < end,
              text.character(at: index) == UInt16(91),   // "["
              text.character(at: index + 1) == UInt16(33) // "!"
        else { return nil }

        let queryStart = index + 2
        var queryEnd = queryStart
        while queryEnd < end, isKindCharacter(text.character(at: queryEnd)) { queryEnd += 1 }

        // The caret has to be inside what is being typed, or this is a callout
        // that merely happens to be on the caret's line.
        guard selection.location >= queryStart, selection.location <= queryEnd else { return nil }

        let closes = queryEnd < end && text.character(at: queryEnd) == UInt16(93)  // "]"
        return Self(
            query: text.substring(with: NSRange(location: queryStart, length: queryEnd - queryStart)),
            queryRange: NSRange(location: queryStart, length: queryEnd - queryStart),
            hasClosingBracket: closes
        )
    }

    /// The kinds matching `query`, best first.
    ///
    /// A prefix match outranks one in the middle, so `not` offers `note`
    /// before `footnote`-shaped aliases, and an empty query offers everything
    /// in declaration order — which is Obsidian's own order, and the order
    /// someone scanning the list expects.
    public func suggestions() -> [CalloutSuggestion] {
        let needle = query.lowercased()
        var scored: [(rank: Int, index: Int, suggestion: CalloutSuggestion)] = []
        for (index, kind) in CalloutKind.allCases.enumerated() {
            guard let rank = Self.rank(kind, matching: needle) else { continue }
            scored.append((rank.0, index, CalloutSuggestion(kind: kind, matchedAlias: rank.1)))
        }
        return scored
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.suggestion)
    }

    /// Rank plus the alias that matched, when it was not the canonical name.
    private static func rank(_ kind: CalloutKind, matching needle: String) -> (Int, String?)? {
        guard !needle.isEmpty else { return (0, nil) }
        let name = kind.rawValue
        if name.hasPrefix(needle) { return (0, nil) }
        for alias in kind.aliases where alias.hasPrefix(needle) { return (1, alias) }
        if name.contains(needle) { return (2, nil) }
        for alias in kind.aliases where alias.contains(needle) { return (3, alias) }
        return nil
    }

    /// The edit that accepts `name`.
    ///
    /// Writes the closing `] ` when there is not one already, so completing a
    /// callout from scratch leaves the caret where the title goes rather than
    /// in front of a bracket that still has to be typed.
    public func accepting(_ name: String) -> MarkdownEditing.Edit {
        let replacement = hasClosingBracket ? name : name + "] "
        return MarkdownEditing.Edit(
            range: queryRange,
            replacement: replacement,
            selection: NSRange(
                location: queryRange.location + (replacement as NSString).length
                    + (hasClosingBracket ? 1 : 0),
                length: 0
            )
        )
    }

    // MARK: - Scanning

    /// Whether `line` opens its quote block. A `[!kind]` on any later line is
    /// literal text to Obsidian, so completing there would be a trap.
    private static func isFirstLineOfQuote(_ line: NSRange, in text: NSString) -> Bool {
        guard line.location > 0 else { return true }
        let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
        guard previous.location != line.location else { return true }
        return quoteMarker(in: previous, text) == nil
    }

    /// The `>`, `> `, `>>` prefix of a quote line, or nil for prose.
    private static func quoteMarker(in line: NSRange, _ text: NSString) -> NSRange? {
        guard line.length > 0 else { return nil }
        let end = NSMaxRange(line)
        var index = line.location
        while index < end, isSpace(text.character(at: index)) { index += 1 }
        guard index < end, text.character(at: index) == UInt16(62) else { return nil }  // ">"
        while index < end, text.character(at: index) == UInt16(62) {
            index += 1
            if index < end, isSpace(text.character(at: index)) { index += 1 }
        }
        return NSRange(location: line.location, length: index - line.location)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == UInt16(32) || character == UInt16(9)
    }

    /// What may appear in a callout's name: letters and `-`, which is enough
    /// for every kind and alias and stops the scan at `]`, a space or the end
    /// of the line.
    private static func isKindCharacter(_ character: unichar) -> Bool {
        (character >= UInt16(97) && character <= UInt16(122))
            || (character >= UInt16(65) && character <= UInt16(90))
            || character == UInt16(45)
    }
}

/// One row of the callout completion menu.
public struct CalloutSuggestion: Equatable, Sendable {
    public let kind: CalloutKind
    /// Set when the query matched an alias rather than the canonical name, so
    /// the row can say which spelling it answered to.
    public let matchedAlias: String?

    public init(kind: CalloutKind, matchedAlias: String? = nil) {
        self.kind = kind
        self.matchedAlias = matchedAlias
    }

    /// What accepting this row writes. Always the canonical name: the aliases
    /// exist so the row can be *found*, not so a vault ends up spelling one
    /// callout four ways.
    public var insertion: String { kind.rawValue }
}
