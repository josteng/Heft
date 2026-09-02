import Foundation

/// The one span in which two versions of a document differ.
///
/// Typing changes one character, so comparing whole documents is wasteful in a
/// way that shows up as lag: the useful information is "what moved, and by how
/// much", and a common-prefix/common-suffix scan answers that in one pass over
/// the two buffers.
public struct SourceEdit: Equatable, Sendable {
    /// The differing span in the *new* text.
    public let changed: NSRange
    /// The same span in the *old* text.
    public let previous: NSRange

    /// How far everything after the edit has moved.
    public var delta: Int { changed.length - previous.length }

    public init(changed: NSRange, previous: NSRange) {
        self.changed = changed
        self.previous = previous
    }

    /// Where an offset in the old text ends up in the new text.
    ///
    /// Offsets inside the edited span have no single answer, so they collapse
    /// onto the span's own edges: callers only use this to bound a range that
    /// is about to be marked dirty in full anyway.
    public func mapStart(_ offset: Int) -> Int {
        if offset <= previous.location { return offset }
        if offset >= NSMaxRange(previous) { return offset + delta }
        return changed.location
    }

    public func mapEnd(_ offset: Int) -> Int {
        if offset <= previous.location { return offset }
        if offset >= NSMaxRange(previous) { return offset + delta }
        return NSMaxRange(changed)
    }

    public static func between(_ old: NSString, _ new: NSString) -> SourceEdit {
        let oldLength = old.length
        let newLength = new.length
        guard oldLength > 0, newLength > 0 else {
            return SourceEdit(
                changed: NSRange(location: 0, length: newLength),
                previous: NSRange(location: 0, length: oldLength)
            )
        }

        var oldChars = [unichar](repeating: 0, count: oldLength)
        var newChars = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&oldChars, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&newChars, range: NSRange(location: 0, length: newLength))

        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              oldChars[oldLength - 1 - suffix] == newChars[newLength - 1 - suffix] {
            suffix += 1
        }

        return SourceEdit(
            changed: NSRange(location: prefix, length: newLength - suffix - prefix),
            previous: NSRange(location: prefix, length: oldLength - suffix - prefix)
        )
    }
}

/// Which parts of the document a restyle actually has to touch.
///
/// The live surface used to re-decorate, re-attribute and re-lay out the whole
/// note on every keystroke. That is the same answer as before everywhere except
/// around the caret, and rewriting an attribute — even to the value it already
/// holds — throws away TextKit's layout for that range, so the cost was a full
/// reflow per character.
///
/// The styled result is a pure function of (decorations, their reveal state,
/// the text they cover). So two restyles differ exactly where that input
/// differs, and this computes where. Everything else keeps the attributes it
/// already has, and keeps its layout with them.
///
/// The ranges returned satisfy an invariant the styler depends on: they are
/// line-aligned, and every decoration is either wholly inside one of them or
/// wholly outside all of them. So the styler can reset those ranges to base
/// attributes and rebuild every decoration touching them, with nothing
/// half-styled at a boundary.
public enum RestyleScope {

    /// Everything one restyle's output depends on, as it was when applied.
    public struct Snapshot {
        public let source: NSString
        public let decorations: [MarkdownDecoration]
        public let reveal: Reveal

        public init(source: NSString, decorations: [MarkdownDecoration], reveal: Reveal) {
            // Copied, and it matters: `NSTextStorage.string` hands back its
            // live backing store, and bridging that through `as NSString` can
            // hand back the very same mutable object. Held onto, the snapshot
            // of "what the storage looked like last time" would quietly become
            // the current text on the next keystroke — the diff would compare
            // the document against itself, find nothing changed, and the
            // surface would stop restyling altogether.
            self.source = source.copy() as? NSString ?? source
            self.decorations = decorations
            self.reveal = reveal
        }
    }

    /// What one restyle has to redo, and how far the rest of the document
    /// moved to make room for it.
    public struct Scope {
        /// Line-aligned ranges whose styling may have changed. Empty means the
        /// document is already styled correctly and the pass can be skipped.
        public let dirty: [NSRange]
        /// The text edit itself, which is what everything outside `dirty` was
        /// displaced by, and therefore what the previous pass's widgets have
        /// to be moved along by to stay on their own paragraphs.
        public let edit: SourceEdit

        public var isEmpty: Bool { dirty.isEmpty }
    }

    public static func scope(from old: Snapshot, to new: Snapshot) -> Scope {
        Scope(dirty: dirtyRanges(from: old, to: new), edit: SourceEdit.between(old.source, new.source))
    }

    /// The line-aligned ranges whose styling may have changed between the two
    /// snapshots. An empty result means the document is already correctly
    /// styled and the restyle can be skipped outright.
    public static func dirtyRanges(from old: Snapshot, to new: Snapshot) -> [NSRange] {
        // Moving the caret cannot change what the constructs *are*, only which
        // of them show their markup. Worth its own path: it is the common case
        // for arrow keys, and it answers in one walk rather than by indexing
        // every decoration in the note.
        if old.source.isEqual(to: new.source as String),
           old.decorations.count == new.decorations.count {
            var dirty: [NSRange] = []
            for (before, after) in zip(old.decorations, new.decorations) {
                guard before == after else {
                    dirty.append(before.range)
                    dirty.append(after.range)
                    continue
                }
                if old.reveal.state(of: before) != new.reveal.state(of: after) {
                    dirty.append(after.range)
                }
            }
            return normalize(dirty, in: new.source, decorations: new.decorations)
        }

        let edit = SourceEdit.between(old.source, new.source)
        var dirty: [NSRange] = []
        if edit.changed.length > 0 || edit.previous.length > 0 {
            dirty.append(edit.changed)
        }

        // Old decorations, moved into new coordinates, indexed by where they
        // land. Anything overlapping the edit cannot be carried across and is
        // dirty on the spot.
        struct Entry {
            let decoration: MarkdownDecoration
            let revealed: RevealState
            var used = false
        }
        var carried: [Int: [Entry]] = [:]
        for decoration in old.decorations {
            let range = decoration.range
            let revealed = old.reveal.state(of: decoration)
            if NSMaxRange(range) <= edit.previous.location {
                carried[range.location, default: []].append(
                    Entry(decoration: decoration, revealed: revealed)
                )
            } else if range.location >= NSMaxRange(edit.previous) {
                let moved = decoration.shifted(by: edit.delta)
                carried[moved.range.location, default: []].append(
                    Entry(decoration: moved, revealed: revealed)
                )
            } else {
                let start = edit.mapStart(range.location)
                dirty.append(NSRange(
                    location: start, length: max(0, edit.mapEnd(NSMaxRange(range)) - start)
                ))
            }
        }

        for decoration in new.decorations {
            let range = decoration.range
            // Anything overlapping the edited span is new by definition.
            guard NSMaxRange(range) <= edit.changed.location
                    || range.location >= NSMaxRange(edit.changed)
            else {
                dirty.append(range)
                continue
            }
            guard var entries = carried[range.location],
                  let index = entries.firstIndex(where: {
                      !$0.used && $0.decoration == decoration
                  })
            else {
                // Nothing like it was here before: newly styled ground.
                dirty.append(range)
                continue
            }
            entries[index].used = true
            carried[range.location] = entries
            // Same construct, but the caret moved into or out of it, so its
            // markup has to collapse or come back.
            if entries[index].revealed != new.reveal.state(of: decoration) {
                dirty.append(range)
            }
        }

        // Whatever was styled last time and has no counterpart now has to be
        // reset, or its markup stays collapsed after the construct is gone.
        for entries in carried.values {
            for entry in entries where !entry.used {
                dirty.append(entry.decoration.range)
            }
        }

        return normalize(dirty, in: new.source, decorations: new.decorations)
    }

    /// Snaps ranges to whole lines, absorbs every decoration they touch, and
    /// merges what overlaps — the invariant the styler relies on.
    static func normalize(
        _ ranges: [NSRange], in text: NSString, decorations: [MarkdownDecoration]
    ) -> [NSRange] {
        let length = text.length
        var current = ranges.compactMap { range -> NSRange? in
            let clamped = NSIntersectionRange(
                NSRange(location: max(0, range.location), length: max(0, range.length)),
                NSRange(location: 0, length: length)
            )
            // A zero-length edit at the caret still dirties the line it sits
            // on: an emptied line changes that line's paragraph style.
            guard range.location <= length else { return nil }
            return clamped.length > 0
                ? clamped
                : NSRange(location: min(range.location, length), length: 0)
        }
        guard !current.isEmpty else { return [] }

        // Absorbing a decoration can extend a range onto new lines, which can
        // in turn touch further decorations. Multi-line constructs do not nest
        // deeply, so this settles in a couple of rounds; the bound is there so
        // a surprise cannot spin.
        for _ in 0..<8 {
            let lined = current.map { neighbouringLines(of: $0, in: text) }
            var merged = coalesce(lined)
            var grown = false
            for decoration in decorations {
                let range = decoration.range
                guard range.length > 0 else { continue }
                guard merged.contains(where: { NSIntersectionRange($0, range).length > 0 })
                else { continue }
                guard !merged.contains(where: { NSIntersectionRange($0, range) == range })
                else { continue }
                merged.append(range)
                grown = true
            }
            current = grown ? coalesce(merged) : merged
            if !grown { break }
        }
        return current
    }

    /// The lines a range covers, plus the one either side of it.
    ///
    /// The neighbours are not slack. Pressing Return inserts a newline that
    /// belongs, as far as `lineRange` is concerned, to the line it *ends* — so
    /// the empty line it brings into existence sits just past the edit, and a
    /// range snapped only to its own lines would never restyle it. Empty lines
    /// carry their own paragraph style, so it would keep the spacing of
    /// whatever was there before. One line of margin costs nothing and closes
    /// the whole family of boundary cases this one came from.
    static func neighbouringLines(of range: NSRange, in text: NSString) -> NSRange {
        let line = text.lineRange(for: range)
        let start = line.location > 0
            ? text.lineRange(for: NSRange(location: line.location - 1, length: 0)).location
            : 0
        let end = NSMaxRange(line) < text.length
            ? NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)))
            : NSMaxRange(line)
        return NSRange(location: start, length: end - start)
    }

    /// Sorts and merges, joining ranges that touch as well as those that
    /// overlap: two adjacent dirty lines are one dirty region.
    static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last, range.location <= NSMaxRange(last) else {
                result.append(range)
                continue
            }
            let end = max(NSMaxRange(last), NSMaxRange(range))
            result[result.count - 1] = NSRange(
                location: last.location, length: end - last.location
            )
        }
        return result
    }
}
