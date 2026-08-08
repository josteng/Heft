import Foundation

/// One styled construct found in markdown source.
///
/// `syntax` holds the marker characters (`**`, `[[`, `# `) that live mode hides
/// when the cursor is elsewhere. Nothing here mutates the text: the editor keeps
/// the document string byte-for-byte and only changes how it is drawn, which is
/// what makes hybrid editing safe to run against a real vault.
public struct MarkdownDecoration: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case frontmatter
        case codeBlock(language: String?)
        case heading(level: Int)
        /// One line of a `>` block. Carried per line rather than per block so
        /// each paragraph can be given its own indent and its own slice of the
        /// bar or callout card the editor draws behind it.
        case quoteLine(QuoteLine)
        case listMarker(kind: ListMarkerKind, depth: Int)
        /// A whole GFM table, header and delimiter row included. Carried as one
        /// decoration because the editor draws the grid itself rather than
        /// styling the pipe characters in place.
        case table(TableLayout)
        case image(source: String, alt: String)
        case bold
        case italic
        case strikethrough
        case highlight
        case inlineCode
        /// The whole parsed link, not just its target: an embed needs the
        /// `#Heading` and `#^block` parts to know which slice of the other
        /// note to transclude.
        case wikiLink(WikiLink)
        case link(destination: String)
        case tag
        case inlineMath(String)
        case blockMath(String)
        case thematicBreak
    }

    public let range: NSRange
    public let syntax: [NSRange]
    public let style: Style

    public init(range: NSRange, syntax: [NSRange] = [], style: Style) {
        self.range = range
        self.syntax = syntax
        self.style = style
    }
}

/// A GFM table reduced to raw cell text plus column alignment.
///
/// Cells stay as markdown source: the editor runs the decorator over each one
/// again when it draws, so `**bold**` and `[[links]]` inside a cell get the
/// same treatment they do in prose.
public struct TableLayout: Sendable, Hashable {
    /// Row 0 is the header.
    public let rows: [[String]]
    public let alignments: [MDColumnAlignment]

    public init(rows: [[String]], alignments: [MDColumnAlignment]) {
        self.rows = rows
        self.alignments = alignments
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

/// Where a line sits inside the run of `>` lines it belongs to. The editor
/// paints a callout's card across several paragraphs, so each one needs to know
/// which of its corners to round.
public enum QuoteEdge: Sendable, Equatable { case only, first, middle, last }

/// One `>`-prefixed line, described in terms of the block around it.
public struct QuoteLine: Sendable, Equatable {
    /// Nesting level, counted from the number of `>` markers on the line.
    public let depth: Int
    public let edge: QuoteEdge
    /// Set on *every* line of an Obsidian callout, so the whole card is tinted.
    public let callout: CalloutKind?
    /// The word inside `[!…]`, kept even when it names no known kind so an
    /// unrecognised callout still reads as one rather than silently degrading.
    public let rawCallout: String?
    /// Text after `[!kind]`, on the callout's header line only.
    ///
    /// Three states, and they are all different: `nil` means this is not a
    /// header line at all (a body line, or any line of a plain quote); `""`
    /// means it is the header but nothing was written after the marker, so the
    /// kind's own name is drawn instead, as Obsidian does; anything else is the
    /// title the author wrote.
    public let title: String?

    public init(
        depth: Int, edge: QuoteEdge, callout: CalloutKind? = nil,
        rawCallout: String? = nil, title: String? = nil
    ) {
        self.depth = depth
        self.edge = edge
        self.callout = callout
        self.rawCallout = rawCallout
        self.title = title
    }

    public var isCallout: Bool { rawCallout != nil }

    /// True on the one line carrying `[!kind]`, whether or not a title was
    /// written after it. Named for the line's role, not its contents: a header
    /// line with nothing after the marker is still the header.
    public var isCalloutHeader: Bool { title != nil }

    /// True when the header line carries no title, so the kind's name has to be
    /// drawn in its place.
    public var needsDrawnTitle: Bool { title?.isEmpty == true }
}

public enum ListMarkerKind: Sendable, Equatable {
    /// `-`, `*` or `+`: replaced by a drawn bullet.
    case bullet
    /// `1.` / `1)`: the numeral stays legible, so it is only dimmed.
    case ordered
    /// `- [ ]` / `- [x]`: replaced by a drawn checkbox.
    case task(checked: Bool)
}

/// What the caret currently exposes as literal markdown source.
///
/// Two ranges rather than one because Obsidian treats block and inline markup
/// differently, and matching that is most of what makes the surface feel right.
/// A heading's `#` comes back as soon as the caret is anywhere on its line; a
/// `**bold**` pair comes back only when the caret is inside *that* span, so the
/// rest of the sentence stays rendered.
public struct Reveal: Equatable, Sendable {
    public var line: NSRange
    public var selection: NSRange

    public static let none = Reveal(
        line: NSRange(location: NSNotFound, length: 0),
        selection: NSRange(location: NSNotFound, length: 0)
    )

    public init(line: NSRange, selection: NSRange) {
        self.line = line
        self.selection = selection
    }

    /// The state a caret or selection in `text` produces.
    public init(selection: NSRange, in text: NSString) {
        self.selection = selection
        self.line = text.lineRange(for: selection)
    }

    public func reveals(_ decoration: MarkdownDecoration) -> Bool {
        if Self.revealsWithItsLine(decoration.style) {
            guard line.location != NSNotFound else { return false }
            return NSIntersectionRange(decoration.range, line).length > 0
        }
        return Self.touches(decoration.range, selection)
    }

    /// True for markup belonging to the line as a whole, so that putting the
    /// caret anywhere on that line brings it back.
    ///
    /// Everything else is an inline span and returns only when the caret is
    /// inside it. The split is what stops a sentence full of `**bold**` from
    /// dissolving into raw asterisks the moment it is clicked.
    public static func revealsWithItsLine(_ style: MarkdownDecoration.Style) -> Bool {
        switch style {
        case .frontmatter, .codeBlock, .heading, .quoteLine, .listMarker,
             .table, .thematicBreak, .blockMath, .image:
            true
        // An embed owning its line is drawn as a block, so it behaves like one.
        case .wikiLink(let link):
            link.isEmbed
        case .bold, .italic, .strikethrough, .highlight, .inlineCode,
             .link, .tag, .inlineMath:
            false
        }
    }

    /// Whether a caret or selection lies inside `range`, counting both edges.
    ///
    /// The edges matter: markup is collapsed to no width, so a click lands the
    /// caret *beside* a span far more often than within it, and a span that
    /// will not open from its own boundary is one the user cannot edit.
    public static func touches(_ range: NSRange, _ selection: NSRange) -> Bool {
        guard selection.location != NSNotFound else { return false }
        if selection.length > 0 { return NSIntersectionRange(range, selection).length > 0 }
        return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
}

public enum LiveDecorator {

    /// Finds every construct worth styling. Emitted roughly outermost-first so a
    /// consumer applying attributes in order gets inner spans winning.
    public static func decorations(in source: String) -> [MarkdownDecoration] {
        let text = source as NSString
        var result: [MarkdownDecoration] = []

        // Code regions are computed first and everything else is excluded from
        // them, so `**not bold**` inside a fence stays literal.
        var protected: [NSRange] = []

        if let fm = firstMatch(#"\A---\n[\s\S]*?\n---"#, text) {
            result.append(MarkdownDecoration(range: fm, style: .frontmatter))
            protected.append(fm)
        }

        for match in matches(#"(?m)^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?^[ \t]*\1[ \t]*$"#, text, excluding: protected) {
            let language = languageOfFence(match, text)
            result.append(MarkdownDecoration(
                range: match, syntax: fenceSyntaxRanges(match, text), style: .codeBlock(language: language)
            ))
            protected.append(match)
        }
        // An unterminated fence still needs protecting, or the rest of the file
        // gets styled as prose while the user is mid-typing a code block. Find
        // its opening independently: a greedy opening-to-EOF regex starts at
        // the first *completed* block and is then rejected as overlapping it.
        if let opening = matches(
            #"(?m)^[ \t]*(```|~~~)[^\n]*\n"#, text, excluding: protected
        ).first {
            let match = NSRange(
                location: opening.location, length: text.length - opening.location
            )
            result.append(MarkdownDecoration(
                range: match, syntax: [opening],
                style: .codeBlock(language: languageOfFence(match, text))
            ))
            protected.append(match)
        }

        // Tables claim their lines whole: the editor draws a grid rather than
        // styling pipes, so nothing inside may be matched independently.
        for match in matches(tablePattern, text, excluding: protected) {
            guard let layout = parseTable(text.substring(with: match)) else { continue }
            result.append(MarkdownDecoration(range: match, style: .table(layout)))
            protected.append(match)
        }

        // Block constructs are found *before* any inline span is protected.
        // Protection rejects a candidate that merely intersects a protected
        // range, so computing inline spans first would delete the heading on
        // `# The $h(t)$ model` (and on any heading holding code or math)
        // instead of just nesting inside it.
        let blocks = blockDecorations(text, protected: protected)
        result.append(contentsOf: blocks)

        // Marker characters themselves are off limits to inline matching, so a
        // task's `[ ]` can never be read as a link label.
        protected.append(contentsOf: blocks.flatMap(\.syntax))

        // Block math before inline, so `$$x$$` is not read as two empty `$$`.
        for match in matches(#"\$\$[\s\S]+?\$\$"#, text, excluding: protected) {
            let inner = NSRange(location: match.location + 2, length: match.length - 4)
            guard inner.length > 0 else { continue }
            let latex = text.substring(with: inner)
            // Only `$$…$$` alone on its line becomes a drawn block. One sitting
            // mid-sentence has no line of its own to reserve, so it would be
            // painted over the surrounding prose.
            let style: MarkdownDecoration.Style = ownsItsLines(match, text)
                ? .blockMath(latex)
                : .inlineMath(latex)
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 2),
                         NSRange(location: NSMaxRange(match) - 2, length: 2)],
                style: style
            ))
            protected.append(match)
        }

        for match in matches(#"`[^`\n]+`"#, text, excluding: protected) {
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 1),
                         NSRange(location: NSMaxRange(match) - 1, length: 1)],
                style: .inlineCode
            ))
            protected.append(match)
        }

        // Inline math. Requires non-space just inside the delimiters so prices
        // ("$5 to $10") are not mistaken for math.
        for match in matches(#"\$(?![\s$])((?:[^$\n]|\\\$)+?)(?<![\s\\])\$"#, text, excluding: protected) {
            let inner = NSRange(location: match.location + 1, length: match.length - 2)
            guard inner.length > 0 else { continue }
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 1),
                         NSRange(location: NSMaxRange(match) - 1, length: 1)],
                style: .inlineMath(text.substring(with: inner))
            ))
            protected.append(match)
        }

        // Block constructs were already collected above, before inline spans
        // were protected; collecting them again here would emit every heading
        // and list marker twice.
        result.append(contentsOf: inlineDecorations(text, protected: protected))
        return result
    }

    // MARK: - Tables

    /// A pipe row, a delimiter row carrying at least one dash, then any number
    /// of further pipe rows.
    private static let tablePattern = #"""
    (?m)^[ \t]*\|[^\n]*\n[ \t]*\|(?=[^\n]*-)[ \t:\-|]+\|?[ \t]*(?:\n[ \t]*\|[^\n]*)*
    """#

    /// Splits a matched table into cells. Returns nil when the delimiter row
    /// does not line up, which means it was not a table after all.
    static func parseTable(_ source: String) -> TableLayout? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let delimiterCells = splitRow(lines[1])
        guard !delimiterCells.isEmpty,
              delimiterCells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil })
        else { return nil }

        let alignments: [MDColumnAlignment] = delimiterCells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }

        var rows = [splitRow(lines[0])]
        rows.append(contentsOf: lines.dropFirst(2).map(splitRow))
        return TableLayout(rows: rows, alignments: alignments)
    }

    /// `| a | b |` to `["a", "b"]`. Obsidian writes `\|` for a literal pipe
    /// inside a cell, so that escape must survive the split.
    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character == "|" ? "|" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        // A well-formed row is bracketed by pipes, which yields an empty cell
        // at each end.
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// True when nothing but whitespace shares the construct's first and last lines.
    private static func ownsItsLines(_ range: NSRange, _ text: NSString) -> Bool {
        let lines = text.lineRange(for: range)
        let before = text.substring(with: NSRange(
            location: lines.location, length: range.location - lines.location
        ))
        let after = text.substring(with: NSRange(
            location: NSMaxRange(range), length: NSMaxRange(lines) - NSMaxRange(range)
        ))
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Block constructs

    private static func blockDecorations(_ text: NSString, protected: [NSRange]) -> [MarkdownDecoration] {
        var result: [MarkdownDecoration] = []

        for match in matches(#"(?m)^(#{1,6})[ \t]+\S.*$"#, text, excluding: protected) {
            let line = text.substring(with: match)
            let level = line.prefix { $0 == "#" }.count
            // Hide the hashes and the space that follows them.
            var syntaxLength = level
            while syntaxLength < line.count,
                  line[line.index(line.startIndex, offsetBy: syntaxLength)] == " " {
                syntaxLength += 1
            }
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: syntaxLength)],
                style: .heading(level: level)
            ))
        }

        result.append(contentsOf: quoteDecorations(text, protected: protected))

        for match in matches(#"(?m)^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#, text, excluding: protected) {
            let marker = text.substring(with: match)
            let leading = marker.prefix { $0 == " " || $0 == "\t" }
            // Two spaces or one tab per nesting level, which is what both
            // Obsidian and CommonMark produce.
            let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) } + (leading.filter { $0 == " " }.count / 2)

            let kind: ListMarkerKind
            if let box = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) {
                kind = .task(checked: marker[box].lowercased().contains("x"))
            } else if marker.contains(where: \.isNumber) {
                kind = .ordered
            } else {
                kind = .bullet
            }

            // The whole marker hides, indentation included: the editor redraws
            // it as a real bullet, checkbox or numeral, and positions it from
            // the paragraph indent rather than from leading whitespace.
            result.append(MarkdownDecoration(
                range: match, syntax: [match], style: .listMarker(kind: kind, depth: depth)
            ))
        }

        for match in matches(#"(?m)^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, style: .thematicBreak))
        }

        return result
    }

    // MARK: - Block quotes and callouts

    /// Groups contiguous `>` lines into blocks, then describes each line in
    /// terms of the block around it.
    ///
    /// Per *line* rather than per block because the editor's unit of drawing is
    /// the layout fragment, and a fragment is one paragraph. Grouping still has
    /// to happen first: a line cannot know whether it rounds the top of a
    /// callout, sits in its middle, or closes it without seeing its neighbours.
    private static func quoteDecorations(
        _ text: NSString, protected: [NSRange]
    ) -> [MarkdownDecoration] {
        var runs: [[NSRange]] = []
        var run: [NSRange] = []

        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            if markerRange(inQuoteLine: line, text) != nil {
                run.append(line)
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        if !run.isEmpty { runs.append(run) }

        var result: [MarkdownDecoration] = []
        for lines in runs {
            let span = NSRange(
                location: lines[0].location,
                length: NSMaxRange(lines[lines.count - 1]) - lines[0].location
            )
            guard !protected.contains(where: { NSIntersectionRange($0, span).length > 0 })
            else { continue }

            // Only the block's opening line can declare a callout, and it
            // applies to every line beneath it.
            var callout: (kind: CalloutKind?, raw: String, title: String, syntax: NSRange)?
            if let marker = markerRange(inQuoteLine: lines[0], text) {
                callout = calloutHeader(after: marker, in: lines[0], text)
            }

            for (index, line) in lines.enumerated() {
                guard let marker = markerRange(inQuoteLine: line, text) else { continue }
                let edge: QuoteEdge
                if lines.count == 1 { edge = .only }
                else if index == 0 { edge = .first }
                else if index == lines.count - 1 { edge = .last }
                else { edge = .middle }

                var syntax = [marker]
                var title: String?
                if let callout {
                    if index == 0 {
                        // `[!note]-` is markup, but the title beside it is
                        // prose and stays visible.
                        syntax.append(callout.syntax)
                        title = callout.title
                    }
                }

                result.append(MarkdownDecoration(
                    range: line,
                    syntax: syntax,
                    style: .quoteLine(QuoteLine(
                        depth: depth(ofMarker: marker, text),
                        edge: edge,
                        callout: callout?.kind,
                        rawCallout: callout?.raw,
                        title: title
                    ))
                ))
            }
        }
        return result
    }

    /// The `> ` (or `>>`, `> > `) prefix of a quote line, or nil for prose.
    private static func markerRange(inQuoteLine line: NSRange, _ text: NSString) -> NSRange? {
        guard line.length > 0 else { return nil }
        let source = text.substring(with: line)
        guard let found = source.range(
            of: #"^[ \t]*(?:>[ \t]?)+"#, options: .regularExpression
        ) else { return nil }
        // The pattern is anchored, so the marker starts where the line does and
        // only its length has to be converted into UTF-16 units.
        return NSRange(
            location: line.location, length: (String(source[found]) as NSString).length
        )
    }

    private static func depth(ofMarker marker: NSRange, _ text: NSString) -> Int {
        max(1, text.substring(with: marker).count(where: { $0 == ">" }))
    }

    /// Parses `[!warning]- Some title` sitting just after a quote marker.
    private static func calloutHeader(
        after marker: NSRange, in line: NSRange, _ text: NSString
    ) -> (kind: CalloutKind?, raw: String, title: String, syntax: NSRange)? {
        let bodyStart = NSMaxRange(marker)
        let bodyLength = NSMaxRange(line) - bodyStart
        guard bodyLength > 0 else { return nil }
        let body = text.substring(with: NSRange(location: bodyStart, length: bodyLength))

        // The trailing `+`/`-` is Obsidian's fold state. Heft does not fold
        // yet, but the character is still markup and must not be shown.
        guard let match = body.range(
            of: #"^\[!([A-Za-z][A-Za-z0-9_-]*)\][+-]?[ \t]*"#, options: .regularExpression
        ) else { return nil }

        let header = String(body[match])
        guard let name = header.range(of: #"[A-Za-z][A-Za-z0-9_-]*"#, options: .regularExpression)
        else { return nil }
        let raw = String(header[name])

        let title = String(body[match.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            CalloutKind.parse(raw), raw, title,
            NSRange(location: bodyStart, length: (header as NSString).length)
        )
    }

    // MARK: - Inline constructs

    private static func inlineDecorations(_ text: NSString, protected initial: [NSRange]) -> [MarkdownDecoration] {
        var result: [MarkdownDecoration] = []
        var protected = initial

        func wrapped(_ pattern: String, _ markerLength: Int, _ style: MarkdownDecoration.Style) {
            for match in matches(pattern, text, excluding: protected) {
                result.append(MarkdownDecoration(
                    range: match,
                    syntax: [NSRange(location: match.location, length: markerLength),
                             NSRange(location: NSMaxRange(match) - markerLength, length: markerLength)],
                    style: style
                ))
            }
        }

        wrapped(#"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#, 2, .bold)
        wrapped(#"(?<![*\w])\*(?=[^\s*])([^\n*]+?)(?<=[^\s*])\*(?![*\w])"#, 1, .italic)
        wrapped(#"(?<![_\w])_(?=\S)([^\n_]+?)(?<=\S)_(?![_\w])"#, 1, .italic)
        wrapped(#"~~(?=\S)([^\n]+?)(?<=\S)~~"#, 2, .strikethrough)
        wrapped(#"==(?=\S)([^\n]+?)(?<=\S)=="#, 2, .highlight)

        // Wikilinks and embeds. The alias marker `Target|` is hidden too, so the
        // reader sees just the alias, as Obsidian does.
        for match in matches(#"!?\[\[[^\]\n]+\]\]"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            let isEmbed = raw.hasPrefix("!")
            let openLength = isEmbed ? 3 : 2
            var syntax = [
                NSRange(location: match.location, length: openLength),
                NSRange(location: NSMaxRange(match) - 2, length: 2),
            ]

            let bodyStart = match.location + openLength
            let bodyLength = match.length - openLength - 2
            let body = text.substring(with: NSRange(location: bodyStart, length: bodyLength))

            if let pipe = body.firstIndex(of: "|") {
                let prefix = body.distance(from: body.startIndex, to: pipe) + 1
                syntax.append(NSRange(location: bodyStart, length: prefix))
            }

            let link = WikiLinkParser.links(in: raw).first
                ?? WikiLink(target: body, isEmbed: isEmbed)
            result.append(MarkdownDecoration(
                range: match, syntax: syntax, style: .wikiLink(link)
            ))
            protected.append(match)
        }

        // Images before links: `![alt](x.png)` contains a valid link match, and
        // whichever runs first claims the range.
        for match in matches(#"!\[([^\]\n]*)\]\(([^)\n]+)\)"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            guard let close = raw.range(of: "](") else { continue }
            let alt = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<close.lowerBound])
            let source = String(raw[close.upperBound...].dropLast())
            result.append(MarkdownDecoration(
                range: match, syntax: [match], style: .image(source: source, alt: alt)
            ))
            protected.append(match)
        }

        for match in matches(#"\[([^\]\n]*)\]\(([^)\n]+)\)"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            guard let close = raw.range(of: "](") else { continue }
            // Length of the label alone, excluding the opening bracket, so the
            // trailing `](url)` range starts exactly on the `]`.
            let labelLength = raw.distance(from: raw.index(after: raw.startIndex), to: close.lowerBound)
            let destination = String(raw[close.upperBound...].dropLast())
            result.append(MarkdownDecoration(
                range: match,
                syntax: [
                    NSRange(location: match.location, length: 1),
                    NSRange(location: match.location + 1 + labelLength,
                            length: match.length - labelLength - 1),
                ],
                style: .link(destination: destination)
            ))
        }

        for match in matches(#"(?<![\w/&])#[A-Za-z][\w/-]*"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, style: .tag))
        }

        return result
    }

    // MARK: - Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        // Patterns are literals in this file; a failure is a programmer error.
        let made = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        cache[pattern] = made
        return made
    }

    private static func matches(_ pattern: String, _ text: NSString, excluding: [NSRange] = []) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        return regex(pattern).matches(in: text as String, range: full)
            .map(\.range)
            .filter { candidate in
                !excluding.contains { NSIntersectionRange($0, candidate).length > 0 }
            }
    }

    private static func firstMatch(_ pattern: String, _ text: NSString) -> NSRange? {
        matches(pattern, text).first
    }

    private static func languageOfFence(_ range: NSRange, _ text: NSString) -> String? {
        let firstLineEnd = text.range(of: "\n", options: [], range: range)
        guard firstLineEnd.location != NSNotFound else { return nil }
        let header = text.substring(with: NSRange(
            location: range.location, length: firstLineEnd.location - range.location
        ))
        let language = header.trimmingCharacters(in: CharacterSet(charactersIn: " \t`~"))
        return language.isEmpty ? nil : language
    }

    /// The opening fence line and the closing fence, which live mode hides.
    private static func fenceSyntaxRanges(_ range: NSRange, _ text: NSString) -> [NSRange] {
        var syntax = openingFenceSyntaxRange(range, text).map { [$0] } ?? []
        if let lastNewline = lastIndexOfNewline(in: range, text) {
            syntax.append(NSRange(location: lastNewline, length: NSMaxRange(range) - lastNewline))
        }
        return syntax
    }

    private static func openingFenceSyntaxRange(_ range: NSRange, _ text: NSString) -> NSRange? {
        let firstLineEnd = text.range(of: "\n", options: [], range: range)
        guard firstLineEnd.location != NSNotFound else { return nil }
        return NSRange(
            location: range.location,
            length: firstLineEnd.location - range.location + 1
        )
    }

    private static func lastIndexOfNewline(in range: NSRange, _ text: NSString) -> Int? {
        let found = text.range(of: "\n", options: .backwards, range: range)
        return found.location == NSNotFound ? nil : found.location
    }
}
