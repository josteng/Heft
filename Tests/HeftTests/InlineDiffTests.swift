import HeftCore
import Testing

/// Word-level marking inside a changed line: which words moved, and when the
/// question is not worth asking.
@Suite("Inline diff")
struct InlineDiffTests {

    private func changed(_ spans: [InlineDiff.Span]) -> [String] {
        spans.filter(\.changed).map(\.text)
    }

    @Test("Only the word that moved is marked")
    func oneWord() throws {
        let pair = try #require(InlineDiff.between(
            "The caret sits above the line.",
            "The caret sits below the line."
        ))
        #expect(changed(pair.before) == ["above"])
        #expect(changed(pair.after) == ["below"])
    }

    @Test("A phrase is one span, not one per word")
    func phrasesMerge() throws {
        let pair = try #require(InlineDiff.between(
            "Agents never write to your notes.",
            "Agents never touch a single one of your notes."
        ))
        #expect(changed(pair.before) == ["write to"])
        // One mark, not five. Which side of it the spaces fall on is an
        // alignment detail; that it is a single run is the point.
        #expect(changed(pair.after).count == 1)
        #expect(changed(pair.after)[0].trimmingCharacters(in: .whitespaces)
            == "touch a single one of")
    }

    /// The invariant everything else rests on: marking a line must not alter
    /// it. A tokenizer that drops or duplicates a character would otherwise
    /// draw a line the note does not contain.
    @Test("Spans rebuild the line exactly")
    func spansRebuild() throws {
        let cases = [
            ("- **Bold** and `code`, plus a [link](x).", "- **Bold** and `code`, plus a [ref][x]."),
            ("  indented   with   gaps", "  indented with gaps"),
            ("Ünïcödé and emoji 🎉 stay whole", "Ünïcödé and emoji 🎉 stay put"),
            ("tabs\tand\tspaces", "tabs\tand  spaces"),
        ]
        for (before, after) in cases {
            let pair = try #require(InlineDiff.between(before, after), "\(before)")
            #expect(pair.before.map(\.text).joined() == before)
            #expect(pair.after.map(\.text).joined() == after)
        }
    }

    /// A word edited in place is marked letter by letter, because the reader
    /// already knows which word it is and wants to know which letter.
    @Test("A typo is marked at the letter that changed")
    func typoMarksTheLetter() throws {
        let pair = try #require(InlineDiff.between(
            "has a second window", "has a second wiNdow"
        ))
        #expect(changed(pair.before) == ["n"])
        #expect(changed(pair.after) == ["N"])
    }

    @Test("A plural is marked at its ending")
    func pluralMarksTheEnding() throws {
        let pair = try #require(InlineDiff.between("the colour", "the colours"))
        #expect(changed(pair.before).isEmpty)
        #expect(changed(pair.after) == ["s"])
    }

    /// The other half of the rule. Two different words that happen to share
    /// letters in order must not be stitched together letter by letter: that
    /// paints a stripe through both and says nothing.
    @Test("A different word is marked whole, not letter by letter")
    func differentWordStaysWhole() throws {
        let pair = try #require(InlineDiff.between(
            "opening a folder takes the highlight", "opening a folder keeps the highlight"
        ))
        #expect(changed(pair.before) == ["takes"])
        #expect(changed(pair.after) == ["keeps"])
    }

    /// Two whole words that both changed are one mark, not two with a gap:
    /// the space between them is part of the same edit.
    @Test("A changed phrase is bridged across its spaces")
    func phrasesBridge() throws {
        let pair = try #require(InlineDiff.between(
            "opening a folder takes off the highlight",
            "opening a folder keeps on the highlight"
        ))
        #expect(changed(pair.before) == ["takes off"])
        #expect(changed(pair.after) == ["keeps on"])
    }

    /// The limit of that bridging. A mark may not start inside a word: when
    /// one side of the space is only a letter, the two are separate edits and
    /// joining them would draw a highlight beginning mid-word.
    @Test("A letter change is not bridged into the next word")
    func lettersDoNotBridge() throws {
        let pair = try #require(InlineDiff.between("the timing is right", "the timings are right"))
        #expect(changed(pair.before) == ["is"])
        #expect(changed(pair.after) == ["s", "are"])
    }

    @Test("Punctuation is its own token")
    func punctuation() throws {
        let pair = try #require(InlineDiff.between("no lock-in", "no lock-in, ever"))
        #expect(changed(pair.before).isEmpty)
        #expect(changed(pair.after).joined() == ", ever")
    }

    @Test("Unrelated lines are not marked up at all")
    func unrelatedLinesRefuse() {
        #expect(InlineDiff.between(
            "Caveats: macOS 26 on Apple Silicon, early, and heavily vibe coded.",
            "GitHub link in the comments."
        ) == nil)
    }

    @Test("An identical line has nothing to say")
    func identical() {
        #expect(InlineDiff.between("same", "same") == nil)
    }

    @Test("An empty side is not compared")
    func emptySide() {
        #expect(InlineDiff.between("", "something") == nil)
        #expect(InlineDiff.between("something", "") == nil)
    }

    /// Shared spaces must not make two different sentences look related, which
    /// is what counting whitespace towards the similarity would do.
    @Test("Whitespace does not count towards similarity")
    func whitespaceIsNotSimilarity() {
        #expect(InlineDiff.between("aaa bbb ccc ddd", "eee fff ggg hhh") == nil)
    }

    @Test("Lines are paired by position, and the surplus is left alone")
    func pairing() {
        let result = InlineDiff.spans(
            removed: ["the caret sits above", "second line here"],
            added: ["the caret sits below", "second line here too", "a third line"]
        )
        #expect(result.removed.count == 2)
        #expect(result.added.count == 3)
        #expect(result.removed[0] != nil)
        #expect(result.added[0] != nil)
        // Nothing to pair the third added line with, so it stays unmarked
        // rather than being compared with a line it has no relation to.
        #expect(result.added[2] == nil)
    }

    /// The comparison trims the shared head and tail before doing the
    /// quadratic part. These prove the trim does not lose the edit it was
    /// meant to make affordable to find.
    @Test("An edit at the far end of a long line is still found")
    func longLineEndEdit() throws {
        let body = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        let pair = try #require(InlineDiff.between(body + "first", body + "second"))
        #expect(changed(pair.before) == ["first"])
        #expect(changed(pair.after) == ["second"])
        #expect(pair.before.map(\.text).joined() == body + "first")
    }

    @Test("An edit in the middle of a long line is still found")
    func longLineMiddleEdit() throws {
        let half = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        let pair = try #require(InlineDiff.between(
            half + "pivot " + half, half + "pivots " + half
        ))
        #expect(changed(pair.before).isEmpty)
        #expect(changed(pair.after) == ["s"])
    }

    /// Past the limit the line was rewritten rather than edited. Refusing
    /// before the table is built is what stops a pasted blob from freezing
    /// the review sheet.
    @Test("A line rewritten past the limit is refused")
    func rewrittenLongLineRefused() {
        let before = (0..<600).map { "word\($0)" }.joined(separator: " ")
        let after = (0..<600).map { $0 % 2 == 0 ? "word\($0)" : "other\($0)" }
            .joined(separator: " ")
        #expect(InlineDiff.between(before, after) == nil)
    }

    @Test("A pure insertion marks nothing")
    func insertionMarksNothing() {
        let result = InlineDiff.spans(removed: [], added: ["a new line", "and another"])
        #expect(result.added.allSatisfy { $0 == nil })
    }
}
