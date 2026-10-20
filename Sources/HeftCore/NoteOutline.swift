import Foundation

/// A note's headings, in order, for the outline beside it: what each says,
/// how far in it sits, and where it is, so one tap can go there.
///
/// The headings are the ones the live surface draws: `#` lines outside code
/// fences and frontmatter, and setext headings under the decorator's rules
/// (two dashes at least, never under a line that opens a block of its own).
/// A line scan rather than a parse, because it is redone as the note is
/// typed and a long note must not pay for a full parse each time.
public struct NoteOutline: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        /// 1 to 6, as written.
        public let level: Int
        /// How far in to draw it: one step per enclosing heading, so a note
        /// that starts at `##`, or jumps from `#` to `###`, does not open
        /// with an empty column.
        public let depth: Int
        /// The heading's text with its markup removed.
        public let title: String
        /// The heading's line, 1-based, as a reveal counts.
        public let line: Int
        /// Where the line starts, in UTF-16 units, as the editor counts.
        public let offset: Int

        public var id: Int { line }
    }

    public let entries: [Entry]

    public static let empty = NoteOutline(entries: [])

    init(entries: [Entry]) {
        self.entries = entries
    }

    public init(source: String) {
        var found: [(level: Int, title: String, line: Int, offset: Int)] = []
        var offset = 0
        var inFence = false
        var fenceMarker = ""
        // Only a closed block is frontmatter, as the decorator has it.
        let frontmatterLines = NoteText.splitFrontmatter(source).frontmatter
            .map { $0.isEmpty ? 2 : $0.components(separatedBy: "\n").count + 2 } ?? 0
        // The line before, for a setext underline: its text, where it
        // started, and whether it can carry one.
        var previous: (text: String, line: Int, offset: Int, isParagraph: Bool)?
        let raws = source.components(separatedBy: "\n")
        // A file saved on Windows ends each line in a return as well.
        let lines = raws.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        // A comment hides what is inside only once it closes, as the
        // decorator matches it: the last line that could close each kind.
        let lastHTMLClose = lines.lastIndex { $0.contains("-->") } ?? -1
        let lastPercentClose = lines.lastIndex { Self.isPercentFence($0) } ?? -1
        var commentCloser: String?

        for (index, line) in lines.enumerated() {
            let lineOffset = offset
            offset += raws[index].utf16.count + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A `# comment` in the YAML is not a heading.
            if index < frontmatterLines { continue }
            if inFence {
                // Only the opening three characters alone on a line close
                // it, as the decorator has it; a ````swift` inside is code.
                if trimmed == fenceMarker { inFence = false }
                previous = nil
                continue
            }
            if let closer = commentCloser {
                if closer == "%%" ? Self.isPercentFence(line) : line.contains(closer) { commentCloser = nil }
                previous = nil
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                previous = nil
                continue
            }
            // A comment left open on this line hides the lines down to its
            // close, and this one with them.
            if Self.opensHTMLComment(line), lastHTMLClose > index {
                commentCloser = "-->"
                previous = nil
                continue
            }
            if Self.isPercentFence(line), lastPercentClose > index {
                commentCloser = "%%"
                previous = nil
                continue
            }

            // At the very start of the line: the decorator draws no indented
            // `#` as a heading.
            if let level = Self.atxLevel(line) {
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                // A closing run of hashes is markup too.
                let title = text.replacing(#/\s+#+$/#, with: "")
                found.append((level, NoteText.plainLine(title), index + 1, lineOffset))
                previous = nil
                continue
            }

            if let level = Self.setextLevel(line), let above = previous, above.isParagraph {
                found.append((level, NoteText.plainLine(above.text), above.line, above.offset))
                previous = nil
                continue
            }

            previous = (trimmed, index + 1, lineOffset, Self.canCarryUnderline(trimmed))
        }

        // Depth from the headings still open above each one.
        var open: [Int] = []
        entries = found.map { heading in
            while let last = open.last, last >= heading.level { open.removeLast() }
            let entry = Entry(level: heading.level, depth: open.count, title: heading.title,
                              line: heading.line, offset: heading.offset)
            open.append(heading.level)
            return entry
        }
    }

    /// The heading `offset` falls under: the last one starting at or before
    /// it. None above the first heading.
    public func index(containing offset: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].offset <= offset { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    // MARK: - Lines

    /// `#` to `######` followed by a space or the end of the line; `#tag`
    /// is a tag.
    private static func atxLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" ? level : nil
    }

    /// `%%` alone on its line, which opens or closes Obsidian's block
    /// comment.
    private static func isPercentFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "%%"
    }

    /// Whether the line leaves a `<!--` without its `-->`.
    private static func opensHTMLComment(_ line: String) -> Bool {
        guard let open = line.range(of: "<!--", options: .backwards) else { return false }
        return line.range(of: "-->", range: open.upperBound..<line.endIndex) == nil
    }

    /// `===` makes an H1 and `--` or longer an H2, with at most three
    /// spaces before it, as the decorator decides.
    private static func setextLevel(_ line: String) -> Int? {
        guard line.firstMatch(of: #/^[ \t]{0,3}(?:=+|--+)[ \t]*$/#) != nil else { return nil }
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("=") ? 1 : 2
    }

    /// An ordinary paragraph line; a blank one, or one that opens a block
    /// of its own, leaves the underline a rule.
    private static func canCarryUnderline(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let opensItsOwnBlock = #/^(?:#{1,6}(?:[ \t]|$)|>|[-*+](?:[ \t]|$)|\d+[.)](?:[ \t]|$)|```|~~~|\||<!--|=+[ \t]*$|-+[ \t]*$)/#
        return trimmed.firstMatch(of: opensItsOwnBlock) == nil
    }
}
