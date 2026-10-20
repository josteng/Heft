import Foundation

/// A line-based three-way merge, for a note that changed on disk while the
/// editor held unsaved edits to it.
///
/// `base` is the text both sides started from (what was last read from or
/// written to disk), `mine` the buffer, `theirs` the file now. The result
/// carries both sides' changes, or is nil when they touch the same lines and
/// only a person can say what the note should read.
///
/// What it is for is a capture: a line filed into the note being typed in,
/// which used to cost the line (a conflict answered "keep mine") or the
/// keystrokes. So it is deliberately byte-exact rather than normalising:
/// lines keep their own `\r\n` or `\n`, and a missing final newline stays
/// missing unless a side that added lines after it says otherwise. The
/// hunks are `NoteDiff`'s, not a second diff.
public enum NoteMerge {

    public static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs { return mine }
        if mine == base { return theirs }
        if theirs == base { return mine }

        // Each text is split into lines that keep their terminators, after
        // giving one that ends mid-line a virtual newline. Without it, "last"
        // and "last\n" would differ, and an append after a note's unfinished
        // last line would read as a change to that line: a conflict with
        // whoever is typing on it. One style for all three, so the virtual
        // terminator matches the real ones the other sides have.
        let newline = [base, mine, theirs].contains { $0.contains("\r\n") } ? "\r\n" : "\n"
        let baseSide = Side(base, newline: newline)
        let mineSide = Side(mine, newline: newline)
        let theirSide = Side(theirs, newline: newline)

        let mineChanges = changes(from: baseSide, to: mineSide, by: .mine)
        var theirChanges = changes(from: baseSide, to: theirSide, by: .theirs)

        // The same edit made on both sides is made once.
        theirChanges.removeAll { theirs in
            mineChanges.contains { $0.range == theirs.range && $0.lines == theirs.lines }
        }
        for mine in mineChanges {
            for theirs in theirChanges where overlap(mine, theirs) { return nil }
        }

        // In base order. A pure insertion at the point where another change
        // starts goes before it; two insertions at one point put theirs
        // first, since it is already on disk and mine is still being typed,
        // which keeps the reader's caret line where it was, last.
        let ordered = (mineChanges + theirChanges).sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            if a.range.isEmpty != b.range.isEmpty { return a.range.isEmpty }
            return a.side == .theirs && b.side == .mine
        }

        var result: [String] = []
        // Whether the result's last line is a side's unfinished last line,
        // whose newline is the virtual one and must come off again.
        var endsUnfinished = false
        var cursor = 0
        for change in ordered {
            if cursor < change.range.lowerBound {
                result.append(contentsOf: baseSide.lines[cursor..<change.range.lowerBound])
                endsUnfinished = false
            }
            result.append(contentsOf: change.lines)
            let side = change.side == .mine ? mineSide : theirSide
            if !change.lines.isEmpty {
                endsUnfinished = change.reachesEnd && !side.endsInNewline
            } else if change.reachesEnd {
                // A deletion to the end leaves the line before it as this
                // side's last, so this side says whether it is finished.
                endsUnfinished = !side.endsInNewline
            }
            cursor = max(cursor, change.range.upperBound)
        }
        if cursor < baseSide.lines.count {
            result.append(contentsOf: baseSide.lines[cursor...])
            // Untouched by either side to the end, so whether it ends in a
            // newline is the one thing still to merge: a side that changed
            // it wins, and they cannot have changed it in different ways.
            let finished = mineSide.endsInNewline == baseSide.endsInNewline
                ? theirSide.endsInNewline : mineSide.endsInNewline
            endsUnfinished = !finished
        }

        var merged = result.joined()
        if endsUnfinished, merged.hasSuffix(newline) {
            merged.removeLast()
            // `\r\n` is one Character, so one removal takes all of it.
        }
        return merged
    }

    // MARK: - Pieces

    private enum Origin { case mine, theirs }

    private struct Side {
        let lines: [String]
        let endsInNewline: Bool

        init(_ text: String, newline: String) {
            // Bytes, not Characters: `\r\n` is one Character and would never
            // match a plain `\n`.
            endsInNewline = text.isEmpty || text.utf8.last == UInt8(ascii: "\n")
            let terminated = endsInNewline ? text : text + newline
            var lines: [String] = []
            var start = terminated.startIndex
            while let breakAt = terminated.utf8[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let end = terminated.utf8.index(after: breakAt)
                lines.append(String(terminated[start..<end]))
                start = end
            }
            self.lines = lines
        }
    }

    private struct Change {
        let range: Range<Int>
        let lines: [String]
        let side: Origin
        /// Whether the change runs to the end of its side's text, so its last
        /// line is that side's last line.
        let reachesEnd: Bool
    }

    private static func changes(from base: Side, to side: Side, by origin: Origin) -> [Change] {
        let hunks = NoteDiff.between(original: base.lines, proposed: side.lines, context: 0).hunks
        // A hunk's end in `side` is its end in base shifted by what the hunks
        // before it, and it, added and removed.
        var shift = 0
        return hunks.map { hunk in
            shift += hunk.added.count - hunk.removed.count
            return Change(
                range: hunk.originalRange,
                lines: hunk.added,
                side: origin,
                reachesEnd: hunk.originalRange.upperBound + shift == side.lines.count
            )
        }
    }

    /// Whether two changes claim the same lines, so applying both would mean
    /// choosing between them. Changes that only touch, one ending where the
    /// other starts, do not: the order they apply in is the order of base.
    private static func overlap(_ a: Change, _ b: Change) -> Bool {
        switch (a.range.isEmpty, b.range.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return b.range.lowerBound < a.range.lowerBound && a.range.lowerBound < b.range.upperBound
        case (false, true):
            return a.range.lowerBound < b.range.lowerBound && b.range.lowerBound < a.range.upperBound
        case (false, false):
            return max(a.range.lowerBound, b.range.lowerBound) < min(a.range.upperBound, b.range.upperBound)
        }
    }
}
