import Foundation

/// Where a dictionary has no business.
///
/// The buffer is the file, so the spell checker sees the markdown source: the
/// contents of a fenced block, an inline code span, a `#tag`, a LaTeX formula
/// and the YAML at the top are all just words to it, and it underlines
/// `thatIsNotAWord`, `projekt` and `\alpha` alike. Those are the spans that
/// come out of the decorator already, so the exclusion list is derived from
/// the same parse the styling uses rather than from a second scan.
///
/// Prose inside markup stays checked, which is why this excludes by style and
/// not by "has syntax": the word in `**recieve**` is a typo whether or not the
/// asterisks are hidden.
public enum SpellCheckScope {
    /// The decoration styles whose whole text is not prose.
    ///
    /// A link or a wikilink is not here: its label is prose, and its
    /// destination is hidden syntax, which the rule below covers. Nor is a
    /// comment or an image, for the same reason from the other side: both are
    /// hidden whole, so both drop out without being named.
    ///
    /// The three label constructs are: `[^fn]`, the `[^fn]:` that opens its
    /// definition, and the whole `[label]: /url "title"` line. They are names
    /// a document refers to itself by rather than words, and the definition
    /// decoration stops at the colon, so the prose that follows stays checked.
    /// The reference line's own quoted title is the one piece of prose given
    /// up here, and it is the rarest corner of the syntax.
    static func isExcluded(_ style: MarkdownDecoration.Style) -> Bool {
        switch style {
        case .inlineCode, .codeBlock, .tag, .frontmatter, .inlineMath, .blockMath,
             .footnoteReference, .footnoteDefinition, .referenceDefinition:
            true
        default:
            false
        }
    }

    /// Whether a decoration's hidden markers can hold a word at all.
    ///
    /// `**`, `# ` and `[[` cannot, and adding every one of them would put a
    /// range in the list for every emphasis in the note. What can: a link's
    /// `](notes/my-file.md)`, a wikilink's `target|` before its alias, and the
    /// whole of an image, which is drawn rather than read.
    private static func holdsWords(_ text: NSString, _ range: NSRange) -> Bool {
        text.rangeOfCharacter(from: .letters, options: [], range: range).location != NSNotFound
    }

    /// The excluded spans, sorted and merged so that `excludes(_:in:)` can
    /// binary search them.
    ///
    /// Three sources, because "not prose" takes three shapes. A style whose
    /// whole text is source. The hidden markers of any decoration, which is
    /// how a link's destination is skipped while its label is still checked:
    /// a word the reader never sees is not a word to check. And a table's
    /// cells, which are markdown the decorator does not descend into, so the
    /// code span in one has to be found by decorating the cell itself.
    ///
    /// Merging matters as much as sorting: these overlap freely, and a search
    /// that assumed disjoint ranges would step past the outer one.
    public static func exclusions(
        for decorations: [MarkdownDecoration], in text: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        for decoration in decorations {
            if isExcluded(decoration.style), decoration.range.length > 0 {
                ranges.append(decoration.range)
            }
            for marker in decoration.syntax where marker.length > 0 && holdsWords(text, marker) {
                ranges.append(marker)
            }
            if case .table(let layout) = decoration.style {
                ranges.append(contentsOf: cellExclusions(of: layout, in: text))
            }
        }
        ranges.sort { $0.location < $1.location }

        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A table is carried as one decoration, so nothing inside it is otherwise
    /// seen: `| `code` | #tag |` is a row of prose as far as the checker is
    /// concerned. The cells are markdown source, so decorating each one and
    /// moving the result to where the cell sits finds what is in them.
    ///
    /// A cell whose recorded range does not match its text is skipped rather
    /// than guessed at; an offset that is wrong by one silences the wrong word.
    private static func cellExclusions(of layout: TableLayout, in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        for (rowIndex, row) in layout.rawRows.enumerated() {
            guard rowIndex < layout.cellRanges.count else { break }
            for (cellIndex, cell) in row.enumerated() {
                guard cellIndex < layout.cellRanges[rowIndex].count else { break }
                let span = layout.cellRanges[rowIndex][cellIndex]
                let source = cell as NSString
                guard source.length == span.length else { continue }
                for inner in exclusions(for: LiveDecorator.decorations(in: cell), in: source) {
                    ranges.append(NSRange(location: span.location + inner.location, length: inner.length))
                }
            }
        }
        return ranges
    }

    /// Whether a word the checker wants to mark falls in an excluded span.
    ///
    /// Any overlap counts. A checker that runs over `foo_bar_baz` hands back
    /// the whole identifier, but one running over a fence's opening line can
    /// hand back a word that only half overlaps, and marking half of it is
    /// worse than marking none.
    public static func excludes(_ range: NSRange, in exclusions: [NSRange]) -> Bool {
        var low = 0
        var high = exclusions.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = exclusions[middle]
            if NSIntersectionRange(candidate, range).length > 0 { return true }
            // A zero-length range intersects nothing, so a caret-sized query
            // has to be compared by position rather than by overlap.
            if range.length == 0, NSLocationInRange(range.location, candidate) { return true }
            if NSMaxRange(candidate) <= range.location {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return false
    }
}
