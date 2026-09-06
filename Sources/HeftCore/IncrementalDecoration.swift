import Foundation

extension LiveDecorator {

    /// The previous parse, kept so the next one can avoid repeating it.
    /// Holds the source as `NSString` deliberately: the caller already has one
    /// and converting on every keystroke would copy the document to save
    /// parsing it.
    public struct DecorationCache {
        public let source: NSString
        public let decorations: [MarkdownDecoration]

        public init(source: NSString, decorations: [MarkdownDecoration]) {
            self.source = source
            self.decorations = decorations
        }
    }

    /// Decorations for `source`, reusing `cache` where the edit provably could
    /// not have changed anything outside one paragraph.
    ///
    /// Decorating is the largest single cost of a keystroke and it rescans the
    /// whole note every time, which is what makes typing scale with document
    /// length rather than with the edit. Almost every keystroke is a character
    /// typed into a paragraph of prose, where nothing outside that paragraph
    /// can possibly differ — so that case reparses the paragraph alone and
    /// carries the rest across, shifted.
    ///
    /// Everything else falls back to the full scan. The guards are deliberately
    /// pessimistic: a wrong reuse is a note that renders incorrectly, while a
    /// wrong fallback is merely the cost we already pay.
    public static func decorations(
        in source: NSString, reusing cache: DecorationCache?
    ) -> [MarkdownDecoration] {
        guard let cache, let reused = reuse(cache: cache, for: source)
        else { return decorations(in: source as String) }
        return reused
    }

    /// Sequences that can begin or end something spanning more than one line.
    /// A paragraph containing any of them is not safely local: adding a
    /// backtick fence changes how the rest of the note parses.
    static let multilineMarkers = ["```", "~~~", "$$", "<!--", "-->"]

    /// Whether `text` holds a marker from the list above, or a `---` where a
    /// frontmatter fence or a thematic break could stand.
    ///
    /// `---` used to be in the list outright, and it disqualified every table:
    /// a separator row is `|---|---|`, so a keystroke inside a cell went
    /// through the full rescan in a note where that costs ten times what the
    /// fast path does. The dashes only mean something at the start of a line;
    /// inside one they are a separator row, which is confined to its
    /// paragraph like the rest of the table.
    static func containsMultilineMarker(_ text: String) -> Bool {
        for marker in multilineMarkers where text.contains(marker) { return true }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("---") {
            return true
        }
        return false
    }

    /// Whether `decoration` describes text the paragraph does not contain.
    ///
    /// Range-based rather than a list of styles, because the list was wrong:
    /// it named the block constructs and missed `$…$`, which can pair across
    /// blank lines and so reach into a paragraph holding no maths of its own.
    /// A decoration wholly inside the paragraph is rebuilt by reparsing it; one
    /// that crosses the boundary is not, whatever kind it is.
    static func escapes(_ decoration: MarkdownDecoration, paragraph: NSRange) -> Bool {
        let range = decoration.range
        guard range.length > 0 else { return false }
        guard NSIntersectionRange(range, paragraph).length > 0 else { return false }
        return !NSEqualRanges(NSIntersectionRange(range, paragraph), range)
    }

    /// Internal so tests can ask directly whether the fast path applied,
    /// rather than inferring it from timings.
    static func reuse(
        cache: DecorationCache, for source: NSString
    ) -> [MarkdownDecoration]? {
        let old = cache.source
        let new = source
        guard old.length > 0, new.length > 0 else { return nil }

        let edit = SourceEdit.between(old, new)
        guard edit.changed.length > 0 || edit.previous.length > 0 else { return cache.decorations }

        // The region the edit sits in, in both texts: the blank-line-bounded
        // paragraphs it touches, and any paragraph it joins across a blank
        // line. A newline in the edit is allowed; Return, a pasted block and
        // a merged paragraph all stay inside their region.
        guard let newRegion = region(containing: edit.changed, in: new),
              let oldRegion = region(containing: edit.previous, in: old)
        else { return nil }

        // Outside the regions the two texts are the same text, since the edit
        // is inside both; the regions must therefore start at the same offset
        // and leave the same tail, or something else moved.
        guard oldRegion.location == newRegion.location,
              old.length - NSMaxRange(oldRegion) == new.length - NSMaxRange(newRegion)
        else { return nil }

        let newText = new.substring(with: newRegion)
        let oldText = old.substring(with: oldRegion)
        // Proven load-bearing: without it the differential check disagrees,
        // because a region that gains a fence changes how text outside it
        // parses.
        guard !containsMultilineMarker(newText), !containsMultilineMarker(oldText) else { return nil }

        // Nothing may reach into the region from outside it: a fence opened
        // above makes its text code, and a `$…$` can pair across a blank line.
        // Proven load-bearing: without it the differential check disagrees.
        for decoration in cache.decorations {
            guard !escapes(decoration, paragraph: oldRegion) else { return nil }
        }

        // Reparse the region alone. It begins at a line start, so the
        // line-anchored patterns see what they would have seen in place.
        let local = decorations(in: newText).map { $0.shifted(by: newRegion.location) }

        var result: [MarkdownDecoration] = []
        result.reserveCapacity(cache.decorations.count + local.count)
        for decoration in cache.decorations {
            let range = decoration.range
            if NSMaxRange(range) <= oldRegion.location {
                result.append(decoration)
            } else if range.location >= NSMaxRange(oldRegion) {
                result.append(decoration.shifted(by: edit.delta))
            }
            // Anything inside the region is replaced by the reparse.
        }
        // The region's own decorations stay together and in the order the
        // full scan produces them, which is what keeps a heading applied before
        // the bold inside it. Nothing outside the region overlaps them, so
        // where the group sits in the array does not matter.
        result.append(contentsOf: local)
        return result
    }

    /// The blank-line-bounded region containing `range`: the paragraph it
    /// sits in, or, when the range touches a blank line, the paragraphs on
    /// both sides of it, because an edit on a blank line joins them.
    static func region(containing range: NSRange, in text: NSString) -> NSRange? {
        guard range.location <= text.length else { return nil }
        var start = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let clampedEnd = min(NSMaxRange(range), text.length)
        var end = NSMaxRange(text.lineRange(for: NSRange(location: clampedEnd, length: 0)))

        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func lineBefore(_ offset: Int) -> NSRange? {
            offset > 0 ? text.lineRange(for: NSRange(location: offset - 1, length: 0)) : nil
        }
        func lineAfter(_ offset: Int) -> NSRange? {
            offset < text.length ? text.lineRange(for: NSRange(location: offset, length: 0)) : nil
        }

        // A blank line at either edge of the span separates two paragraphs
        // that the edit may be joining, so cross it and take the neighbour.
        if isBlank(text.lineRange(for: NSRange(location: start, length: 0))) {
            while let previous = lineBefore(start), isBlank(previous) { start = previous.location }
        }
        if end > start, isBlank(text.lineRange(for: NSRange(location: end - 1, length: 0))) {
            while let next = lineAfter(end), isBlank(next) { end = NSMaxRange(next) }
        }
        // Then out to the paragraph boundaries either side.
        while let previous = lineBefore(start), !isBlank(previous) { start = previous.location }
        while let next = lineAfter(end), !isBlank(next) { end = NSMaxRange(next) }
        return NSRange(location: start, length: end - start)
    }
}
