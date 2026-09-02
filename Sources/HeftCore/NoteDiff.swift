import Foundation

/// A line-level diff between two versions of a note, grouped into hunks that
/// can be accepted or rejected one at a time.
///
/// Line-level rather than character-level on purpose: a hunk is a thing a
/// person decides about, and "this paragraph became those two paragraphs" is a
/// decision. A character diff of the same edit is a dozen decisions about
/// fragments that mean nothing on their own.
public struct NoteDiff: Sendable, Equatable {

    /// A run of consecutive changed lines, with the surrounding context needed
    /// to show it.
    public struct Hunk: Sendable, Equatable, Identifiable {
        /// Position is not an id: hunks are re-derived whenever either side
        /// changes, and the UI has to keep its selection across that.
        public let id: Int
        /// Range of lines in the original that this hunk replaces, as a
        /// half-open `[start, end)` in 0-based line numbers. An empty range is
        /// a pure insertion at `start`.
        public let originalRange: Range<Int>
        public let removed: [String]
        public let added: [String]
        /// Up to three lines either side, for display only.
        public let leading: [String]
        public let trailing: [String]

        public var isInsertion: Bool { removed.isEmpty }
        public var isDeletion: Bool { added.isEmpty }

        public init(
            id: Int, originalRange: Range<Int>, removed: [String], added: [String],
            leading: [String] = [], trailing: [String] = []
        ) {
            self.id = id
            self.originalRange = originalRange
            self.removed = removed
            self.added = added
            self.leading = leading
            self.trailing = trailing
        }
    }

    public let hunks: [Hunk]

    public var isEmpty: Bool { hunks.isEmpty }
    public var addedLines: Int { hunks.reduce(0) { $0 + $1.added.count } }
    public var removedLines: Int { hunks.reduce(0) { $0 + $1.removed.count } }

    public init(hunks: [Hunk]) { self.hunks = hunks }

    /// Splits a document the way the diff has to see it: keeping a trailing
    /// empty line when the text ends in a newline would make every file that
    /// ends properly differ from one that does not, in a phantom last hunk.
    public static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Rejoins lines into a document, restoring the trailing newline. Every
    /// note Heft writes ends in one.
    public static func join(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func between(
        original: String, proposed: String, context: Int = 3
    ) -> NoteDiff {
        between(original: lines(of: original), proposed: lines(of: proposed), context: context)
    }

    public static func between(
        original before: [String], proposed after: [String], context: Int = 3
    ) -> NoteDiff {
        var hunks: [Hunk] = []
        for (originalRange, added) in editScript(before, after) {
            let removed = Array(before[originalRange])
            guard !(removed.isEmpty && added.isEmpty) else { continue }
            let leadStart = max(0, originalRange.lowerBound - context)
            let trailEnd = min(before.count, originalRange.upperBound + context)
            hunks.append(Hunk(
                id: hunks.count,
                originalRange: originalRange,
                removed: removed,
                added: added,
                leading: Array(before[leadStart..<originalRange.lowerBound]),
                trailing: Array(before[originalRange.upperBound..<trailEnd])
            ))
        }
        return NoteDiff(hunks: hunks)
    }

    /// Applies a chosen subset of hunks to the original.
    ///
    /// Hunks address the *original*, so they are applied back to front: an
    /// earlier hunk changing the line count would otherwise move every later
    /// one out from under itself.
    public static func apply(
        _ hunks: [Hunk], to original: String, accepting accepted: Set<Int>
    ) -> String {
        var lines = lines(of: original)
        let ordered = hunks
            .filter { accepted.contains($0.id) }
            .sorted { $0.originalRange.lowerBound > $1.originalRange.lowerBound }
        for hunk in ordered {
            guard hunk.originalRange.upperBound <= lines.count else { continue }
            lines.replaceSubrange(hunk.originalRange, with: hunk.added)
        }
        return join(lines)
    }

    // MARK: - Edit script

    /// Returns (range in `before` to replace, replacement lines).
    ///
    /// A plain LCS over lines, trimmed to the differing middle first. The trim
    /// is what keeps it affordable on real notes: an agent rewriting one
    /// paragraph of a 500-line note leaves a common prefix and suffix that the
    /// quadratic part never has to look at.
    private static func editScript(
        _ before: [String], _ after: [String]
    ) -> [(Range<Int>, [String])] {
        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] {
            start += 1
        }
        var endBefore = before.count
        var endAfter = after.count
        while endBefore > start, endAfter > start, before[endBefore - 1] == after[endAfter - 1] {
            endBefore -= 1
            endAfter -= 1
        }

        let midBefore = Array(before[start..<endBefore])
        let midAfter = Array(after[start..<endAfter])
        if midBefore.isEmpty && midAfter.isEmpty { return [] }
        if midBefore.isEmpty { return [(start..<start, midAfter)] }
        if midAfter.isEmpty { return [(start..<endBefore, [])] }

        // Beyond this the table costs more than the result is worth, and the
        // answer "this whole region was rewritten" is honest anyway.
        if midBefore.count > 4000 || midAfter.count > 4000 {
            return [(start..<endBefore, midAfter)]
        }

        var script: [(Range<Int>, [String])] = []
        var i = 0, j = 0
        var pendingRemoveStart: Int?
        var pendingAdd: [String] = []

        func flush(at boundary: Int) {
            let removeStart = pendingRemoveStart ?? boundary
            let range = (start + removeStart)..<(start + boundary)
            if !range.isEmpty || !pendingAdd.isEmpty { script.append((range, pendingAdd)) }
            pendingRemoveStart = nil
            pendingAdd = []
        }

        for anchor in longestCommonSubsequence(midBefore, midAfter) {
            while i < anchor.inBefore {
                if pendingRemoveStart == nil { pendingRemoveStart = i }
                i += 1
            }
            while j < anchor.inAfter {
                pendingAdd.append(midAfter[j])
                j += 1
            }
            if pendingRemoveStart != nil || !pendingAdd.isEmpty { flush(at: i) }
            i += 1
            j += 1
        }
        while i < midBefore.count {
            if pendingRemoveStart == nil { pendingRemoveStart = i }
            i += 1
        }
        while j < midAfter.count {
            pendingAdd.append(midAfter[j])
            j += 1
        }
        if pendingRemoveStart != nil || !pendingAdd.isEmpty { flush(at: i) }

        return script
    }

    private struct Anchor { let inBefore: Int; let inAfter: Int }

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
