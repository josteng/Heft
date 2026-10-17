import Foundation

/// The part of a wikilink after its note being typed: the link's own text
/// after `|`, or a heading after `#`.
///
/// Shaped like `WikiCompletionContext`, which hands over to this the moment
/// a `|` or `#` is typed, so the editor drives both through the same menu.
public struct LinkPartContext: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        /// After `|`: what the link reads, offered from the note's aliases.
        case text
        /// After `#`: one of the note's headings.
        case heading
    }

    public let part: Part
    /// The note the link points at, as written; empty in `[[#Heading]]`,
    /// which points into the note it is in.
    public let target: String
    public let query: String
    public let queryRange: NSRange
    public let hasClosingBrackets: Bool
    /// `![[`: after `|` an embed takes a size, not text.
    public let isEmbed: Bool
    /// Where the `[[` opening the link is, so a suggestion made for one link
    /// is not offered in another.
    public let linkStart: Int

    public init(
        part: Part, target: String, query: String, queryRange: NSRange, hasClosingBrackets: Bool,
        isEmbed: Bool = false, linkStart: Int = 0
    ) {
        self.part = part
        self.target = target
        self.query = query
        self.queryRange = queryRange
        self.hasClosingBrackets = hasClosingBrackets
        self.isEmbed = isEmbed
        self.linkStart = linkStart
    }

    /// The link part the caret is in, or nil. A block reference, `#^`, is
    /// not a heading and is left alone.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = min(selection.location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let opener = text.range(
            of: "[[", options: .backwards, range: NSRange(location: line.location, length: caret - line.location)
        )
        guard opener.location != NSNotFound else { return nil }
        let bodyStart = NSMaxRange(opener)
        let body = text.substring(with: NSRange(location: bodyStart, length: caret - bodyStart))
        guard !body.contains("]"), !body.contains("[") else { return nil }

        let closer = NSRange(location: caret, length: min(2, text.length - caret))
        let closes = closer.length == 2 && text.substring(with: closer) == "]]"
        let embed = opener.location > 0 && text.character(at: opener.location - 1) == UInt16(33)  // "!"

        if let bar = body.firstIndex(of: "|") {
            let query = String(body[body.index(after: bar)...])
            guard !query.contains("|") else { return nil }
            var left = String(body[..<bar])
            if left.hasSuffix("\\") { left.removeLast() }
            let target = left.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? left
            return Self(
                part: .text, target: target, query: query,
                queryRange: NSRange(location: caret - (query as NSString).length, length: (query as NSString).length),
                hasClosingBrackets: closes, isEmbed: embed, linkStart: opener.location
            )
        }
        if let hash = body.firstIndex(of: "#") {
            let query = String(body[body.index(after: hash)...])
            guard !query.hasPrefix("^") else { return nil }
            return Self(
                part: .heading, target: String(body[..<hash]), query: query,
                queryRange: NSRange(location: caret - (query as NSString).length, length: (query as NSString).length),
                hasClosingBrackets: closes, isEmbed: embed, linkStart: opener.location
            )
        }
        return nil
    }

    /// `candidates` matching what has been typed: those starting with it
    /// first, then those containing it, each once, in their own order.
    public func matching(_ candidates: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.lowercased()).inserted }
        guard !needle.isEmpty else { return unique }
        let starting = unique.filter { $0.lowercased().hasPrefix(needle) }
        let containing = unique.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        return starting + containing
    }

    /// Writes `value` in place of what was typed and leaves the caret after
    /// the link, closing it if it was not closed.
    public func accepting(_ value: String) -> MarkdownEditing.Edit {
        let replacement = value + (hasClosingBrackets ? "" : "]]")
        return MarkdownEditing.Edit(
            range: queryRange,
            replacement: replacement,
            selection: NSRange(location: queryRange.location + (value as NSString).length + 2, length: 0)
        )
    }

    /// The sentence the link is being written into: the line before `[[`,
    /// its last few hundred characters, for suggesting text that fits it.
    public func sentence(in source: String) -> String {
        let text = source as NSString
        let line = text.lineRange(for: NSRange(location: linkStart, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: linkStart - line.location))
        return String(before.suffix(300)).trimmingCharacters(in: .whitespaces)
    }

    /// A heading as a link can carry it: brackets and pipes would end the
    /// link, so they become spaces.
    public static func linkable(heading: String) -> String {
        heading
            .map { "[]|".contains($0) ? " " : String($0) }
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
