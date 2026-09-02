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
    static let multilineMarkers = ["```", "~~~", "---", "$$", "|", "<!--", "-->"]

    /// Whether a decoration can cover more than the line it starts on. These
    /// are the ones whose extent depends on text far from the edit.
    static func spansLines(_ style: MarkdownDecoration.Style) -> Bool {
        switch style {
        case .frontmatter, .codeBlock, .comment, .table, .blockMath, .agentGuideBoundary:
            true
        case .wikiLink(let link):
            link.isEmbed
        default:
            false
        }
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

        // A newline anywhere in the change moves the line structure the whole
        // parse is built on. Defence in depth: the blank-line test in
        // `paragraph(containing:)` already rejects every case the differential
        // check can construct, so removing this alone breaks nothing today.
        // It is kept because that is a property of `paragraph`, not of this
        // guard, and the two are free to drift.
        guard !new.substring(with: edit.changed).contains("\n"),
              !old.substring(with: edit.previous).contains("\n")
        else { return nil }

        // The paragraph the edit sits in, in both texts. Blank lines bound it,
        // which is also where inline spans stop.
        guard let newParagraph = paragraph(containing: edit.changed, in: new),
              let oldParagraph = paragraph(containing: edit.previous, in: old)
        else { return nil }

        // The edit must be strictly inside, and the paragraph must have grown by
        // exactly the edit, so the two paragraphs are the same one rather than
        // one that merged with its neighbour. Also defence in depth, for the
        // same reason as above.
        guard edit.changed.location > newParagraph.location,
              NSMaxRange(edit.changed) < NSMaxRange(newParagraph),
              edit.previous.location > oldParagraph.location,
              NSMaxRange(edit.previous) < NSMaxRange(oldParagraph),
              newParagraph.length - oldParagraph.length == edit.delta
        else { return nil }

        let newText = new.substring(with: newParagraph)
        let oldText = old.substring(with: oldParagraph)
        // Proven load-bearing: without it the differential check disagrees on
        // 16 edits, because a paragraph that gains a fence or a pipe changes
        // how text outside it parses.
        for marker in multilineMarkers {
            guard !newText.contains(marker), !oldText.contains(marker) else { return nil }
        }

        // Nothing multi-line may reach into the paragraph: a fence opened above
        // it makes its text code, and the fence's own decoration would have to
        // grow rather than the paragraph's change. Proven load-bearing: without
        // it the differential check disagrees on 70 edits.
        for decoration in cache.decorations where spansLines(decoration.style) {
            guard NSIntersectionRange(decoration.range, oldParagraph).length == 0 else {
                return nil
            }
        }

        // Reparse the paragraph alone. It begins at a line start, so the
        // line-anchored patterns see what they would have seen in place.
        let local = decorations(in: newText).map { $0.shifted(by: newParagraph.location) }

        var result: [MarkdownDecoration] = []
        result.reserveCapacity(cache.decorations.count + local.count)
        for decoration in cache.decorations {
            let range = decoration.range
            if NSMaxRange(range) <= oldParagraph.location {
                result.append(decoration)
            } else if range.location >= NSMaxRange(oldParagraph) {
                result.append(decoration.shifted(by: edit.delta))
            }
            // Anything inside the paragraph is replaced by the reparse.
        }
        // The paragraph's own decorations stay together and in the order the
        // full scan produces them, which is what keeps a heading applied before
        // the bold inside it. Nothing outside the paragraph overlaps them, so
        // where the group sits in the array does not matter.
        result.append(contentsOf: local)
        return result
    }

    /// The blank-line-bounded paragraph containing `range`, or nil when the
    /// range touches a blank line and so has no single one.
    static func paragraph(containing range: NSRange, in text: NSString) -> NSRange? {
        guard range.location <= text.length else { return nil }
        var start = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let clampedEnd = min(NSMaxRange(range), text.length)
        var end = NSMaxRange(text.lineRange(for: NSRange(location: clampedEnd, length: 0)))

        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // The edit's own lines must not be blank, or "the paragraph" is
        // ambiguous and the guards below cannot bound it.
        guard !isBlank(NSRange(location: start, length: end - start)) else { return nil }

        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous) { break }
            start = previous.location
        }
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }
}
