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
        #expect(act("`", "", caret: 0) == .insert("``", caretOffset: 1, selects: 0))
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

    @Test("Backspace between a pair takes both")
    func deletesBothHalves() {
        #expect(BracketPairing.deletesPair(in: "()", at: 1, brackets: true, markdown: true))
        #expect(BracketPairing.deletesPair(in: "**", at: 1, brackets: true, markdown: true))
        #expect(!BracketPairing.deletesPair(in: "ab", at: 1, brackets: true, markdown: true))
        #expect(!BracketPairing.deletesPair(in: "()", at: 1, brackets: false, markdown: false))
    }
}
