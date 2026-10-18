import Foundation

/// What a Markdown line carries to the line Return makes after it: the list
/// or quote marker, advanced for a numbered item. Pure string work, shared by
/// the Mac editor and the iOS one so Return behaves the same on both.
enum ListContinuation {
    /// `> `, `> > ` … with indentation, or nil when the line is not quoted.
    ///
    /// A callout's `[!kind]` header is deliberately not carried down: the next
    /// line continues the callout's body, and repeating the marker would
    /// declare a second callout inside the first.
    static func quoteMarker(of line: String) -> String? {
        guard let match = line.range(
            of: #"^[ \t]*(?:>[ \t]?)+"#, options: .regularExpression
        ) else { return nil }
        return String(line[match])
    }

    /// `- `, `* `, `- [ ] `, `3. ` … with indentation, or nil for prose.
    /// A checked task yields an unchecked one.
    static func listMarker(of line: String) -> String? {
        guard let match = line.range(
            of: #"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#, options: .regularExpression
        ) else { return nil }
        return String(line[match])
            .replacingOccurrences(of: "[x]", with: "[ ]")
            .replacingOccurrences(of: "[X]", with: "[ ]")
    }

    /// The structural prefix Heft carries to a following Markdown line.
    /// Recognizes lists nested inside blockquotes in addition to standalone
    /// lists and quotes, so Return and Vim's optional o/O behavior agree.
    static func markdownContinuation(of line: String) -> (marker: String, isList: Bool)? {
        if let marker = listMarker(of: line) { return (marker, true) }
        guard let quote = quoteMarker(of: line) else { return nil }
        let remainder = String(line.dropFirst(quote.count))
        if let list = listMarker(of: remainder) { return (quote + list, true) }
        return (quote, false)
    }

    /// Marker for the following list item. Bullets and tasks repeat, while an
    /// ordered marker advances and retains its indentation, delimiter and
    /// whitespace (`9. ` becomes `10. ` and `9) ` becomes `10) `).
    /// Nesting level of a list line: one per tab, one per two spaces, which
    /// is what both Obsidian and CommonMark produce.
    ///
    /// Shared by Shift-Tab and by Return on an empty item, so the level Return
    /// steps out of is always the one Shift-Tab would have.
    static func listDepth(of line: String) -> Int {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        return leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
            + leading.filter { $0 == " " }.count / 2
    }

    static func nextListMarker(after marker: String) -> String {
        guard let number = marker.range(
            of: #"\d+(?=[.)][ \t]+$)"#, options: .regularExpression
        ), let value = Int(marker[number]), value < Int.max else { return marker }
        var result = marker
        result.replaceSubrange(number, with: String(value + 1))
        return result
    }
}
