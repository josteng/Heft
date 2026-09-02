import Foundation

enum VimMotionKind {
    case exclusive
    case inclusive
    case linewise
}

struct VimMotionResult {
    var target: Int
    var kind: VimMotionKind
}

struct VimText {
    let value: NSString

    init(_ string: String) { value = string as NSString }
    var length: Int { value.length }

    func clampedInsertion(_ location: Int) -> Int { min(max(0, location), length) }

    func clampedCursor(_ location: Int) -> Int {
        guard length > 0 else { return 0 }
        let location = min(max(0, location), length - 1)
        if isNewline(at: location), location > lineContentRange(at: location).location {
            return previousCharacter(from: location)
        }
        return composedRange(at: location).location
    }

    func composedRange(at location: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        return value.rangeOfComposedCharacterSequence(at: min(max(0, location), length - 1))
    }

    func nextCharacter(from location: Int) -> Int {
        guard location < length else { return length }
        return NSMaxRange(composedRange(at: location))
    }

    func previousCharacter(from location: Int) -> Int {
        guard location > 0 else { return 0 }
        return value.rangeOfComposedCharacterSequence(at: location - 1).location
    }

    func isNewline(at location: Int) -> Bool {
        guard location >= 0, location < length else { return false }
        let scalar = value.character(at: location)
        return scalar == 10 || scalar == 13
    }

    func lineRange(at location: Int) -> NSRange {
        value.lineRange(for: NSRange(location: clampedInsertion(location), length: 0))
    }

    func lineContentRange(at location: Int) -> NSRange {
        let line = lineRange(at: location)
        var end = NSMaxRange(line)
        while end > line.location, isNewline(at: end - 1) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    func firstNonblank(at location: Int) -> Int {
        let line = lineContentRange(at: location)
        var cursor = line.location
        while cursor < NSMaxRange(line) {
            let c = value.character(at: cursor)
            if c != 32 && c != 9 { return cursor }
            cursor = nextCharacter(from: cursor)
        }
        return line.location
    }

    func lastCharacterOfLine(at location: Int) -> Int {
        let line = lineContentRange(at: location)
        guard line.length > 0 else { return line.location }
        return previousCharacter(from: NSMaxRange(line))
    }

    func column(at location: Int) -> Int { location - lineRange(at: location).location }

    func vertical(from location: Int, delta: Int, preferredColumn: Int?) -> Int {
        var line = lineRange(at: location)
        let column = preferredColumn ?? self.column(at: location)
        if delta > 0 {
            for _ in 0..<delta {
                let next = NSMaxRange(line)
                guard next < length else { break }
                line = lineRange(at: next)
            }
        } else {
            for _ in 0..<(-delta) {
                guard line.location > 0 else { break }
                line = lineRange(at: line.location - 1)
            }
        }
        let content = lineContentRange(at: line.location)
        guard content.length > 0 else { return content.location }
        if column == .max { return lastCharacterOfLine(at: line.location) }
        return clampedCursor(min(content.location + column, NSMaxRange(content) - 1))
    }

    func lineStart(from location: Int, offset: Int) -> Int {
        var line = lineRange(at: location)
        if offset > 0 {
            for _ in 0..<offset {
                let next = NSMaxRange(line)
                guard next < length else { return line.location }
                line = lineRange(at: next)
            }
        } else if offset < 0 {
            for _ in 0..<(-offset) {
                guard line.location > 0 else { return 0 }
                line = lineRange(at: line.location - 1)
            }
        }
        return line.location
    }

    func lastLineStart() -> Int {
        guard length > 0 else { return 0 }
        return lineRange(at: length - 1).location
    }

    func isKeyword(at location: Int, bigWord: Bool = false) -> Bool {
        guard location >= 0, location < length, !isNewline(at: location) else { return false }
        let string = value.substring(with: composedRange(at: location))
        if string.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        if bigWord { return true }
        return string.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    func wordForward(from location: Int, count: Int, bigWord: Bool = false) -> Int {
        guard length > 0 else { return 0 }
        var p = clampedCursor(location)
        for _ in 0..<max(1, count) {
            let initialKeyword = isKeyword(at: p, bigWord: bigWord)
            let initialWhitespace = whitespace(at: p)
            p = nextCharacter(from: p)
            while p < length {
                if initialWhitespace {
                    if !whitespace(at: p) { break }
                } else if whitespace(at: p) || isKeyword(at: p, bigWord: bigWord) != initialKeyword {
                    break
                }
                p = nextCharacter(from: p)
            }
            while p < length, whitespace(at: p) {
                // Vim treats each empty line as a word. Stop on its newline so
                // a later count consumes that boundary as a separate motion.
                if isNewline(at: p), lineContentRange(at: p).length == 0 { break }
                p = nextCharacter(from: p)
            }
            if p >= length { p = max(0, length - 1) }
        }
        return clampedCursor(p)
    }

    func wordBackward(from location: Int, count: Int, bigWord: Bool = false) -> Int {
        guard length > 0 else { return 0 }
        var p = clampedCursor(location)
        for _ in 0..<max(1, count) {
            if p > 0 { p = previousCharacter(from: p) }
            while p > 0, whitespace(at: p) {
                let previous = previousCharacter(from: p)
                if isNewline(at: p), isNewline(at: previous) { break }
                p = previous
            }
            let keyword = isKeyword(at: p, bigWord: bigWord)
            while p > 0 {
                let previous = previousCharacter(from: p)
                if whitespace(at: previous) || isKeyword(at: previous, bigWord: bigWord) != keyword { break }
                p = previous
            }
        }
        return p
    }

    func wordEnd(from location: Int, count: Int, bigWord: Bool = false) -> Int {
        guard length > 0 else { return 0 }
        var p = clampedCursor(location)
        for iteration in 0..<max(1, count) {
            if iteration > 0 || whitespace(at: p) { p = nextCharacter(from: p) }
            while p < length, whitespace(at: p) { p = nextCharacter(from: p) }
            guard p < length else { return max(0, length - 1) }
            let keyword = isKeyword(at: p, bigWord: bigWord)
            var next = nextCharacter(from: p)
            while next < length, !whitespace(at: next), isKeyword(at: next, bigWord: bigWord) == keyword {
                p = next
                next = nextCharacter(from: next)
            }
        }
        return clampedCursor(p)
    }

    func paragraph(from location: Int, forward: Bool, count: Int) -> Int {
        let original = clampedCursor(location)
        var p = clampedCursor(location)
        for iteration in 0..<max(1, count) {
            if forward {
                var line = lineRange(at: p)
                repeat {
                    let next = NSMaxRange(line)
                    if next >= length {
                        return iteration + 1 < max(1, count)
                            ? original
                            : max(0, length - 1)
                    }
                    line = lineRange(at: next)
                } while lineContentRange(at: line.location).length > 0
                p = line.location
            } else {
                var line = lineRange(at: p)
                guard line.location > 0 else {
                    return iteration + 1 < max(1, count) ? original : 0
                }
                repeat { line = lineRange(at: line.location - 1) }
                while line.location > 0 && lineContentRange(at: line.location).length > 0
                p = line.location
            }
        }
        return p
    }

    func matchingBracket(from location: Int) -> Int? {
        guard length > 0 else { return nil }
        let pairs: [unichar: (unichar, Int)] = [
            40: (41, 1), 91: (93, 1), 123: (125, 1),
            41: (40, -1), 93: (91, -1), 125: (123, -1),
        ]
        var start = clampedCursor(location)
        while start < NSMaxRange(lineContentRange(at: location)), pairs[value.character(at: start)] == nil {
            start = nextCharacter(from: start)
        }
        guard start < length, let (match, direction) = pairs[value.character(at: start)] else { return nil }
        let original = value.character(at: start)
        var depth = 1
        var p = start
        while true {
            if direction > 0 {
                p = nextCharacter(from: p)
                if p >= length { return nil }
            } else {
                if p == 0 { return nil }
                p = previousCharacter(from: p)
            }
            let c = value.character(at: p)
            if c == original { depth += 1 }
            if c == match { depth -= 1 }
            if depth == 0 { return p }
        }
    }

    func find(character: String, from location: Int, forward: Bool, till: Bool, count: Int) -> Int? {
        guard !character.isEmpty else { return nil }
        let line = lineContentRange(at: location)
        var found: Int?
        var searchStart = forward ? nextCharacter(from: location) : line.location
        var searchEnd = forward ? NSMaxRange(line) : location
        for _ in 0..<max(1, count) {
            guard searchEnd >= searchStart else { return nil }
            let options: NSString.CompareOptions = forward ? [] : [.backwards]
            let result = value.range(of: character, options: options, range: NSRange(
                location: searchStart, length: searchEnd - searchStart
            ))
            guard result.location != NSNotFound else { return nil }
            found = result.location
            if forward { searchStart = NSMaxRange(result) } else { searchEnd = result.location }
        }
        guard var target = found else { return nil }
        if till { target = forward ? previousCharacter(from: target) : nextCharacter(from: target) }
        return target
    }

    func whitespace(at location: Int) -> Bool {
        guard location >= 0, location < length else { return true }
        let text = value.substring(with: composedRange(at: location))
        return text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    func wordObject(at location: Int, bigWord: Bool, around: Bool) -> NSRange? {
        guard length > 0 else { return nil }
        var cursor = clampedCursor(location)
        if whitespace(at: cursor) {
            var whitespaceStart = cursor
            while whitespaceStart > 0 {
                let previous = previousCharacter(from: whitespaceStart)
                if !whitespace(at: previous) || isNewline(at: previous) { break }
                whitespaceStart = previous
            }
            var whitespaceEnd = cursor
            while whitespaceEnd < length,
                  whitespace(at: whitespaceEnd),
                  !isNewline(at: whitespaceEnd) {
                whitespaceEnd = nextCharacter(from: whitespaceEnd)
            }
            if !around || whitespaceEnd >= length || isNewline(at: whitespaceEnd) {
                return NSRange(
                    location: whitespaceStart,
                    length: whitespaceEnd - whitespaceStart
                )
            }
            cursor = whitespaceEnd
            let keyword = isKeyword(at: cursor, bigWord: bigWord)
            var wordEnd = nextCharacter(from: cursor)
            while wordEnd < length,
                  !whitespace(at: wordEnd),
                  isKeyword(at: wordEnd, bigWord: bigWord) == keyword {
                wordEnd = nextCharacter(from: wordEnd)
            }
            return NSRange(location: whitespaceStart, length: wordEnd - whitespaceStart)
        }
        let keyword = isKeyword(at: cursor, bigWord: bigWord)
        var start = cursor
        while start > 0 {
            let previous = previousCharacter(from: start)
            if whitespace(at: previous) || isKeyword(at: previous, bigWord: bigWord) != keyword { break }
            start = previous
        }
        var end = nextCharacter(from: cursor)
        while end < length, !whitespace(at: end), isKeyword(at: end, bigWord: bigWord) == keyword {
            end = nextCharacter(from: end)
        }
        if around {
            let originalEnd = end
            while end < length, whitespace(at: end), !isNewline(at: end) { end = nextCharacter(from: end) }
            if end == originalEnd {
                while start > 0 {
                    let previous = previousCharacter(from: start)
                    if !whitespace(at: previous) || isNewline(at: previous) { break }
                    start = previous
                }
            }
        }
        return NSRange(location: start, length: end - start)
    }

    func delimitedObject(at location: Int, opening: Character, closing: Character, around: Bool) -> NSRange? {
        guard let pair = delimiterPair(at: location, opening: opening, closing: closing) else {
            return nil
        }
        return delimitedRange(pair, at: location, quoted: opening == closing, around: around)
    }

    /// Turns a delimiter pair into the object's range. `quoted` selects the
    /// quote rules rather than the bracket ones — it is not `opening ==
    /// closing`, because a curly quote pair is quote-like despite its two ends
    /// being different characters.
    func delimitedRange(
        _ pair: (left: Int, right: Int),
        at location: Int,
        quoted: Bool,
        around: Bool
    ) -> NSRange? {
        var start = around ? pair.left : nextCharacter(from: pair.left)
        var end = around ? nextCharacter(from: pair.right) : pair.right
        if !around, !quoted, start < end, isNewline(at: start) {
            // For a multiline inner block Vim preserves the structural newline
            // immediately after the opening delimiter (`di[` leaves "[\n]").
            start = nextCharacter(from: start)
        }
        // Vim's quote objects absorb adjacent horizontal whitespace. Prefer
        // the following run and use the preceding run only at line end.
        if around, quoted {
            let line = lineContentRange(at: location)
            let originalEnd = end
            while end < NSMaxRange(line), whitespace(at: end) { end = nextCharacter(from: end) }
            if end == originalEnd {
                while start > line.location {
                    let previous = previousCharacter(from: start)
                    guard whitespace(at: previous) else { break }
                    start = previous
                }
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func delimiterPair(
        at location: Int,
        opening: Character,
        closing: Character
    ) -> (left: Int, right: Int)? {
        let openingValue = (String(opening) as NSString).character(at: 0)
        let closingValue = (String(closing) as NSString).character(at: 0)
        if opening == closing {
            let line = lineContentRange(at: location)
            var delimiters: [Int] = []
            var p = line.location
            while p < NSMaxRange(line) {
                if value.character(at: p) == openingValue, !isEscaped(at: p) {
                    delimiters.append(p)
                }
                p = nextCharacter(from: p)
            }
            var index = 0
            while index + 1 < delimiters.count {
                let left = delimiters[index], right = delimiters[index + 1]
                if left <= location, location <= right { return (left, right) }
                if left > location { return (left, right) }
                index += 2
            }
            return nil
        }

        var stack: [Int] = []
        var best: (left: Int, right: Int)?
        var next: (left: Int, right: Int)?
        var p = 0
        while p < length {
            let character = value.character(at: p)
            if character == openingValue {
                stack.append(p)
            } else if character == closingValue, let left = stack.popLast() {
                if left <= location, location <= p {
                    if best == nil || left > best!.left { best = (left, p) }
                } else if left > location, next == nil || left < next!.left {
                    next = (left, p)
                }
            }
            p = nextCharacter(from: p)
        }
        return best ?? next
    }

    private func isEscaped(at location: Int) -> Bool {
        var backslashes = 0
        var p = location
        while p > 0 {
            p -= 1
            guard value.character(at: p) == 92 else { break }
            backslashes += 1
        }
        return backslashes.isMultiple(of: 2) == false
    }
}
