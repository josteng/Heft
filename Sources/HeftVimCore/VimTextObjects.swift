import Foundation

// Sentence, paragraph and tag objects, plus the motions that share their
// boundary logic. They live apart from `VimText` because all three are
// *span* problems rather than character problems: each one first cuts the
// document into an alternating run of content and separator, then answers
// "which run am I in" — which is also exactly what a count has to walk.

extension VimText {
    /// One run of the alternating content/separator sequence a text object is
    /// carved out of: a sentence and the whitespace after it, a paragraph and
    /// the blank lines after it.
    struct Span {
        var range: NSRange
        var isSeparator: Bool
    }

    // MARK: - Sentences

    func isSentenceTerminator(at location: Int) -> Bool {
        guard location >= 0, location < length else { return false }
        let c = value.character(at: location)
        return c == 46 || c == 33 || c == 63 // . ! ?
    }

    private func isSentenceCloser(at location: Int) -> Bool {
        guard location >= 0, location < length else { return false }
        let c = value.character(at: location)
        return c == 41 || c == 93 || c == 34 || c == 39 // ) ] " '
    }

    /// The sentences of the paragraph around `location`, as content spans
    /// separated by the whitespace between them.
    ///
    /// Vim ends a sentence at `.`, `!` or `?` followed by any number of `)`,
    /// `]`, `"` or `'` and then a space, tab or line break. A blank line ends
    /// one too, which is why the scan never leaves the enclosing paragraph —
    /// but an ordinary line break inside one does not, so a sentence may run
    /// across several lines.
    func sentenceSpans(around location: Int) -> [Span] {
        guard length > 0 else { return [] }
        let bounds = paragraphBounds(at: clampedInsertion(location))
        guard bounds.length > 0 else {
            // A blank line is a sentence of its own, and it is its line break.
            let terminator = NSMaxRange(lineRange(at: bounds.location))
            return [Span(
                range: NSRange(location: bounds.location, length: terminator - bounds.location),
                isSeparator: false
            )]
        }
        var spans: [Span] = []
        var start = bounds.location
        var p = bounds.location
        while p < NSMaxRange(bounds) {
            guard isSentenceTerminator(at: p) else {
                p = nextCharacter(from: p)
                continue
            }
            var after = nextCharacter(from: p)
            while after < NSMaxRange(bounds), isSentenceCloser(at: after) {
                after = nextCharacter(from: after)
            }
            guard after >= NSMaxRange(bounds) || whitespace(at: after) else {
                p = nextCharacter(from: p)
                continue
            }
            spans.append(Span(range: NSRange(location: start, length: after - start), isSeparator: false))
            var gap = after
            while gap < NSMaxRange(bounds), whitespace(at: gap) { gap = nextCharacter(from: gap) }
            if gap > after {
                spans.append(Span(range: NSRange(location: after, length: gap - after), isSeparator: true))
            }
            start = gap
            p = gap
        }
        if start < NSMaxRange(bounds) {
            spans.append(Span(
                range: NSRange(location: start, length: NSMaxRange(bounds) - start),
                isSeparator: false
            ))
        }
        return spans.map(absorbingLineBreak)
    }

    /// A sentence that fills whole lines takes their final line break with it,
    /// so `dis` on a one-sentence line removes the line rather than hollowing
    /// it out. Vim stops short of the buffer's very last break, which belongs
    /// to the file rather than to any line.
    private func absorbingLineBreak(_ span: Span) -> Span {
        guard !span.isSeparator, span.range.length > 0 else { return span }
        let end = NSMaxRange(span.range)
        guard span.range.location == lineRange(at: span.range.location).location,
              end < length, isNewline(at: end),
              end == NSMaxRange(lineContentRange(at: previousCharacter(from: end))),
              nextCharacter(from: end) < length
        else { return span }
        return Span(
            range: NSRange(
                location: span.range.location,
                length: nextCharacter(from: end) - span.range.location
            ),
            isSeparator: false
        )
    }

    /// The paragraph body around `location`, without its trailing line break.
    /// An empty line is its own paragraph, so `is` on one selects just it.
    private func paragraphBounds(at location: Int) -> NSRange {
        let line = lineRange(at: location)
        guard lineContentRange(at: line.location).length > 0 else {
            return lineContentRange(at: line.location)
        }
        var start = line.location
        while start > 0 {
            let previous = lineRange(at: start - 1)
            guard lineContentRange(at: previous.location).length > 0 else { break }
            start = previous.location
        }
        var end = line
        while NSMaxRange(end) < length {
            let next = lineRange(at: NSMaxRange(end))
            guard lineContentRange(at: next.location).length > 0 else { break }
            end = next
        }
        return NSRange(
            location: start,
            length: NSMaxRange(lineContentRange(at: end.location)) - start
        )
    }

    /// `is` is one sentence; `as` adds the run of spaces after it, or the run
    /// before it when the sentence ends its line. Only *horizontal* whitespace
    /// counts — a sentence never reaches across a line break for its padding,
    /// which is what separates this from `wordObject` and `paragraphObject`.
    func sentenceObject(at location: Int, around: Bool, count: Int) -> NSRange? {
        let spans = sentenceSpans(around: location)
        guard !spans.isEmpty else { return nil }
        let cursor = clampedInsertion(location)
        guard let index = spans.firstIndex(where: { NSLocationInRange(cursor, $0.range) })
            ?? spans.indices.last(where: { NSMaxRange(spans[$0].range) <= cursor })
        else { return nil }

        let start = spans[index].range.location
        var last = index
        // With the caret in the gap, an `as` unit is *gap then sentence*, so
        // the gap alone does not complete one — the same grouping `ap` uses.
        let startsOnSeparator = around && spans[index].isSeparator
        var consumed = startsOnSeparator ? 0 : 1
        while consumed < max(1, count), last + 1 < spans.count {
            last += 1
            if around, spans[last].isSeparator { continue }
            consumed += 1
        }
        // Unlike `ip`, a counted sentence object stops at the paragraph rather
        // than failing: Vim's own `2is` reaches into the blank lines beyond it,
        // and following it there would cost the exactness `is`/`as` have at
        // count 1 for a form almost nobody types.
        var end = NSMaxRange(spans[last].range)
        guard around else { return NSRange(location: start, length: end - start) }

        if startsOnSeparator { return NSRange(location: start, length: end - start) }

        // A span that already swallowed its line break has no padding left to
        // take, and reaching for the next line's would cross a boundary Vim
        // treats as absolute.
        if isNewline(at: previousCharacter(from: end)) {
            return NSRange(location: start, length: end - start)
        }
        if last + 1 < spans.count, spans[last + 1].isSeparator,
           !isNewline(at: spans[last + 1].range.location) {
            end = NSMaxRange(spans[last + 1].range)
            return NSRange(location: start, length: end - start)
        }
        if index > 0, spans[index - 1].isSeparator,
           !isNewline(at: spans[index - 1].range.location) {
            let leading = spans[index - 1].range.location
            return NSRange(location: leading, length: end - leading)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Start of the `count`-th sentence forward or backward. Exclusive, like
    /// Vim's own `(` and `)`.
    ///
    /// Unlike the sentence *object*, these motions cross paragraphs freely, so
    /// they work from the document's whole list of sentence starts rather than
    /// one paragraph's spans.
    func sentence(from location: Int, forward: Bool, count: Int) -> Int {
        let cursor = clampedCursor(location)
        let starts = allSentenceStarts()
        guard !starts.isEmpty else { return cursor }
        var p = cursor
        for _ in 0..<max(1, count) {
            if forward {
                guard let next = starts.first(where: { $0 > p }) else {
                    return max(0, length - 1)
                }
                p = next
            } else {
                // A counted backward motion that cannot complete is a failed
                // motion: Vim leaves the caret rather than going as far as it
                // can, so `2(` in the first sentence does nothing.
                guard let previous = starts.last(where: { $0 < p }) else { return cursor }
                p = previous
            }
        }
        return p
    }

    /// Every sentence start in the document. A blank line is one of its own,
    /// which is how `)` stops between paragraphs rather than skipping them.
    private func allSentenceStarts() -> [Int] {
        var starts: [Int] = []
        var lineStart = 0
        while lineStart < length {
            let line = lineRange(at: lineStart)
            if lineContentRange(at: lineStart).length == 0 {
                starts.append(lineStart)
                guard NSMaxRange(line) > lineStart else { break }
                lineStart = NSMaxRange(line)
                continue
            }
            let spans = sentenceSpans(around: lineStart)
            starts.append(contentsOf: spans.filter { !$0.isSeparator }.map(\.range.location))
            // Skip the whole paragraph: its spans were just collected.
            var probe = lineStart
            while probe < length, lineContentRange(at: probe).length > 0 {
                let next = NSMaxRange(lineRange(at: probe))
                guard next > probe else { break }
                probe = next
            }
            guard probe > lineStart else { break }
            lineStart = probe
        }
        return starts
    }

    // MARK: - Paragraphs

    /// Alternating runs of non-blank and blank lines, whole-line ranges.
    func paragraphSpans() -> [Span] {
        guard length > 0 else { return [] }
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < length {
            let blank = lineContentRange(at: lineStart).length == 0
            let runStart = lineStart
            var runEnd = lineStart
            while runEnd < length, (lineContentRange(at: runEnd).length == 0) == blank {
                let line = lineRange(at: runEnd)
                runEnd = NSMaxRange(line)
                if runEnd <= line.location { break }
            }
            spans.append(Span(
                range: NSRange(location: runStart, length: runEnd - runStart),
                isSeparator: blank
            ))
            guard runEnd > lineStart else { break }
            lineStart = runEnd
        }
        return spans
    }

    func paragraphObject(at location: Int, around: Bool, count: Int) -> NSRange? {
        objectFromSpans(paragraphSpans(), at: location, around: around, count: count)
    }

    // MARK: - Shared span walk

    /// `i` takes `count` runs of the kind the cursor is in; `a` takes each of
    /// those plus the separator behind it, falling back to the separator in
    /// front when there is none — the rule `aw`, `as` and `ap` all share.
    private func objectFromSpans(
        _ spans: [Span],
        at location: Int,
        around: Bool,
        count: Int
    ) -> NSRange? {
        guard !spans.isEmpty else { return nil }
        let cursor = clampedInsertion(location)
        guard var index = spans.firstIndex(where: { NSLocationInRange(cursor, $0.range) })
            ?? spans.indices.last(where: { $0 < spans.count && NSMaxRange(spans[$0].range) <= cursor })
        else { return nil }
        if index >= spans.count { index = spans.count - 1 }

        let start = spans[index].range.location
        var end = NSMaxRange(spans[index].range)
        // Starting inside the blank run, an `ap` unit is *blank lines then a
        // paragraph* rather than *paragraph then blank lines*, so the run the
        // caret is in does not complete a unit on its own.
        let startsOnSeparator = around && spans[index].isSeparator
        var consumed = startsOnSeparator ? 0 : 1
        var last = index
        // `2ip` counts blank runs as units of their own; `2ap` counts a
        // paragraph and the blank lines beside it as one.
        while consumed < max(1, count), last + 1 < spans.count {
            last += 1
            end = NSMaxRange(spans[last].range)
            if around, spans[last].isSeparator { continue }
            consumed += 1
        }
        // Vim refuses a count that runs off the end rather than doing less
        // than it was asked, so too large a count leaves the buffer alone.
        guard consumed >= max(1, count) else { return nil }
        guard around else { return NSRange(location: start, length: end - start) }
        if startsOnSeparator { return NSRange(location: start, length: end - start) }

        if last + 1 < spans.count, spans[last + 1].isSeparator {
            return NSRange(
                location: start,
                length: NSMaxRange(spans[last + 1].range) - start
            )
        }
        if index > 0, spans[index - 1].isSeparator {
            let leading = spans[index - 1].range.location
            return NSRange(location: leading, length: end - leading)
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Tag blocks

    private struct Tag {
        var name: String
        var range: NSRange
        var isClosing: Bool
        var isSelfClosing: Bool
    }

    /// The `count`-th enclosing `<tag>…</tag>` pair. `around` includes both
    /// tags; otherwise only what sits between them.
    func tagObject(at location: Int, around: Bool, count: Int) -> NSRange? {
        let cursor = clampedInsertion(location)
        var stack: [Tag] = []
        var enclosing: [(open: Tag, close: Tag)] = []
        for tag in tags() {
            if tag.isSelfClosing { continue }
            if tag.isClosing {
                guard let openIndex = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
                let open = stack[openIndex]
                stack.removeSubrange(openIndex...)
                if open.range.location <= cursor, cursor < NSMaxRange(tag.range) {
                    enclosing.append((open, tag))
                }
            } else {
                stack.append(tag)
            }
        }
        // `tags()` closes innermost first, so the list is already inside-out.
        // As with `2i(`, a count past the outermost pair fails rather than
        // settling for the nearest one.
        let index = max(1, count) - 1
        guard index < enclosing.count else { return nil }
        let pair = enclosing[index]
        if around {
            return NSRange(
                location: pair.open.range.location,
                length: NSMaxRange(pair.close.range) - pair.open.range.location
            )
        }
        let start = NSMaxRange(pair.open.range)
        let end = pair.close.range.location
        // Vim falls back to `at` when the pair has nothing between it, so that
        // `cit` on `<b></b>` still gives you somewhere to type.
        guard end > start else {
            return NSRange(
                location: pair.open.range.location,
                length: NSMaxRange(pair.close.range) - pair.open.range.location
            )
        }
        return NSRange(location: start, length: end - start)
    }

    private func tags() -> [Tag] {
        var result: [Tag] = []
        var p = 0
        while p < length {
            guard value.character(at: p) == 60 else { p = nextCharacter(from: p); continue } // <
            var q = nextCharacter(from: p)
            let isClosing = q < length && value.character(at: q) == 47 // /
            if isClosing { q = nextCharacter(from: q) }
            let nameStart = q
            while q < length, isTagNameCharacter(at: q) { q = nextCharacter(from: q) }
            guard q > nameStart else { p = nextCharacter(from: p); continue }
            let name = value.substring(with: NSRange(location: nameStart, length: q - nameStart))
            // Skip the attribute list, honouring quotes so that `a="b>c"` does
            // not end the tag early.
            var quote: unichar?
            while q < length {
                let c = value.character(at: q)
                if let open = quote {
                    if c == open { quote = nil }
                } else if c == 34 || c == 39 {
                    quote = c
                } else if c == 62 { // >
                    break
                }
                q = nextCharacter(from: q)
            }
            guard q < length, value.character(at: q) == 62 else { p = nextCharacter(from: p); continue }
            let previous = previousCharacter(from: q)
            let selfClosing = previous > nameStart && value.character(at: previous) == 47
            result.append(Tag(
                name: name,
                range: NSRange(location: p, length: nextCharacter(from: q) - p),
                isClosing: isClosing,
                isSelfClosing: selfClosing
            ))
            p = nextCharacter(from: q)
        }
        return result
    }

    private func isTagNameCharacter(at location: Int) -> Bool {
        guard location < length else { return false }
        let c = value.character(at: location)
        return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
            || c == 45 || c == 95 || c == 58 // - _ :
    }

    // MARK: - Backward word ends

    /// `ge` / `gE`. Defined as "the nearest word end before the cursor", which
    /// is cheaper and less error-prone than mirroring `wordEnd`'s state walk.
    /// Nil when there is no earlier word end, so an operator aborts instead of
    /// falling back on the start of the document and eating a character.
    func wordEndBackward(from location: Int, count: Int, bigWord: Bool = false) -> Int? {
        guard length > 0 else { return nil }
        var p = clampedCursor(location)
        for step in 0..<max(1, count) {
            var q = p
            var found = false
            while q > 0 {
                q = previousCharacter(from: q)
                if isWordEnd(at: q, bigWord: bigWord) { found = true; break }
            }
            // Running out lands on the first character, the way every backward
            // motion in Vim does. Only a caret already sitting there has
            // nowhere left to go, and that is a failed motion.
            guard found else { return (step == 0 && p == 0) ? nil : 0 }
            p = q
        }
        return p
    }

    private func isWordEnd(at location: Int, bigWord: Bool) -> Bool {
        guard location >= 0, location < length, !whitespace(at: location) else { return false }
        let next = nextCharacter(from: location)
        guard next < length else { return true }
        if whitespace(at: next) { return true }
        return isKeyword(at: next, bigWord: bigWord) != isKeyword(at: location, bigWord: bigWord)
    }

    // MARK: - Counted word objects

    /// `2iw` reaches over a word and the space after it, because `iw` treats
    /// a whitespace run as a unit of its own.
    func wordObject(at location: Int, bigWord: Bool, around: Bool, count: Int) -> NSRange? {
        guard count > 1 else { return wordObject(at: location, bigWord: bigWord, around: around) }
        guard !around else { return countedAroundWord(at: location, bigWord: bigWord, count: count) }
        guard var range = wordObject(at: location, bigWord: bigWord, around: false) else { return nil }
        var units = 1
        while units < count {
            let next = NSMaxRange(range)
            guard next < length else { break }
            if isNewline(at: next) {
                // A single line break is absorbed rather than counted: `2iw`
                // at the end of a line takes the word after it, not the break.
                // A blank line is whitespace of its own, and does count.
                let blankLine = crossesBlankLine(from: next)
                var skip = next
                while skip < length, whitespace(at: skip) { skip = nextCharacter(from: skip) }
                guard skip < length else { break }
                range = NSRange(location: range.location, length: skip - range.location)
                if blankLine { units += 1 }
                continue
            }
            guard let more = wordObject(at: next, bigWord: bigWord, around: false),
                  NSMaxRange(more) > next
            else { break }
            range = NSRange(location: range.location, length: NSMaxRange(more) - range.location)
            units += 1
        }
        // Like `2i(`, a count that runs off the end is a failed object rather
        // than a smaller one.
        guard units >= count else { return nil }
        return range
    }

    /// Whether the whitespace run starting at `location` passes through an
    /// empty line, rather than merely ending one line and starting the next.
    private func crossesBlankLine(from location: Int) -> Bool {
        var newlines = 0
        var p = location
        while p < length, whitespace(at: p) {
            if isNewline(at: p) {
                newlines += 1
                if newlines > 1 { return true }
            }
            p = nextCharacter(from: p)
        }
        return false
    }

    /// `2aw` and friends. Each unit is *whitespace then word* when it begins on
    /// a space and *word then whitespace* when it does not, which is why the
    /// two forms cannot be built by chaining single `aw` objects: `2aw` on the
    /// space in `alpha (beta [` takes the trailing space too, while the same
    /// command on the space in `one two three` does not, and both fall out of
    /// this one rule.
    ///
    /// The leading-whitespace fallback is then decided once, for the whole run:
    /// it applies only when no unit found whitespace behind it.
    private func countedAroundWord(at location: Int, bigWord: Bool, count: Int) -> NSRange? {
        let start = clampedCursor(location)
        var probe = start
        var end = start
        var sawTrailing = false
        var completed = 0
        for _ in 0..<count {
            // A single line break is just where one line stops: step over it
            // and take the next word with its own trailing space. A blank
            // line is whitespace in its own right, so the unit begins there
            // and stops at the end of the word, taking nothing behind it.
            if probe < length, isNewline(at: probe), !crossesBlankLine(from: probe) {
                while probe < length, isNewline(at: probe) { probe = nextCharacter(from: probe) }
            }
            guard probe < length else { break }
            if whitespace(at: probe) {
                while probe < length, whitespace(at: probe) { probe = nextCharacter(from: probe) }
                guard probe < length,
                      let word = wordObject(at: probe, bigWord: bigWord, around: false),
                      NSMaxRange(word) > probe
                else { break }
                probe = NSMaxRange(word)
                sawTrailing = false
            } else {
                guard let word = wordObject(at: probe, bigWord: bigWord, around: false),
                      NSMaxRange(word) > probe
                else { break }
                var after = NSMaxRange(word)
                let contentEnd = after
                while after < length, whitespace(at: after), !isNewline(at: after) {
                    after = nextCharacter(from: after)
                }
                sawTrailing = after > contentEnd
                probe = after
            }
            end = probe
            completed += 1
        }
        guard end > start, completed >= count else { return nil }

        // A caret in the middle of a word takes the whole word with it.
        var begin = start
        if !whitespace(at: start),
           let first = wordObject(at: start, bigWord: bigWord, around: false) {
            begin = first.location
        }
        if !sawTrailing {
            while begin > 0 {
                let previous = previousCharacter(from: begin)
                if !whitespace(at: previous) || isNewline(at: previous) { break }
                begin = previous
            }
        }
        return NSRange(location: begin, length: end - begin)
    }

    // MARK: - Counted delimiter objects

    /// `2i(` reaches the second enclosing pair. Vim gives up rather than
    /// settling for a closer one, so too large a count is a failed object and
    /// leaves the buffer alone — which is why this counts levels up front
    /// instead of walking outwards and keeping the best it found.
    func delimitedObject(
        at location: Int,
        opening: Character,
        closing: Character,
        around: Bool,
        count: Int
    ) -> NSRange? {
        guard count > 1, opening != closing else {
            return delimitedObject(at: location, opening: opening, closing: closing, around: around)
        }
        let pairs = enclosingPairs(at: location, opening: opening, closing: closing)
        guard count <= pairs.count else { return nil }
        return delimitedRange(
            pairs[count - 1], at: location, opening: opening, closing: closing, around: around
        )
    }

    /// Every `opening`/`closing` pair that contains `location`, innermost first.
    private func enclosingPairs(
        at location: Int,
        opening: Character,
        closing: Character
    ) -> [(left: Int, right: Int)] {
        let openingValue = (String(opening) as NSString).character(at: 0)
        let closingValue = (String(closing) as NSString).character(at: 0)
        var stack: [Int] = []
        var found: [(left: Int, right: Int)] = []
        var p = 0
        while p < length {
            let character = value.character(at: p)
            if character == openingValue {
                stack.append(p)
            } else if character == closingValue, let left = stack.popLast() {
                if left <= location, location <= p { found.append((left, p)) }
            }
            p = nextCharacter(from: p)
        }
        // Closings arrive innermost-first, which is the order a count wants.
        return found
    }
}
