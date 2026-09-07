import Foundation
import Testing
@testable import HeftCore

/// Obsidian splits this into "Auto pair brackets" and "Auto pair Markdown
/// syntax", so these are two settings and two sets of rules: a bracket closes
/// with a different character, an emphasis marker closes with itself, and the
/// second kind needs rules the first does not.
@Suite("Bracket pairing")
struct BracketPairingTests {

    private func act(
        _ typed: String, _ document: String, caret: Int, length: Int = 0,
        brackets: Bool = true, markdown: Bool = true
    ) -> BracketPairing.Action {
        BracketPairing.action(
            typing: typed, in: document as NSString,
            selection: NSRange(location: caret, length: length),
            brackets: brackets, markdown: markdown
        )
    }

    @Test("An opening bracket closes itself")
    func closesBrackets() {
        #expect(act("(", "", caret: 0) == .insert("()", caretOffset: 1, selects: 0))
        #expect(act("[", "", caret: 0) == .insert("[]", caretOffset: 1, selects: 0))
        #expect(act("{", "", caret: 0) == .insert("{}", caretOffset: 1, selects: 0))
    }

    /// Two `[` in a row is how a wikilink starts, and falls out of ordinary
    /// pairing rather than needing a case of its own: the second `[` sees `]`
    /// ahead, which is not a word character, so it pairs again.
    @Test("Two brackets give a wikilink's four")
    func wikilinkShape() {
        #expect(act("[", "[]", caret: 1) == .insert("[]", caretOffset: 1, selects: 0))
    }

    @Test("Typing the closer steps over one already there")
    func skipsCloser() {
        #expect(act(")", "()", caret: 1) == .skip)
        #expect(act("]", "[]", caret: 1) == .skip)
    }

    /// Nothing to step over, so it is just a character.
    @Test("A closer with nothing ahead is typed normally")
    func closerWithoutPair() {
        #expect(act(")", "", caret: 0) == .none)
    }

    @Test("A selection is wrapped, not replaced")
    func wrapsSelection() {
        #expect(
            act("(", "hello", caret: 0, length: 5)
                == .insert("(hello)", caretOffset: 1, selects: 5)
        )
    }

    /// Typing `(` in front of a word is how wrapping it by hand starts, and a
    /// closer inserted there is one you have to delete first.
    @Test("Nothing is closed immediately before a word")
    func notBeforeAWord() {
        #expect(act("(", "word", caret: 0) == .none)
        #expect(act("[", "9lives", caret: 0) == .none)
        // A space or a closing bracket ahead is not a word, so it still pairs.
        #expect(act("(", " after", caret: 0) == .insert("()", caretOffset: 1, selects: 0))
    }

    @Test("An emphasis marker closes itself")
    func closesEmphasis() {
        #expect(act("*", "", caret: 0) == .insert("**", caretOffset: 1, selects: 0))
        #expect(act("_", "", caret: 0) == .insert("__", caretOffset: 1, selects: 0))
    }

    /// A code fence is three backticks typed in a row. Pairing them would make
    /// six, and Obsidian does not pair them either.
    @Test("A backtick is typed alone")
    func backtickIsNotPaired() {
        #expect(act("`", "", caret: 0) == .none)
        #expect(act("`", "``", caret: 2) == .none)
    }

    /// The second `*` of `**bold**` must open another pair. Stepping over the
    /// one ahead would leave `**` with nothing to close it.
    @Test("A second marker opens the bold pair rather than skipping")
    func boldOpensASecondPair() {
        #expect(act("*", "**", caret: 1) == .insert("**", caretOffset: 1, selects: 0))
    }

    /// ...but once there is a word between them, the marker closes.
    @Test("A marker after a word steps over its closer")
    func emphasisClosesAfterAWord() {
        #expect(act("*", "*hello*", caret: 6) == .skip)
    }

    /// `snake_case` must not pair the underscore in the middle of a word, and
    /// a marker opening emphasis always follows a space or a line start.
    @Test("A marker directly after a word is typed normally")
    func notAfterAWord() {
        #expect(act("_", "snake", caret: 5) == .none)
        #expect(act("*", "word", caret: 4) == .none)
        #expect(act("_", "snake ", caret: 6) == .insert("__", caretOffset: 1, selects: 0))
    }

    @Test("Each setting only governs its own characters")
    func settingsAreSeparate() {
        #expect(act("(", "", caret: 0, brackets: false) == .none)
        #expect(act("*", "", caret: 0, brackets: false) == .insert("**", caretOffset: 1, selects: 0))
        #expect(act("*", "", caret: 0, markdown: false) == .none)
        #expect(act("(", "", caret: 0, markdown: false) == .insert("()", caretOffset: 1, selects: 0))
    }

    /// Quotes belong to the curling substitution; two features must not fight
    /// over one keystroke.
    @Test("Quotes are left to smart typography")
    func leavesQuotesAlone() {
        #expect(act("\"", "", caret: 0) == .none)
        #expect(act("'", "", caret: 0) == .none)
    }

    /// Promoting `*word*` to `**word**` by hand is one marker typed at each
    /// end, and neither end may do anything clever. The front stepped over the
    /// marker already there, so the keystroke moved the caret and typed
    /// nothing at all.
    @Test("Bold is reached by typing a marker at each end")
    func promotingItalicToBold() {
        #expect(act("*", "*hello*", caret: 0) == .none)
        #expect(act("_", "_hello_", caret: 0) == .none)
        // Mid-line, where a space rather than the line start sits behind.
        #expect(act("*", "see *hello*", caret: 4) == .none)
        // And with the front done, the same keystroke at the back.
        #expect(act("*", "**hello*", caret: 8) == .none)
    }

    /// Stepping over is about the count, not about the neighbouring
    /// characters: a marker ahead is consumed only while the run that opened
    /// the emphasis is still owed one.
    @Test("A marker steps over only while a closer is still owed")
    func skippingFollowsTheCount() {
        // One owed and one ahead, so the marker finishes the pair.
        #expect(act("*", "*hello*", caret: 6) == .skip)
        #expect(act("*", "*a*", caret: 2) == .skip)
        #expect(act("*", "*hello *", caret: 7) == .skip)

        // Two owed and only one of them written: the second is typed rather
        // than consumed, which is the back half of promoting italic to bold.
        #expect(act("*", "**One live surface*", caret: 18) == .none)
        #expect(act("_", "__One live surface_", caret: 18) == .none)
        // ...and with both written, the run is paid off and steps over again.
        #expect(act("*", "**One live surface**", caret: 19) == .skip)

        // Nothing open at all, so the marker ahead belongs to something else.
        #expect(act("*", "see *hello*", caret: 4) == .none)
    }

    /// Promoting `*word*` to bold is typing one marker at each end. Pairing at
    /// the closing end wrote two and left three markers there.
    @Test("A marker after a closing marker is typed alone")
    func afterAClosingMarker() {
        #expect(act("*", "*hello*", caret: 7) == .none)
        #expect(act("_", "_hello_", caret: 7) == .none)
        // Mid-line, with the rest of the sentence still ahead.
        #expect(act("*", "*hello* there", caret: 7) == .none)
    }

    /// The marker ahead is what tells the two apart: inside `**|**` there is
    /// one, at the end of `*hello*|` there is not.
    @Test("The bold pair is still opened from inside its own")
    func boldStillPairsInsideItsPair() {
        #expect(act("*", "**", caret: 1) == .insert("**", caretOffset: 1, selects: 0))
    }

    @Test("Backspace between a pair takes both")
    func deletesBothHalves() {
        #expect(BracketPairing.deletesPair(in: "()", at: 1, brackets: true, markdown: true))
        #expect(BracketPairing.deletesPair(in: "**", at: 1, brackets: true, markdown: true))
        #expect(!BracketPairing.deletesPair(in: "ab", at: 1, brackets: true, markdown: true))
        #expect(!BracketPairing.deletesPair(in: "()", at: 1, brackets: false, markdown: false))
        // An empty pair still counts as one with a word in front of it.
        #expect(BracketPairing.deletesPair(in: "word **", at: 6, brackets: true, markdown: true))
    }

    /// Demoting `**bold**` to `*bold*` deletes one marker from each end. The
    /// caret between the two closing markers looks exactly like the caret in
    /// an empty pair, and taking both left `**bold`.
    @Test("Backspace inside a closing run takes one marker")
    func keepsTheOtherClosingMarker() {
        #expect(!BracketPairing.deletesPair(in: "**bold**", at: 7, brackets: true, markdown: true))
        #expect(!BracketPairing.deletesPair(in: "__bold__", at: 7, brackets: true, markdown: true))
        // The opening run is unaffected: `b` is not a marker, so it was never
        // a pair to begin with.
        #expect(!BracketPairing.deletesPair(in: "**bold**", at: 2, brackets: true, markdown: true))
    }
}
