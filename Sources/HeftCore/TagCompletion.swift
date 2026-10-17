import Foundation

/// A `#tag` being typed, and what completing it writes.
///
/// Shaped like the other completion contexts, so the editor offers the
/// vault's tags through the same menu. A tag starts a word and begins with a
/// letter, which is what keeps headings out: `# ` and `## ` close the menu
/// at their first character.
public struct TagCompletionContext: Equatable, Sendable {
    /// What has been typed after `#`.
    public let query: String
    public let queryRange: NSRange

    public init(query: String, queryRange: NSRange) {
        self.query = query
        self.queryRange = queryRange
    }

    /// The tag being typed at `selection`, or nil. Not in code, in a link,
    /// in a URL's `/#part` or in the frontmatter, where tags carry no `#`;
    /// and not with the caret inside a tag already written, where
    /// completing would leave its tail behind.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = selection.location
        guard caret > 0, caret <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: caret, length: 0))

        var start = caret
        while start > line.location, isTagCharacter(text.character(at: start - 1)) { start -= 1 }
        let hash = start - 1
        guard hash >= line.location, text.character(at: hash) == UInt16(35) else { return nil }  // "#"
        if hash > line.location {
            let before = text.character(at: hash - 1)
            guard before == UInt16(32) || before == UInt16(9) else { return nil }
        }
        if caret < NSMaxRange(line), isTagCharacter(text.character(at: caret)) { return nil }

        let query = text.substring(with: NSRange(location: start, length: caret - start))
        // A tag begins with a letter: `#1` is a number, not a tag.
        if let first = query.unicodeScalars.first, !CharacterSet.letters.contains(first) { return nil }

        let before = text.substring(with: NSRange(location: line.location, length: hash - line.location))
        guard before.filter({ $0 == "`" }).count % 2 == 0,
              before.components(separatedBy: "[[").count == before.components(separatedBy: "]]").count,
              !HighlightCompletionContext.isInsideFence(line.location, in: source),
              !isInsideFrontmatter(hash, in: text)
        else { return nil }
        return Self(query: query, queryRange: NSRange(location: start, length: caret - start))
    }

    /// `tags`, in their given order, narrowed to what was typed: those
    /// starting with it first, then those merely containing it.
    public func suggestions(from tags: [String]) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return tags }
        let starting = tags.filter { $0.lowercased().hasPrefix(needle) }
        let containing = tags.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        return starting + containing
    }

    /// Writes `tag` in place of what was typed, followed by a space unless
    /// one is already there, and leaves the caret after it.
    public func accepting(_ tag: String, in source: String) -> MarkdownEditing.Edit {
        let text = source as NSString
        let after = NSMaxRange(queryRange)
        let spaced = after < text.length && (text.character(at: after) == UInt16(32) || text.character(at: after) == UInt16(9))
        let replacement = spaced ? tag : tag + " "
        return MarkdownEditing.Edit(
            range: queryRange, replacement: replacement,
            selection: NSRange(location: queryRange.location + (tag as NSString).length + 1, length: 0)
        )
    }

    /// Letters, digits and the `_`, `-`, `/` a tag may hold.
    private static func isTagCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || character == UInt16(95)
            || character == UInt16(45) || character == UInt16(47)
    }

    private static func isInsideFrontmatter(_ location: Int, in text: NSString) -> Bool {
        guard text.hasPrefix("---\n") else { return false }
        let close = text.range(of: "\n---", options: [], range: NSRange(location: 3, length: text.length - 3))
        return close.location != NSNotFound && location <= close.location
    }
}
