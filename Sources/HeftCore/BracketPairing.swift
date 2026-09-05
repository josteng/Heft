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

    /// Markers that close with themselves. `*` and `_` are emphasis, `` ` ``
    /// is code. `==` and `~~` are two characters and so are not a single
    /// keystroke's decision.
    public static let symmetric: Set<Character> = ["*", "_", "`"]

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
            // ...unless we are sitting inside a pair this just wrote, where a
            // second marker is how `**bold**` gets started. Skipping there
            // would leave `**` with nothing to close it.
            let previous = characterBefore(selection, in: text)
            if !(symmetric.contains(typed) && previous == typed) { return .skip }
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

        // For a symmetric marker, not immediately *after* a word either, or
        // `snake_case` pairs the underscore in the middle of the word. A
        // marker opening emphasis always follows a space or a line start.
        if symmetric.contains(typed), let previous = characterBefore(selection, in: text),
           previous.isLetter || previous.isNumber {
            return .none
        }

        return .insert("\(typed)\(closer)", caretOffset: 1, selects: 0)
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
        if markdownEnabled, symmetric.contains(opener), opener == after { return true }
        return false
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
