import Foundation

/// Closing a bracket, or an emphasis marker, as the opening one is typed.
///
/// Pure, and deliberately not part of `SmartTypography`: a substitution is a
/// function of (document, caret) run *after* a character has landed, which
/// cannot put the caret back between two characters it just wrote. Pairing has
/// to answer before the insertion happens, so it is its own decision and the
/// text view asks it inside `insertText`.
///
/// Obsidian splits this in two, and so does this: "Auto pair brackets" and
/// "Auto pair Markdown syntax", stored in `.obsidian/app.json` as
/// `autoPairBrackets` and `autoPairMarkdown`. Neither's character set is
/// documented anywhere, so these are the ones that earn their place.
///
/// Quotes are left out on purpose. `"` and `'` are already claimed by the
/// quote-curling substitution, and pairing a character that is about to be
/// replaced by a curly one is two features fighting over one keystroke.
public enum BracketPairing {

    /// Openers that close with something else.
    public static let brackets: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// Markers that close with themselves: `*` and `_`, the emphasis pair.
    /// Not the backtick, which Obsidian leaves alone too: pairing it turns
    /// the three of a code fence into six, with the caret stranded in the
    /// middle. `==` and `~~` are two characters and so are not a single
    /// keystroke's decision.
    public static let symmetric: Set<Character> = ["*", "_"]

    public enum Action: Equatable {
        /// Insert this text, then put the caret `caretOffset` into it. When
        /// `selects` is non-zero, that many characters from the caret are
        /// selected instead, which is what wrapping a selection leaves behind.
        case insert(String, caretOffset: Int, selects: Int)
        /// The closer is already there: step over it rather than writing a
        /// second one.
        case skip
        /// Type the character normally.
        case none
    }

    /// What typing `character` should do.
    public static func action(
        typing character: String,
        in text: NSString,
        selection: NSRange,
        brackets bracketsEnabled: Bool,
        markdown markdownEnabled: Bool
    ) -> Action {
        guard character.count == 1, let typed = character.first else { return .none }

        let closer: Character?
        if bracketsEnabled, let paired = brackets[typed] {
            closer = paired
        } else if markdownEnabled, symmetric.contains(typed) {
            closer = typed
        } else {
            closer = nil
        }

        let next = characterAfter(selection, in: text)

        // Typing a closer that is already sitting under the caret walks past
        // it, so finishing a pair by hand does not leave `())`. Checked before
        // anything else, including for the symmetric markers, where the same
        // key is both ends.
        let closers = Set(brackets.values)
        let isCloser = (bracketsEnabled && closers.contains(typed))
            || (markdownEnabled && symmetric.contains(typed))
        if isCloser, selection.length == 0, next == typed {
            // A bracket's ends are different characters, so one ahead is
            // always a closer and stepping over it is right.
            guard symmetric.contains(typed) else { return .skip }
            return markerMeetingItsOwnKind(typed, in: text, at: selection.location)
        }

        guard let closer else { return .none }

        // A selection is wrapped rather than replaced, which is the whole
        // reason to reach for a bracket with text already chosen.
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            return .insert("\(typed)\(inner)\(closer)", caretOffset: 1, selects: inner.count)
        }

        // Not immediately before a word: typing `(` in front of existing text
        // is how you start wrapping it by hand, and auto-closing there leaves
        // a `)` to delete before you can carry on.
        if let next, next.isLetter || next.isNumber { return .none }

        // A marker with nothing of its own kind ahead. One of its kind under
        // the caret is settled above and never reaches here.
        if symmetric.contains(typed) {
            let previous = characterBefore(selection, in: text)
            // Not immediately after a word, or `snake_case` pairs the
            // underscore in the middle of it. A marker opening emphasis always
            // follows a space or a line start.
            if let previous, previous.isLetter || previous.isNumber { return .none }
            // Directly after a marker: promoting `*word*` to bold types one at
            // each end, and pairing gave the end three.
            if previous == typed { return .none }
        }

        return .insert("\(typed)\(closer)", caretOffset: 1, selects: 0)
    }

    /// What typing marker `m` does when one just like it sits under the caret.
    ///
    /// This is the whole difficulty with `*` and `_`, and it cannot be settled
    /// from the two neighbouring characters: the same key opens and closes, so
    /// `*word|*` and `**word|*` look identical either side of the caret and
    /// want opposite answers. Counting settles it. The run that opened the
    /// emphasis says how many markers are owed to close it, and the markers
    /// already written between the caret and the text say how many are paid.
    /// Step over one only while the debt stands.
    ///
    /// Reading a word behind the caret as "this is closing emphasis" is what
    /// this replaced, and it made the second half of `**bold**` impossible to
    /// type by hand: the step over consumed the keystroke every time.
    private static func markerMeetingItsOwnKind(
        _ m: Character, in text: NSString, at caret: Int
    ) -> Action {
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var index = caret

        // The markers already written on this side of the text.
        var paid = 0
        while index > lineStart, character(at: index - 1, in: text) == m {
            index -= 1
            paid += 1
        }

        // A run with a line start or a space behind it, and the caret inside
        // it, is the empty pair this just wrote. A second marker there is how
        // `**bold**` gets started, so it pairs again rather than counting.
        if paid > 0 {
            let outside = character(at: index - 1, in: text)
            if index <= lineStart || !(outside?.isLetter ?? false || outside?.isNumber ?? false) {
                return .insert("\(m)\(m)", caretOffset: 1, selects: 0)
            }
        }

        // Back past the text being emphasised, to the run that opened it.
        while index > lineStart, character(at: index - 1, in: text) != m { index -= 1 }
        var owed = 0
        while index > lineStart, character(at: index - 1, in: text) == m {
            index -= 1
            owed += 1
        }

        // Nothing is open, so nothing is owed and the marker ahead belongs to
        // something else: `see |*word*` is a marker being typed in front of
        // existing markup, not one closing anything.
        guard owed > 0 else { return .none }

        var ahead = 0
        var forward = caret
        while forward < text.length, character(at: forward, in: text) == m {
            forward += 1
            ahead += 1
        }
        return ahead >= owed - paid ? .skip : .none
    }

    /// True when backspace at `location` sits between a pair, so deleting the
    /// opener should take the closer with it.
    public static func deletesPair(
        in text: NSString, at location: Int, brackets bracketsEnabled: Bool, markdown markdownEnabled: Bool
    ) -> Bool {
        guard location > 0, location < text.length,
              let opener = characterBefore(NSRange(location: location, length: 0), in: text),
              let after = characterAfter(NSRange(location: location, length: 0), in: text)
        else { return false }
        if bracketsEnabled, brackets[opener] == after { return true }
        if markdownEnabled, symmetric.contains(opener), opener == after {
            return isEmptyEmphasis(in: text, at: location, marker: opener)
        }
        return false
    }

    /// True when the two markers either side of `location` hold nothing.
    ///
    /// A symmetric marker cannot tell its ends apart, so `**bold*|*` looks
    /// locally identical to `*|*`: one marker behind, one ahead. What
    /// separates them is the character before the whole run, because an
    /// opener always follows a space or a line start. Without this, a
    /// backspace meant to demote `**bold**` to italic took both closing
    /// markers instead of one.
    private static func isEmptyEmphasis(
        in text: NSString, at location: Int, marker: Character
    ) -> Bool {
        var start = location
        while start > 0, character(at: start - 1, in: text) == marker { start -= 1 }
        guard start > 0, let before = character(at: start - 1, in: text) else { return true }
        return !(before.isLetter || before.isNumber)
    }

    private static func character(at index: Int, in text: NSString) -> Character? {
        guard index >= 0, index < text.length else { return nil }
        return text.substring(with: NSRange(location: index, length: 1)).first
    }

    private static func characterAfter(_ selection: NSRange, in text: NSString) -> Character? {
        let end = NSMaxRange(selection)
        guard end < text.length else { return nil }
        return text.substring(with: NSRange(location: end, length: 1)).first
    }

    private static func characterBefore(_ selection: NSRange, in text: NSString) -> Character? {
        guard selection.location > 0 else { return nil }
        return text.substring(with: NSRange(location: selection.location - 1, length: 1)).first
    }
}
