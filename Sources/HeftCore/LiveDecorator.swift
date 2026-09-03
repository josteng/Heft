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
        case comment
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
        /// `[^1]` in the prose. The label is kept so the editor can draw the
        /// reference raised, and so a click could one day find its definition.
        case footnoteReference(label: String)
        /// `[^1]:` opening a definition line.
        case footnoteDefinition(label: String)
        /// An emphasis delimiter that has been opened and not yet closed:
        /// `**bold` while it is still being typed. `level` is 1 for `*` and 2
        /// for `**`. Carries no `syntax`, because an unclosed delimiter is
        /// literal text in the file and hiding it would misrepresent it.
        case pendingEmphasis(level: Int)
        case inlineMath(String)
        case blockMath(String)
        case thematicBreak
        /// One of the two markers fencing the section `heft agent-setup`
        /// rewrites. Drawn as a labelled rule so the boundary is visible: as a
        /// bare HTML comment it disappears, and a note typed at what looks
        /// like the end of the file is in fact on managed ground.
        case agentGuideBoundary(isEnd: Bool)
    }

    public let range: NSRange
    public let syntax: [NSRange]
    /// Optional smaller range that activates source reveal. A list's trailing
    /// space belongs to hidden syntax but not to its marker: the normal typing
    /// caret sits after that space and should continue to see the rendered
    /// bullet, numeral or checkbox.
    public let revealRange: NSRange?
    public let style: Style

    public init(
        range: NSRange, syntax: [NSRange] = [],
        revealRange: NSRange? = nil, style: Style
    ) {
        self.range = range
        self.syntax = syntax
        self.revealRange = revealRange
        self.style = style
    }

    /// The same construct, moved along the document.
    ///
    /// Inserting a character above a decoration moves it without changing it,
    /// and `RestyleScope` shifts the previous pass's decorations by that much
    /// to see which ones really are unchanged and can keep their styling.
    public func shifted(by delta: Int) -> MarkdownDecoration {
        func move(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }
        return MarkdownDecoration(
            range: move(range),
            syntax: syntax.map(move),
            revealRange: revealRange.map(move),
            style: style
        )
    }
}

/// A GFM table reduced to raw cell text plus column alignment.
///
/// Cells stay as markdown source: the editor runs the decorator over each one
/// again when it draws, so `**bold**` and `[[links]]` inside a cell get the
/// same treatment they do in prose.
///
/// Every cell also carries where it came from. That is what lets the caret sit
/// *inside* a drawn table rather than dissolving it back into pipes: the
/// editor maps an insertion point to a cell, draws that one cell as source,
/// and leaves the rest of the grid rendered.
public struct TableLayout: Sendable, Hashable {
    /// Row 0 is the header.
    public let rows: [[String]]
    public let alignments: [MDColumnAlignment]
    /// The same cells as they are written in the file, with `\|` left escaped.
    /// `rows` unescapes for display, which changes the length; this does not,
    /// so `rawRows[r][c]` is exactly the text `cellRanges[r][c]` covers and a
    /// caret offset in one is an offset in the other.
    public let rawRows: [[String]]
    /// Source range of each cell's trimmed content, relative to the table's
    /// own start. Parallel to `rows`.
    public let cellRanges: [[NSRange]]
    /// Each content row's line, terminator excluded, relative to the table's
    /// start. Parallel to `rows`.
    public let rowRanges: [NSRange]
    /// The `---` line, relative to the table's start. It has no row of its own
    /// because it holds no content, so a caret landing on it is the one place
    /// the whole table falls back to plain source.
    public let delimiterRange: NSRange
    /// Length of the source the table was parsed from, so an offset past the
    /// last cell can still be clamped into one.
    public let sourceLength: Int

    public init(
        rows: [[String]],
        alignments: [MDColumnAlignment],
        rawRows: [[String]] = [],
        cellRanges: [[NSRange]] = [],
        rowRanges: [NSRange] = [],
        delimiterRange: NSRange = NSRange(location: NSNotFound, length: 0),
        sourceLength: Int = 0
    ) {
        self.rows = rows
        self.alignments = alignments
        self.rawRows = rawRows.isEmpty ? rows : rawRows
        self.cellRanges = cellRanges
        self.rowRanges = rowRanges
        self.delimiterRange = delimiterRange
        self.sourceLength = sourceLength
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

/// Where a line sits inside the run of `>` lines it belongs to. The editor
/// paints a callout's card across several paragraphs, so each one needs to know
/// which of its corners to round.
public enum QuoteEdge: Sendable, Equatable { case only, first, middle, last }

/// A block construct written *inside* a quote, after its `>` markers.
///
/// The block matchers are anchored to the start of a line, so `> - item` used
/// to be quoted prose: no bullet, no indent, and `> ## Heading` was quoted
/// text at body size. A quote is where a lot of real notes keep their lists,
/// so this is the difference between quoting a passage and quoting a document.
///
/// Carried on the quote line rather than emitted as its own decoration
/// because the editor draws one widget per line: a bullet and a quote bar on
/// the same line are one thing to draw, not two competing for the same key.
public enum QuotedBlock: Sendable, Equatable {
    /// `marker` is the literal source of the marker, `- ` or `1. ` or
    /// `- [x] `, exactly as an unquoted list carries it. The glyph is
    /// positioned from it, so revealing the source swaps in place instead of
    /// making the bullet jump sideways.
    case list(kind: ListMarkerKind, depth: Int, marker: String)
    case heading(level: Int)
}

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
    /// A list item or heading written inside the quote, if any.
    public let nested: QuotedBlock?

    public init(
        depth: Int, edge: QuoteEdge, callout: CalloutKind? = nil,
        rawCallout: String? = nil, title: String? = nil,
        nested: QuotedBlock? = nil
    ) {
        self.depth = depth
        self.edge = edge
        self.callout = callout
        self.rawCallout = rawCallout
        self.title = title
        self.nested = nested
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

/// How a bullet is drawn at a given nesting level.
///
/// Depth is otherwise invisible in a live surface: the indent alone is easy to
/// lose track of once a list runs past a few items. Browsers have shaded
/// nested lists this way since the beginning — `list-style-type` defaults to
/// disc, then circle, then square — and Obsidian, Bear and most Markdown
/// editors inherit it, so it is the shape people already read as "one level
/// in" rather than a private convention.
public enum BulletShape: Sendable, Equatable, CaseIterable {
    /// A filled dot, for the outermost items.
    case disc
    /// A hollow ring: the same dot, one level in.
    case circle
    /// A filled square.
    case square

    /// The shape for `level`, counting the outermost list as zero.
    ///
    /// The three repeat rather than growing indefinitely. Lists nested four
    /// deep are rare enough that inventing further shapes would trade a
    /// familiar cycle for glyphs nobody recognises, and the indent is still
    /// there to say which level is which.
    public static func forLevel(_ level: Int) -> BulletShape {
        let cycle = allCases
        return cycle[max(0, level) % cycle.count]
    }
}

public enum ListMarkerKind: Sendable, Equatable {
    /// `-`, `*` or `+`: replaced by a drawn bullet, whose shape says how
    /// deeply the item is nested.
    case bullet(shape: BulletShape)
    /// `1.` / `1)`: the numeral stays legible, so it is only dimmed.
    case ordered
    /// `- [ ]` / `- [x]`: replaced by a drawn checkbox.
    case task(TaskState)
}

/// What is written between a task's brackets.
///
/// Obsidian puts a checkbox on *any* `- [c]`, whatever the character, and
/// carries that character through for a theme to style — which is how the
/// `[/]`, `[-]`, `[>]` and `[?]` conventions came to be so widespread. Reading
/// only `[ ]` and `[x]` made every one of those render as a plain bullet, so a
/// note full of half-done work looked like a note full of prose.
public enum TaskState: Sendable, Equatable {
    case unchecked
    case done
    /// Anything else between the brackets, kept so it can be drawn.
    case other(Character)

    public init(marker: Character) {
        switch marker {
        case " ", "\t": self = .unchecked
        case "x", "X": self = .done
        default: self = .other(marker)
        }
    }

    /// Whether the item counts as finished. Only `[x]` does: `[/]` is in
    /// progress and `[-]` is abandoned, and striking either through would say
    /// the work was completed.
    public var isDone: Bool { self == .done }
}

/// What the caret currently exposes as literal markdown source.
///
/// Two ranges rather than one because Obsidian treats block and inline markup
/// differently, and matching that is most of what makes the surface feel right.
/// A heading's `#` comes back as soon as the caret is anywhere on its line; a
/// `**bold**` pair comes back only when the caret is inside *that* span, so the
/// rest of the sentence stays rendered.
/// What one reveal pass decided about a single construct.
///
/// `cell` exists because a table is never wholly revealed while it is being
/// edited: the grid stays drawn and one cell shows its markdown source. The
/// restyle diff compares these values, so moving the caret from one cell to
/// the next is a change even though both are "not revealed".
public enum RevealState: Equatable, Sendable {
    case hidden
    case revealed
    case cell(row: Int, column: Int)
}

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
        state(of: decoration) == .revealed
    }

    /// How `decoration` is styled under this reveal.
    ///
    /// Two states for everything except a table, which has a third: the grid
    /// is drawn whether or not the caret is inside it, and only which *cell*
    /// shows its source changes. That is what stops clicking a table from
    /// dissolving the whole thing into pipes, and it is why the restyle diff
    /// compares this rather than a bare "is it revealed".
    public func state(of decoration: MarkdownDecoration) -> RevealState {
        if case .table(let table) = decoration.style {
            guard touchesLine(decoration.range) else { return .hidden }
            guard let cursor = table.cursor(
                for: selection, tableStart: decoration.range.location
            ) else {
                // The delimiter row, or a selection spanning cells: there is no
                // one cell to edit, so fall back to plain source.
                return .revealed
            }
            return .cell(row: cursor.row, column: cursor.column)
        }
        if Self.revealsWithItsLine(decoration.style) {
            return touchesLine(decoration.range) ? .revealed : .hidden
        }
        return Self.touches(decoration.revealRange ?? decoration.range, selection)
            ? .revealed : .hidden
    }

    private func touchesLine(_ range: NSRange) -> Bool {
        guard line.location != NSNotFound else { return false }
        return NSIntersectionRange(range, line).length > 0
    }

    /// True for markup belonging to the line as a whole, so that putting the
    /// caret anywhere on that line brings it back.
    ///
    /// Everything else is an inline span and returns only when the caret is
    /// inside it. The split is what stops a sentence full of `**bold**` from
    /// dissolving into raw asterisks the moment it is clicked.
    public static func revealsWithItsLine(_ style: MarkdownDecoration.Style) -> Bool {
        switch style {
        case .frontmatter, .comment, .codeBlock, .heading, .quoteLine,
             .table, .thematicBreak, .blockMath, .image, .agentGuideBoundary,
             // A definition *is* its line, and its `[^1]:` sits at the start
             // of it, where a caret arriving from the line above lands.
             .footnoteDefinition:
            true
        // An embed owning its line is drawn as a block, so it behaves like one.
        case .wikiLink(let link):
            link.isEmbed
        case .listMarker, .bold, .italic, .strikethrough, .highlight, .inlineCode,
             .link, .tag, .inlineMath, .footnoteReference:
            false
        // Not really a reveal: this is the one style that is *applied* on the
        // caret's line rather than undone there. Riding the line rule is what
        // keeps it to the line being typed — an unclosed `*` left in a note
        // years ago must not italicise the rest of its line forever.
        case .pendingEmphasis:
            true
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

/// The ranges no further pattern may match inside, kept sorted and merged.
///
/// Every construct found protects its own span, so by the time inline spans are
/// matched the set holds one entry per heading, list marker, quote marker and
/// code span in the note. Testing each new candidate against all of them in
/// turn made decoration quadratic in the size of the document, which is what
/// made a long note noticeably slower to type in than a short one. Union
/// membership is the only question ever asked of this set, so overlapping and
/// abutting ranges merge on the way in and a binary search answers it.
struct ProtectedRanges {
    private var ranges: [NSRange] = []

    init() {}

    /// True when `candidate` overlaps any protected range. Zero-length
    /// candidates never do, matching the intersection test this replaced.
    func intersects(_ candidate: NSRange) -> Bool {
        guard candidate.length > 0, !ranges.isEmpty else { return false }
        // The first range that could reach past the candidate's start.
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= candidate.location { low = mid + 1 } else { high = mid }
        }
        guard low < ranges.count else { return false }
        return ranges[low].location < NSMaxRange(candidate)
    }

    mutating func insert(_ range: NSRange) {
        guard range.length > 0 else { return }
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) < range.location { low = mid + 1 } else { high = mid }
        }
        // `low` is the first range that touches or follows the new one; absorb
        // every range it reaches, so the array stays disjoint and sorted.
        var start = range.location
        var end = NSMaxRange(range)
        var last = low
        while last < ranges.count, ranges[last].location <= end {
            start = min(start, ranges[last].location)
            end = max(end, NSMaxRange(ranges[last]))
            last += 1
        }
        ranges.replaceSubrange(low..<last, with: [
            NSRange(location: start, length: end - start),
        ])
    }

    mutating func insert(contentsOf newRanges: [NSRange]) {
        for range in newRanges { insert(range) }
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
        var protected = ProtectedRanges()

        if let fm = firstMatch(#"\A---\n[\s\S]*?\n---"#, text) {
            result.append(MarkdownDecoration(range: fm, style: .frontmatter))
            protected.insert(fm)
        }

        for match in matches(#"(?m)^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?^[ \t]*\1[ \t]*$"#, text, excluding: protected) {
            let language = languageOfFence(match, text)
            result.append(MarkdownDecoration(
                range: match, syntax: fenceSyntaxRanges(match, text), style: .codeBlock(language: language)
            ))
            protected.insert(match)
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
            protected.insert(match)
        }

        // Tables claim their lines whole: the editor draws a grid rather than
        // styling pipes, so nothing inside may be matched independently.
        for match in matches(tablePattern, text, excluding: protected) {
            guard let layout = parseTable(text.substring(with: match)) else { continue }
            result.append(MarkdownDecoration(range: match, style: .table(layout)))
            protected.insert(match)
        }

        // The agent-guide markers are claimed before the general comment
        // sweep, which would otherwise hide them as ordinary metadata and
        // leave the boundary invisible.
        for (marker, isEnd) in [(AgentGuide.markerStart, false), (AgentGuide.markerEnd, true)] {
            var searchStart = 0
            while searchStart < text.length {
                let found = text.range(
                    of: marker,
                    range: NSRange(location: searchStart, length: text.length - searchStart)
                )
                guard found.location != NSNotFound else { break }
                searchStart = NSMaxRange(found)
                guard !protected.intersects(found) else { continue }
                result.append(MarkdownDecoration(
                    range: found,
                    syntax: [found],
                    style: .agentGuideBoundary(isEnd: isEnd)
                ))
                protected.insert(found)
            }
        }

        // Comments are metadata, not visible prose. Keep them in the buffer
        // and reveal them on their line for editing, while shielding any
        // markdown-looking text inside from further decoration.
        //
        // Both spellings: `<!-- -->` is HTML's and `%% %%` is Obsidian's own,
        // which a vault written in Obsidian is full of and which showed here
        // as literal text with the percent signs and all. Both forms span
        // lines, because both are allowed to.
        // Obsidian's own form has two shapes and they are matched separately:
        // `%%` alone on a line opens a block comment that runs to the next
        // such line, while `%%…%%` inside a line is an inline one. Matching
        // one loose `%%[\s\S]*?%%` for both would let an inline comment leap
        // across lines and swallow the prose between two unrelated `%%` —
        // which prose about percentages really can contain.
        for match in matches(
            #"<!--[\s\S]*?-->"#
                + #"|(?m)^[ \t]*%%[ \t]*$[\s\S]*?^[ \t]*%%[ \t]*$"#
                + #"|%%[^\n]*?%%"#,
            text, excluding: protected
        ) {
            result.append(MarkdownDecoration(
                range: match,
                syntax: [match],
                style: .comment
            ))
            protected.insert(match)
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
        protected.insert(contentsOf: blocks.flatMap(\.syntax))

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
            protected.insert(match)
        }

        for match in matches(#"`[^`\n]+`"#, text, excluding: protected) {
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 1),
                         NSRange(location: NSMaxRange(match) - 1, length: 1)],
                style: .inlineCode
            ))
            protected.insert(match)
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
            protected.insert(match)
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
    ///
    /// Everything is measured in UTF-16 offsets from the start of `source`,
    /// because that is what the editor has to work with: a decoration range in
    /// the document, plus a caret somewhere inside it.
    static func parseTable(_ source: String) -> TableLayout? {
        let text = source as NSString
        let lines = contentLines(of: text)
        guard lines.count >= 2 else { return nil }

        let delimiterCells = splitRow(text, lines[1])
        guard !delimiterCells.isEmpty,
              delimiterCells.allSatisfy({
                  $0.text.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
              })
        else { return nil }

        let alignments: [MDColumnAlignment] = delimiterCells.map { cell in
            switch (cell.text.hasPrefix(":"), cell.text.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }

        let contentRows = [lines[0]] + lines.dropFirst(2)
        let split = contentRows.map { splitRow(text, $0) }
        return TableLayout(
            rows: split.map { $0.map { unescapePipes($0.text) } },
            alignments: alignments,
            rawRows: split.map { $0.map(\.text) },
            cellRanges: split.map { $0.map(\.range) },
            rowRanges: contentRows,
            delimiterRange: lines[1],
            sourceLength: text.length
        )
    }

    /// The non-blank lines of `text`, terminators excluded.
    private static func contentLines(of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            while content.length > 0 {
                let character = text.character(at: NSMaxRange(content) - 1)
                guard character == 10 || character == 13 else { break }
                content.length -= 1
            }
            if !text.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(content)
            }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        return result
    }

    /// `| a | b |` to `["a", "b"]`, each with the range its text occupies.
    ///
    /// Obsidian writes `\|` for a literal pipe inside a cell, so that escape
    /// has to survive the split: an escaped pipe is not a cell boundary. The
    /// text keeps its backslash here, because unescaping changes the length
    /// and the range has to stay a description of what is in the file.
    static func splitRow(_ text: NSString, _ line: NSRange) -> [(text: String, range: NSRange)] {
        var boundaries: [Int] = []
        var escaped = false
        var index = line.location
        while index < NSMaxRange(line) {
            let character = text.character(at: index)
            if escaped {
                escaped = false
            } else if character == 92 {
                escaped = true
            } else if character == 124 {
                boundaries.append(index)
            }
            index += 1
        }

        var spans: [NSRange] = []
        var cursor = line.location
        for pipe in boundaries {
            spans.append(NSRange(location: cursor, length: pipe - cursor))
            cursor = pipe + 1
        }
        spans.append(NSRange(location: cursor, length: NSMaxRange(line) - cursor))

        func isBlank(_ range: NSRange) -> Bool {
            text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
        }
        // A well-formed row is bracketed by pipes, which leaves an empty span
        // at each end.
        if let first = spans.first, isBlank(first) { spans.removeFirst() }
        if spans.count > 1, let last = spans.last, isBlank(last) { spans.removeLast() }

        return spans.map { span in
            let trimmed = trimming(text, span)
            return (text.substring(with: trimmed), trimmed)
        }
    }

    /// `span` with its surrounding spaces and tabs removed. An all-blank span
    /// collapses onto the position just inside its leading pad, which is where
    /// typing into an empty cell should land: `| x |`, not `|x  |`.
    private static func trimming(_ text: NSString, _ span: NSRange) -> NSRange {
        var start = span.location
        var end = NSMaxRange(span)
        while start < end {
            let character = text.character(at: start)
            guard character == 32 || character == 9 else { break }
            start += 1
        }
        while end > start {
            let character = text.character(at: end - 1)
            guard character == 32 || character == 9 else { break }
            end -= 1
        }
        if start == end, span.length > 0 {
            return NSRange(location: min(span.location + 1, NSMaxRange(span)), length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func unescapePipes(_ cell: String) -> String {
        guard cell.contains("\\") else { return cell }
        var result = ""
        var escaped = false
        for character in cell {
            if escaped {
                result.append(character == "|" ? "|" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
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

    private static func blockDecorations(_ text: NSString, protected: ProtectedRanges) -> [MarkdownDecoration] {
        var result: [MarkdownDecoration] = []

        // Treat a marker-only line as a provisional heading while it is being
        // typed. CommonMark needs a following space and content, but waiting
        // for the first title character makes the editor visibly jump from
        // body text to H1. This also lets successive # characters preview H1,
        // H2, and so on immediately; "#tag" remains ordinary tag syntax.
        for match in matches(
            #"(?m)^(#{1,6})(?:[ \t]+.*)?$"#, text, excluding: protected
        ) {
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

        // Any single character between the brackets, not just ` `, `x` and
        // `X`: Obsidian puts a checkbox on every `- [c]` and carries the
        // character through for a theme to style, which is where the `[/]`,
        // `[-]` and `[>]` conventions come from. Narrowing it here made all of
        // those render as plain bullets, so a note full of half-done work
        // looked like a note full of prose.
        for match in matches(
            #"(?m)^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[^\]\n]\][ \t]+)?"#, text, excluding: protected
        ) {
            let marker = text.substring(with: match)
            let leading = marker.prefix { $0 == " " || $0 == "\t" }
            // Two spaces or one tab per nesting level, which is what both
            // Obsidian and CommonMark produce.
            let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) } + (leading.filter { $0 == " " }.count / 2)

            // Scanned rather than matched with `\[[ xX]\]`, for the same reason
            // quote markers are: this is once per list item, and building a
            // regular expression each time costs more than the whole document
            // scan that found the item.
            let kind: ListMarkerKind
            if let box = checkboxState(in: marker) {
                kind = .task(box)
            } else if marker.contains(where: \.isNumber) {
                kind = .ordered
            } else {
                kind = .bullet(shape: .forLevel(depth))
            }

            // The whole marker hides, indentation included: the editor redraws
            // it as a real bullet, checkbox or numeral, and positions it from
            // the paragraph indent rather than from leading whitespace.
            let visible = String(marker.dropFirst(leading.utf16.count))
            let semanticLength = visible
                .trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
            let revealRange = NSRange(
                location: match.location + leading.utf16.count,
                length: semanticLength
            )
            result.append(MarkdownDecoration(
                range: match, syntax: [match], revealRange: revealRange,
                style: .listMarker(kind: kind, depth: depth)
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
        _ text: NSString, protected: ProtectedRanges
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
            guard !protected.intersects(span) else { continue }

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
                var isCalloutHeaderLine = false
                if let callout {
                    if index == 0 {
                        // `[!note]-` is markup, but the title beside it is
                        // prose and stays visible.
                        syntax.append(callout.syntax)
                        title = callout.title
                        isCalloutHeaderLine = true
                    }
                }

                // A list or heading written after the `>` markers. Never on a
                // callout's header line, where `[!kind]` has already claimed
                // what follows the marker.
                var nested: QuotedBlock?
                if !isCalloutHeaderLine,
                   let found = quotedBlock(after: marker, in: line, text) {
                    nested = found.block
                    syntax.append(found.syntax)
                }

                result.append(MarkdownDecoration(
                    range: line,
                    syntax: syntax,
                    style: .quoteLine(QuoteLine(
                        depth: depth(ofMarker: marker, text),
                        edge: edge,
                        callout: callout?.kind,
                        rawCallout: callout?.raw,
                        title: title,
                        nested: nested
                    ))
                ))
            }
        }
        return result
    }

    /// A list marker or ATX heading sitting just after a quote's `>` markers.
    ///
    /// Scanned by hand for the same reason `markerRange` is: this runs on
    /// every line of every quote in the document, and building a regular
    /// expression per line costs more than the whole scan that found it.
    ///
    /// Returns the block *and* the range of the markup that introduces it, so
    /// the caller can collapse it exactly as the unquoted forms are collapsed.
    private static func quotedBlock(
        after marker: NSRange, in line: NSRange, _ text: NSString
    ) -> (block: QuotedBlock, syntax: NSRange)? {
        let start = NSMaxRange(marker)
        var end = NSMaxRange(line)
        while end > start, isNewline(text.character(at: end - 1)) { end -= 1 }
        guard start < end else { return nil }

        // Indentation *inside* the quote is what nests the list, so it is
        // measured from where the quote's own markers stop rather than from
        // the start of the line.
        var index = start
        var spaces = 0
        var tabs = 0
        while index < end, isBlank(text.character(at: index)) {
            if text.character(at: index) == UInt16(9) { tabs += 1 } else { spaces += 1 }
            index += 1
        }
        guard index < end else { return nil }

        if text.character(at: index) == UInt16(35) {  // "#"
            var level = 0
            while index < end, text.character(at: index) == UInt16(35), level < 6 {
                level += 1
                index += 1
            }
            // CommonMark wants a space after the hashes; without one this is a
            // tag, not a heading.
            guard index < end, isBlank(text.character(at: index)) else { return nil }
            while index < end, isBlank(text.character(at: index)) { index += 1 }
            return (.heading(level: level), NSRange(location: start, length: index - start))
        }

        let depth = tabs + spaces / 2
        let bulletStart = index
        let character = text.character(at: index)
        let isBullet = character == UInt16(45) || character == UInt16(42) || character == UInt16(43)
        var isOrdered = false
        if !isBullet {
            var digits = 0
            while index < end, isDigit(text.character(at: index)) {
                digits += 1
                index += 1
            }
            guard digits > 0, index < end else { return nil }
            let delimiter = text.character(at: index)
            guard delimiter == UInt16(46) || delimiter == UInt16(41) else { return nil }
            isOrdered = true
        }
        index += 1
        // A marker with nothing after it is not a list item, it is a stray
        // character; `- ` needs its space exactly as it does outside a quote.
        guard index < end, isBlank(text.character(at: index)) else { return nil }
        while index < end, isBlank(text.character(at: index)) { index += 1 }

        var kind: ListMarkerKind = isOrdered ? .ordered : .bullet(shape: .forLevel(depth))
        if !isOrdered {
            let rest = NSRange(location: bulletStart, length: end - bulletStart)
            if let box = checkboxState(in: text.substring(with: rest)) {
                kind = .task(box)
                // The box is markup too, so the collapsed run has to reach
                // past it or `[ ]` is left sitting beside the drawn checkbox.
                if let boxEnd = checkboxEnd(from: index, limit: end, text) {
                    index = boxEnd
                }
            }
        }
        let syntax = NSRange(location: start, length: index - start)
        // The marker as written, without the indentation before it: the same
        // form `.listMarker` positions its glyph from.
        let marker = text.substring(
            with: NSRange(location: bulletStart, length: NSMaxRange(syntax) - bulletStart)
        )
        return (.list(kind: kind, depth: depth, marker: marker), syntax)
    }

    /// Where `[ ] ` ends, starting from the first character after the bullet.
    private static func checkboxEnd(from start: Int, limit: Int, _ text: NSString) -> Int? {
        var index = start
        guard index < limit, text.character(at: index) == UInt16(91) else { return nil }  // "["
        index += 1
        guard index < limit else { return nil }
        index += 1
        guard index < limit, text.character(at: index) == UInt16(93) else { return nil }  // "]"
        index += 1
        guard index < limit, isBlank(text.character(at: index)) else { return nil }
        while index < limit, isBlank(text.character(at: index)) { index += 1 }
        return index
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= UInt16(48) && character <= UInt16(57)
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == UInt16(10) || character == UInt16(13)
    }

    /// The `> ` (or `>>`, `> > `) prefix of a quote line, or nil for prose.
    ///
    /// Scanned by hand rather than matched with `^[ \t]*(?:>[ \t]?)+`, because
    /// this runs on every line of the document and `range(of:options:)` builds
    /// a fresh `NSRegularExpression` on every call. Quote detection alone was
    /// most of the cost of decorating a long note.
    private static func markerRange(inQuoteLine line: NSRange, _ text: NSString) -> NSRange? {
        guard line.length > 0 else { return nil }
        let end = NSMaxRange(line)
        var index = line.location
        while index < end, isBlank(text.character(at: index)) { index += 1 }
        guard index < end, text.character(at: index) == UInt16(62) else { return nil }  // ">"
        while index < end, text.character(at: index) == UInt16(62) {
            index += 1
            // One optional space or tab per marker, exactly as the pattern's
            // `[ \t]?` allows — never two, or `>  indented` would lose a space.
            if index < end, isBlank(text.character(at: index)) { index += 1 }
        }
        return NSRange(location: line.location, length: index - line.location)
    }

    private static func isBlank(_ character: unichar) -> Bool {
        character == UInt16(32) || character == UInt16(9)
    }

    /// Whether a list marker carries a `[ ]`, `[x]` or `[X]` box, and whether
    /// it is ticked. Nil when the marker is a plain bullet or numeral.
    /// The state written in a task's brackets, or nil when there are none.
    ///
    /// Any single character counts, as it does in Obsidian. The brackets have
    /// to be immediately adjacent, which is what keeps a link label like
    /// `[a]` from being read as a task.
    private static func checkboxState(in marker: String) -> TaskState? {
        let source = marker as NSString
        guard source.length >= 3 else { return nil }
        for index in 0...(source.length - 3) where source.character(at: index) == UInt16(91) {
            guard source.character(at: index + 2) == UInt16(93) else { continue }
            let inner = source.character(at: index + 1)
            // A newline between brackets is not a task, it is a broken line.
            guard inner != UInt16(10), inner != UInt16(13) else { continue }
            guard let scalar = Unicode.Scalar(inner) else { continue }
            return TaskState(marker: Character(scalar))
        }
        return nil
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

    /// Unclosed `*`/`**`/`_`/`__` runs, one per line at most.
    ///
    /// Hand-scanned rather than matched, because the pattern would have to
    /// reach to the end of the line and `matches(_:excluding:)` rejects any
    /// candidate that so much as touches a protected range — which a line
    /// holding one code span would.
    private static func pendingEmphasis(
        _ text: NSString, protected: ProtectedRanges, closedStarts: Set<Int>
    ) -> [MarkdownDecoration] {
        let asterisk = UInt16(42)
        let underscore = UInt16(95)
        var result: [MarkdownDecoration] = []

        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, isNewline(text.character(at: end - 1)) { end -= 1 }

            var index = line.location
            while index < end {
                let character = text.character(at: index)
                guard character == asterisk || character == underscore else {
                    index += 1
                    continue
                }
                var runEnd = index
                while runEnd < end, text.character(at: runEnd) == character { runEnd += 1 }
                let length = runEnd - index
                defer { index = runEnd }

                // `***` is ambiguous mid-typing and three-deep emphasis is rare
                // enough that guessing wrong is worse than doing nothing.
                guard length == 1 || length == 2 else { continue }
                // A closed span starts here, so this delimiter is not open.
                guard !closedStarts.contains(index) else { continue }
                guard !protected.intersects(NSRange(location: index, length: length)) else { continue }

                // Must open: something has to follow, and not a space — which
                // is also what keeps a `* ` list marker and a lone `5 * 3` out.
                guard runEnd < end else { continue }
                let next = text.character(at: runEnd)
                guard !isBlank(next), next != character else { continue }

                // `_` never opens inside a word, so `snake_case` is a name and
                // not the start of an emphasis span.
                if character == underscore, index > line.location {
                    let previous = text.character(at: index - 1)
                    guard !isWordCharacter(previous), previous != underscore else { continue }
                }
                if character == asterisk, index > line.location,
                   text.character(at: index - 1) == asterisk {
                    continue
                }

                result.append(MarkdownDecoration(
                    range: NSRange(location: index, length: end - index),
                    style: .pendingEmphasis(level: length)
                ))
                break
            }

            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        return result
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        (character >= UInt16(48) && character <= UInt16(57))
            || (character >= UInt16(65) && character <= UInt16(90))
            || (character >= UInt16(97) && character <= UInt16(122))
    }

    private static func inlineDecorations(_ text: NSString, protected initial: ProtectedRanges) -> [MarkdownDecoration] {
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
        // Emphasis while it is still being typed. `**bold**` only styled once
        // the closing pair arrived, so text stayed plain until the span was
        // finished; Obsidian styles from the opening delimiter.
        //
        // Every closed span has already been matched above, so a delimiter
        // that no closed span starts on is an open one.
        let closedStarts = Set(result.compactMap { decoration -> Int? in
            switch decoration.style {
            case .bold, .italic: decoration.range.location
            default: nil
            }
        })
        result.append(contentsOf: pendingEmphasis(text, protected: protected, closedStarts: closedStarts))

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
            protected.insert(match)
        }

        // Footnotes before links, because `[^1]` is a bracket pair a looser
        // link matcher would be entitled to. Definitions before references,
        // because `[^1]:` opening a line is a definition and not a reference
        // that happens to be followed by a colon.
        //
        // The reference pattern's `(?!:)` is defence in depth rather than the
        // thing that separates them: a definition is matched and protected
        // first, so removing the lookahead changes nothing today, which
        // mutation confirms. It is kept because that is a property of the
        // ordering, not of the pattern.
        for match in matches(#"(?m)^[ \t]*\[\^([^\]\s]+)\]:"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            guard let open = raw.range(of: "[^"), let close = raw.range(of: "]:") else { continue }
            let label = String(raw[open.upperBound..<close.lowerBound])
            let openStart = match.location + raw.distance(from: raw.startIndex, to: open.lowerBound)
            result.append(MarkdownDecoration(
                range: match,
                // `[^` and `]:` hide; the label stays, so a definition still
                // reads as the numbered note it is rather than as a stray
                // paragraph that happens to sit at the bottom of the file.
                syntax: [
                    NSRange(location: openStart, length: 2),
                    NSRange(location: match.location + match.length - 2, length: 2),
                ],
                style: .footnoteDefinition(label: label)
            ))
            protected.insert(match)
        }

        for match in matches(#"\[\^([^\]\s]+)\](?!:)"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            let label = String(raw.dropFirst(2).dropLast())
            result.append(MarkdownDecoration(
                range: match,
                syntax: [
                    NSRange(location: match.location, length: 2),
                    NSRange(location: NSMaxRange(match) - 1, length: 1),
                ],
                style: .footnoteReference(label: label)
            ))
            protected.insert(match)
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
            protected.insert(match)
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

    private static func matches(
        _ pattern: String, _ text: NSString, excluding: ProtectedRanges = ProtectedRanges()
    ) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        return regex(pattern).matches(in: text as String, range: full)
            .map(\.range)
            .filter { !excluding.intersects($0) }
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
