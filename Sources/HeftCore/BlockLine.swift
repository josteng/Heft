import Foundation

/// Whether a construct the editor draws instead of showing is alone on its
/// line, and what leads it there.
public enum BlockLine {

    /// The length of the markers a block construct follows: `0` when it
    /// starts its own line, and `nil` when anything else shares that line.
    ///
    /// A picture pasted onto a bullet is `- ![[shot.png]]`. That is what
    /// Obsidian writes, and in a daily log made of bullets it is what pasting
    /// produces every single time. The construct still owns its line: a list
    /// marker is the line's structure rather than its content, so a picture
    /// behind one is no less a picture.
    ///
    /// Only a marker may lead, which is the whole point of returning nil
    /// rather than a bool. `- see ![[shot.png]]` is a sentence that happens to
    /// end in an embed, and drawing that as a block would swallow the sentence
    /// into a picture's reserved line.
    ///
    /// Quote markers count for the same reason and compose with a list
    /// marker, so `> ![[shot.png]]` and `> - ![[shot.png]]` are both a picture
    /// inside a quote. A callout's header is not: `[!kind]` has already
    /// claimed what follows the marker on that line, which is also why
    /// `QuotedBlock` excludes it.
    ///
    /// Scanned by hand rather than matched: this runs once per embed, and
    /// `range(of:options:.regularExpression)` builds a fresh
    /// `NSRegularExpression` every call.
    public static func leadingMarkers(before range: NSRange, in text: NSString) -> Int? {
        let line = text.lineRange(for: range)
        guard range.location >= line.location, NSMaxRange(range) <= NSMaxRange(line) else { return nil }

        let trailing = text.substring(with: NSRange(
            location: NSMaxRange(range), length: NSMaxRange(line) - NSMaxRange(range)
        ))
        guard trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let leading = Array(text.substring(with: NSRange(
            location: line.location, length: range.location - line.location
        )))
        if leading.allSatisfy(\.isWhitespace) { return 0 }
        return isMarkers(leading) ? leading.count : nil
    }

    /// `[ \t]*>*[ \t]*(([-*+]|\d+[.)])[ \t]+(\[c\][ \t]+)?)?`, and nothing
    /// after it. Everything past the quote markers is optional, because `> ` on
    /// its own is a complete lead.
    private static func isMarkers(_ characters: [Character]) -> Bool {
        var i = 0
        func skipSpaces() -> Bool {
            let start = i
            while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
            return i > start
        }
        _ = skipSpaces()

        var quoted = false
        while i < characters.count, characters[i] == ">" {
            quoted = true
            i += 1
            _ = skipSpaces()
        }
        // A quote's own marker is a complete lead: `> ![[shot.png]]` is a
        // picture in a quote with no list involved.
        if quoted, i == characters.count { return true }

        guard i < characters.count else { return false }
        if characters[i] == "-" || characters[i] == "*" || characters[i] == "+" {
            i += 1
        } else if characters[i].isNumber {
            while i < characters.count, characters[i].isNumber { i += 1 }
            guard i < characters.count, characters[i] == "." || characters[i] == ")" else { return false }
            i += 1
        } else {
            return false
        }
        guard skipSpaces() else { return false }

        // The optional checkbox. Any single character, for the same reason the
        // decorator accepts one: `[/]` and `[-]` are checkboxes in Obsidian.
        if i < characters.count, characters[i] == "[" {
            guard i + 2 < characters.count, characters[i + 2] == "]" else { return false }
            i += 3
            guard skipSpaces() else { return false }
        }
        return i == characters.count
    }
}
