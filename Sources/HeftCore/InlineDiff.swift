import Foundation

/// Which words moved inside a line that changed.
///
/// This is display only, and deliberately separate from `NoteDiff`. A hunk
/// stays the unit a person decides about, for the reason written there; what
/// is missing is not a finer decision but a way to *read* the one on offer.
/// When a hunk replaces one line with a near copy of itself, the reader
/// currently has to compare two long lines by eye to find the four words that
/// differ, which is the whole cost this removes.
///
/// Nothing here changes what accepting a hunk does. `NoteDiff.apply` never
/// sees a span.
public enum InlineDiff {

    /// A run of a line, marked as carried over or as changed.
    public struct Span: Sendable, Equatable {
        public let text: String
        public let changed: Bool

        public init(text: String, changed: Bool) {
            self.text = text
            self.changed = changed
        }
    }

    /// Below this share of tokens in common, the two lines are treated as
    /// unrelated and get no highlighting at all.
    ///
    /// Highlighting is only worth anything when most of the line survived. A
    /// rewritten line marked up word by word is a stripe of colour that says
    /// "everything changed" in the most expensive way available, and it is
    /// harder to read than the plain line. So the fallback is the current
    /// behaviour, which is already correct, just coarse.
    static let similarityFloor = 0.35

    /// Above this share of letters in common, two words in the same place are
    /// treated as the same word edited, and marked letter by letter instead
    /// of whole. Deliberately high: see `byCharacter`.
    static let sameWordFloor = 0.7

    /// The most tokens the quadratic comparison will look at, once the shared
    /// head and tail are trimmed off. Past this the line was rewritten, not
    /// edited, and marking it is both slow and useless.
    static let middleLimit = 400

    /// The two lines split into spans, or nil when they are too different to
    /// be worth comparing word by word.
    ///
    /// Nil rather than "all changed" so a caller cannot draw a fully
    /// highlighted line by accident: the absence of a comparison and a
    /// comparison that found nothing in common must look different.
    public static func between(_ before: String, _ after: String) -> (before: [Span], after: [Span])? {
        guard before != after else { return nil }
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        guard !beforeTokens.isEmpty, !afterTokens.isEmpty else { return nil }

        // Trim to the differing middle first, the way NoteDiff does for
        // lines and for the same reason: the comparison is quadratic, and a
        // line whose last four words changed otherwise pays for every word
        // before them. This runs inside a view body on every redraw, so the
        // shared head and tail have to be free.
        var head = 0
        while head < beforeTokens.count, head < afterTokens.count,
              beforeTokens[head] == afterTokens[head] { head += 1 }
        var tail = 0
        while tail < beforeTokens.count - head, tail < afterTokens.count - head,
              beforeTokens[beforeTokens.count - 1 - tail] == afterTokens[afterTokens.count - 1 - tail] {
            tail += 1
        }
        let beforeMiddle = Array(beforeTokens[head..<(beforeTokens.count - tail)])
        let afterMiddle = Array(afterTokens[head..<(afterTokens.count - tail)])

        // A middle this large is a line that was rewritten rather than
        // edited, which the similarity floor would reject anyway. Refusing
        // before the table is built is what stops a pasted blob on one line
        // from freezing the review sheet.
        guard beforeMiddle.count <= middleLimit, afterMiddle.count <= middleLimit else { return nil }

        let common = longestCommonSubsequence(beforeMiddle, afterMiddle)
        // Whitespace is left out of the count. Two unrelated sentences of
        // similar length share most of their spaces, and counting those would
        // call them related.
        func solid(_ tokens: some Sequence<String>) -> Int {
            tokens.filter { !$0.allSatisfy(\.isWhitespace) }.count
        }
        let shared = solid(beforeTokens[0..<head])
            + solid(beforeTokens[(beforeTokens.count - tail)...])
            + solid(common.map { beforeMiddle[$0.inBefore] })
        guard similarity(shared: shared, beforeTokens, afterTokens) >= similarityFloor else {
            return nil
        }

        var beforePieces = beforeTokens[0..<head].map {
            Piece(text: $0, changed: false, whole: false)
        }
        var afterPieces = afterTokens[0..<head].map {
            Piece(text: $0, changed: false, whole: false)
        }
        var i = 0, j = 0
        for anchor in common {
            replaced(
                Array(beforeMiddle[i..<anchor.inBefore]),
                Array(afterMiddle[j..<anchor.inAfter]),
                into: &beforePieces, and: &afterPieces
            )
            beforePieces.append(
                Piece(text: beforeMiddle[anchor.inBefore], changed: false, whole: false))
            afterPieces.append(
                Piece(text: afterMiddle[anchor.inAfter], changed: false, whole: false))
            i = anchor.inBefore + 1
            j = anchor.inAfter + 1
        }
        replaced(
            Array(beforeMiddle[i...]), Array(afterMiddle[j...]),
            into: &beforePieces, and: &afterPieces
        )
        beforePieces += beforeTokens[(beforeTokens.count - tail)...].map {
            Piece(text: $0, changed: false, whole: false)
        }
        afterPieces += afterTokens[(afterTokens.count - tail)...].map {
            Piece(text: $0, changed: false, whole: false)
        }
        return (settle(beforePieces), settle(afterPieces))
    }

    /// One stretch that the token comparison found replaced, on both sides.
    ///
    /// A stretch of exactly one word against exactly one word is where a
    /// typo lives, and marking the whole word there answers "which word"
    /// when the reader already knows and wants "which letter". So that one
    /// case, and only it, is compared again by character.
    private static func replaced(
        _ before: [String], _ after: [String],
        into beforePieces: inout [Piece], and afterPieces: inout [Piece]
    ) {
        if before.count == 1, after.count == 1,
           isWord(before[0]), isWord(after[0]),
           let refined = byCharacter(before[0], after[0]) {
            beforePieces.append(contentsOf: refined.before)
            afterPieces.append(contentsOf: refined.after)
            return
        }
        beforePieces.append(contentsOf: before.map { Piece(text: $0, changed: true, whole: true) })
        afterPieces.append(contentsOf: after.map { Piece(text: $0, changed: true, whole: true) })
    }

    /// Two words compared letter by letter, or nil when they are different
    /// enough that letters are the wrong unit.
    ///
    /// `takes` and `keeps` share three letters in order. Marking those as
    /// carried over paints a stripe through the middle of both words and
    /// says nothing; the honest answer there is that one word replaced the
    /// other. So the floor is high, and only near-copies get through it:
    /// a plural, a typo, a capital letter.
    private static func byCharacter(
        _ before: String, _ after: String
    ) -> (before: [Piece], after: [Piece])? {
        let beforeCharacters = before.map(String.init)
        let afterCharacters = after.map(String.init)
        let common = longestCommonSubsequence(beforeCharacters, afterCharacters)
        let longest = max(beforeCharacters.count, afterCharacters.count)
        guard longest > 0,
              Double(common.count) / Double(longest) >= sameWordFloor else { return nil }

        var beforeKept = Set<Int>(), afterKept = Set<Int>()
        for anchor in common {
            beforeKept.insert(anchor.inBefore)
            afterKept.insert(anchor.inAfter)
        }
        return (
            beforeCharacters.enumerated().map {
                Piece(text: $1, changed: !beforeKept.contains($0), whole: false)
            },
            afterCharacters.enumerated().map {
                Piece(text: $1, changed: !afterKept.contains($0), whole: false)
            }
        )
    }

    /// A piece on its way to becoming a span, carrying the one fact `settle`
    /// needs and a `Span` cannot: whether a whole token changed, or only some
    /// letters inside one. Only the first kind may be joined across a space.
    private struct Piece {
        let text: String
        let changed: Bool
        let whole: Bool
    }

    private static func isWord(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The same for a whole hunk: which removed line to compare with which
    /// added line.
    ///
    /// Paired by position, and only where both sides have a line. A hunk that
    /// replaces two lines with five has no honest pairing past the second, and
    /// guessing one would highlight words that did not move. Where position
    /// pairs two unrelated lines, `between` rejects them on similarity, so the
    /// wrong pairing costs a comparison rather than a wrong answer.
    public static func spans(
        removed: [String], added: [String]
    ) -> (removed: [[Span]?], added: [[Span]?]) {
        var removedSpans = [[Span]?](repeating: nil, count: removed.count)
        var addedSpans = [[Span]?](repeating: nil, count: added.count)
        for index in 0..<min(removed.count, added.count) {
            guard let pair = between(removed[index], added[index]) else { continue }
            removedSpans[index] = pair.before
            addedSpans[index] = pair.after
        }
        return (removedSpans, addedSpans)
    }

    // MARK: - Tokens

    /// Splits a line into words, whitespace runs, and single punctuation
    /// marks.
    ///
    /// Words are the unit the line is compared in, so that a replacement is
    /// reported as one word standing in for another rather than as letters
    /// shared by accident between two unrelated words. Where a word really
    /// was only edited, `replaced` goes back down to letters. Punctuation is
    /// its own token so that adding a comma marks the comma rather than the
    /// word it now follows.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord = false

        for character in line {
            let isWord = character.isLetter || character.isNumber || character == "_"
            let isSpace = character.isWhitespace
            if isSpace {
                // Whitespace joins its own run: a line that gained two spaces
                // should report one changed gap, not two.
                if !current.isEmpty, !currentIsWord, current.allSatisfy(\.isWhitespace) {
                    current.append(character)
                } else {
                    if !current.isEmpty { tokens.append(current) }
                    current = String(character)
                    currentIsWord = false
                }
            } else if isWord {
                if currentIsWord {
                    current.append(character)
                } else {
                    if !current.isEmpty { tokens.append(current) }
                    current = String(character)
                    currentIsWord = true
                }
            } else {
                // Punctuation stands alone.
                if !current.isEmpty { tokens.append(current) }
                tokens.append(String(character))
                current = ""
                currentIsWord = false
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// How much of the two lines the common subsequence accounts for.
    ///
    /// Whitespace is excluded from the measure. Two unrelated sentences of
    /// similar length share most of their spaces, and counting those would
    /// call them related.
    private static func similarity(
        shared: Int, _ before: [String], _ after: [String]
    ) -> Double {
        func weight(_ tokens: [String]) -> Int {
            tokens.filter { !$0.allSatisfy(\.isWhitespace) }.count
        }
        let longest = max(weight(before), weight(after))
        guard longest > 0 else { return 0 }
        return min(1, Double(shared) / Double(longest))
    }

    /// Turns a run of pieces into spans: bridges the gaps inside one edit,
    /// then glues neighbours that agree.
    private static func settle(_ pieces: [Piece]) -> [Span] {
        var marks = pieces.map(\.changed)
        let original = marks
        // A space *between* two changed words belongs to the same edit. The
        // token comparison keeps such a space, because both lines have one
        // there, and without this a rewritten phrase comes out as one mark
        // per word with unmarked gaps between them: several small edits
        // where there was one.
        for index in pieces.indices where !original[index] {
            guard pieces[index].text.allSatisfy(\.isWhitespace) else { continue }
            // Whole-token changes only. A space between a plural's "s" and
            // the next changed word is not part of one edit, and joining
            // them would draw a mark that starts inside a word.
            let before = index > 0 && original[index - 1] && pieces[index - 1].whole
            let after = index + 1 < pieces.count && original[index + 1] && pieces[index + 1].whole
            if before, after { marks[index] = true }
        }

        var spans: [Span] = []
        for (index, piece) in pieces.enumerated() {
            let changed = marks[index]
            if let last = spans.last, last.changed == changed {
                spans[spans.count - 1] = Span(text: last.text + piece.text, changed: changed)
            } else {
                spans.append(Span(text: piece.text, changed: changed))
            }
        }
        return spans
    }

    // MARK: - Edit script

    private struct Anchor { let inBefore: Int; let inAfter: Int }

    /// The same plain LCS `NoteDiff` runs over lines, here over tokens.
    ///
    /// Quadratic, and bounded by the length of one line, which is why it can
    /// stay plain: the table for two 200-token lines is smaller than the one
    /// `NoteDiff` already builds for a modest note.
    private static func longestCommonSubsequence(
        _ a: [String], _ b: [String]
    ) -> [Anchor] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var anchors: [Anchor] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                anchors.append(Anchor(inBefore: i, inAfter: j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return anchors
    }
}
