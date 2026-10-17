import Foundation

/// A picture embedded in a note, as it is written, and the edits that resize
/// or remove it.
///
/// Obsidian writes a picture's size into its link: `![[shot.png|300]]`, or
/// for a Markdown image in its alt text, `![300](shot.png)` and
/// `![a cat|300](shot.png)`. `|300x200` gives both sides. Resizing is
/// rewriting that number and nothing else, so the rest of the link is left
/// exactly as written.
public struct ImageEmbed: Equatable, Sendable {
    /// The whole embed, `![[` or `![` to the closing bracket.
    public let range: NSRange
    public let width: Int?
    public let height: Int?
    /// The written size: `|300` with its pipe, or the whole alt when the alt
    /// is nothing but a size. Nil when there is none.
    let sizeRange: NSRange?
    /// Where a size goes when there is none yet.
    let insertion: Int
    /// Whether a size written at `insertion` needs a pipe before it: not in
    /// an empty alt, where the size is the whole of it.
    let insertsPipe: Bool
    /// The pipe inside a table cell is written `\|`, or it would end the cell.
    let pipe: String

    public init?(_ source: String, range: NSRange) {
        let text = source as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        let raw = text.substring(with: range)
        let inTable = Self.isTableRow(text, at: range.location)
        if raw.hasPrefix("![["), raw.hasSuffix("]]") {
            self.init(wiki: raw, at: range, inTable: inTable)
        } else if raw.hasPrefix("!["), let close = raw.range(of: "](") {
            self.init(markdown: raw, close: close, at: range, inTable: inTable)
        } else {
            return nil
        }
    }

    private init?(wiki raw: String, at range: NSRange, inTable: Bool) {
        let body = String(raw.dropFirst(3).dropLast(2))
        let bodyStart = range.location + 3
        self.range = range
        self.pipe = inTable ? "\\|" : "|"
        guard let bar = Self.firstPipe(in: body) else {
            width = nil
            height = nil
            sizeRange = nil
            insertion = NSMaxRange(range) - 2
            insertsPipe = true
            return
        }
        let after = String(body[bar.upperBound...]).trimmingCharacters(in: .whitespaces)
        // `![[pic.png|caption]]` has no size and nowhere to put one that
        // Obsidian would still read as its caption.
        guard let size = Self.size(after) else { return nil }
        width = size.width
        height = size.height
        let barStart = bodyStart + (String(body[..<bar.lowerBound]) as NSString).length
        sizeRange = NSRange(location: barStart, length: NSMaxRange(range) - 2 - barStart)
        insertion = barStart
        insertsPipe = true
    }

    private init(markdown raw: String, close: Range<String.Index>, at range: NSRange, inTable: Bool) {
        let alt = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<close.lowerBound])
        let altStart = range.location + 2
        let altLength = (alt as NSString).length
        self.range = range
        self.pipe = inTable ? "\\|" : "|"
        let parsed = Self.markdownAlt(alt)
        width = parsed.width
        height = parsed.height
        if parsed.width == nil {
            sizeRange = nil
            insertion = altStart + altLength
            insertsPipe = !alt.isEmpty
        } else if let bar = Self.lastPipe(in: alt) {
            let barStart = altStart + (String(alt[..<bar.lowerBound]) as NSString).length
            sizeRange = NSRange(location: barStart, length: altStart + altLength - barStart)
            insertion = barStart
            insertsPipe = true
        } else {
            sizeRange = NSRange(location: altStart, length: altLength)
            insertion = altStart
            insertsPipe = false
        }
    }

    /// A Markdown image's alt split into its words and its size: `300`,
    /// `300x200`, `a cat|300`. Anything else is all words.
    public static func markdownAlt(_ alt: String) -> (alt: String, width: Int?, height: Int?) {
        if let size = size(alt.trimmingCharacters(in: .whitespaces)) {
            return ("", size.width, size.height)
        }
        guard let bar = lastPipe(in: alt),
              let size = size(String(alt[bar.upperBound...]).trimmingCharacters(in: .whitespaces))
        else { return (alt, nil, nil) }
        return (String(alt[..<bar.lowerBound]), size.width, size.height)
    }

    /// The edit that draws the picture `width` wide, keeping its proportions,
    /// or at its own size again for nil.
    public func resizing(toWidth width: Int?) -> MarkdownEditing.Edit {
        guard let width else {
            guard let sizeRange else { return .nothing(keeping: range) }
            return edit(replacing: sizeRange, with: "")
        }
        let written = "\(max(1, width))"
        if let sizeRange {
            return edit(replacing: sizeRange, with: (insertsPipe ? pipe : "") + written)
        }
        return edit(
            replacing: NSRange(location: insertion, length: 0),
            with: (insertsPipe ? pipe : "") + written
        )
    }

    /// The edit that takes the picture out, with its line when the picture
    /// was all the line held.
    public func removing(in source: String) -> MarkdownEditing.Edit {
        let text = source as NSString
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let content = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        let target = content == text.substring(with: range) ? line : range
        return MarkdownEditing.Edit(
            range: target, replacement: "",
            selection: NSRange(location: target.location, length: 0)
        )
    }

    private func edit(replacing target: NSRange, with replacement: String) -> MarkdownEditing.Edit {
        let delta = (replacement as NSString).length - target.length
        return MarkdownEditing.Edit(
            range: target, replacement: replacement,
            // The whole embed, as rewritten, so the picture stays the subject.
            selection: NSRange(location: range.location, length: range.length + delta)
        )
    }

    // MARK: - Scanning

    private static func size(_ text: String) -> (width: Int, height: Int?)? {
        if let w = Int(text), w > 0 { return (w, nil) }
        let parts = text.split(separator: "x", maxSplits: 1)
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 { return (w, h) }
        return nil
    }

    /// The first `|` or `\|`, as `WikiLinkParser` splits a link on its first.
    private static func firstPipe(in text: String) -> Range<String.Index>? {
        guard let bar = text.firstIndex(of: "|") else { return nil }
        return escapedStart(of: bar, in: text)..<text.index(after: bar)
    }

    /// The last `|` or `\|`: an alt's words may hold a pipe of their own.
    private static func lastPipe(in text: String) -> Range<String.Index>? {
        guard let bar = text.lastIndex(of: "|") else { return nil }
        return escapedStart(of: bar, in: text)..<text.index(after: bar)
    }

    private static func escapedStart(of bar: String.Index, in text: String) -> String.Index {
        guard bar > text.startIndex else { return bar }
        let before = text.index(before: bar)
        return text[before] == "\\" ? before : bar
    }

    private static func isTableRow(_ text: NSString, at location: Int) -> Bool {
        let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }
}
