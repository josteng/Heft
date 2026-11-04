import Foundation

/// What the properties table decides from the text alone: where a caret
/// that landed somewhere hidden goes, what a row left behind is tidied
/// into, and what a key typed or a target tapped writes. The Mac and iOS
/// editors each own a buffer and a pointer of their own; this is the part
/// they share, so the table behaves the same on both.
///
/// `normal` is Vim's Normal mode, where the cursor stands on a character
/// rather than between two; iOS has no Vim and always passes false.
public enum PropertySurface {

    // MARK: Rows

    /// The row whose key line holds `caret`, its end included.
    public static func row(at caret: Int, in source: String) -> PropertyEditing.Row? {
        PropertyEditing.rows(in: source).first { caret >= $0.range.location && caret <= $0.valueEnd }
    }

    /// The row starting at `start`.
    public static func row(startingAt start: Int, in source: String) -> PropertyEditing.Row? {
        PropertyEditing.rows(in: source).first { $0.range.location == start }
    }

    /// The key written on the line at `start`, or nil before its colon.
    public static func key(onLineAt start: Int, in source: String) -> String? {
        let text = source as NSString
        let line = text.substring(with: text.lineRange(for: NSRange(location: start, length: 0)))
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Where the line holding `location` ends, before its line break.
    public static func lineEnd(of location: Int, in source: String) -> Int {
        let text = source as NSString
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        while line.length > 0, [10, 13].contains(text.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        return NSMaxRange(line)
    }

    /// A row holding only a key, its colon not yet typed.
    public static func isKeyWithoutColon(_ row: PropertyEditing.Row, in source: String) -> Bool {
        let text = source as NSString
        let line = text.substring(with: NSRange(location: row.range.location, length: row.valueEnd - row.range.location))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !line.contains(":") && line.first != " " && line.first != "\t"
            && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-")
    }

    /// Whether the value of the row at `start` has no text a tap could land
    /// in: a list, an empty value, a key with no colon yet.
    public static func valueHasNoText(onLineAt start: Int, in source: String) -> Bool {
        guard let row = row(startingAt: start, in: source) else { return false }
        guard let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd) else {
            return isKeyWithoutColon(row, in: source)
        }
        let value = (source as NSString).substring(with: NSRange(location: gap.valueStart, length: row.valueEnd - gap.valueStart))
        return value.isEmpty || value.hasPrefix("[")
            || PropertyListContext.detect(in: source, selection: NSRange(location: row.valueEnd, length: 0)) != nil
    }

    /// `caret` moved along by `edit`, which leaves it where it was: before
    /// the edit it stays, after it it shifts, inside it it goes to its start.
    public static func caret(_ caret: Int, keptThrough edit: MarkdownEditing.Edit) -> Int {
        let delta = (edit.replacement as NSString).length - edit.range.length
        if caret >= NSMaxRange(edit.range) { return max(0, caret + delta) }
        if caret > edit.range.location { return edit.range.location }
        return caret
    }

    // MARK: Where the caret may stand

    /// The fences are not rows while the table shows: the opening one is
    /// the heading, the closing one takes no room. A caret on one goes to
    /// the first property from the opening fence, and from the closing one
    /// to the last property when it came from below, to the text after the
    /// block when it came from above. Nil when it may stay.
    public static func caretOffFences(in source: String, caret: Int, previous: Int?, normal: Bool) -> Int? {
        guard let block = PropertyEditing.blockRange(in: source) else { return nil }
        let text = source as NSString
        let opening = text.lineRange(for: NSRange(location: 0, length: 0))
        let closing = text.lineRange(for: NSRange(location: NSMaxRange(block) - 1, length: 0))
        let rows = PropertyEditing.rows(in: source)
        let target: Int
        if NSLocationInRange(caret, opening) || (caret == 0 && opening.length == 0) {
            target = rows.first?.range.location ?? NSMaxRange(block)
        } else if NSLocationInRange(caret, closing) {
            if let last = rows.last, (previous ?? 0) > caret {
                target = normal ? max(last.valueEnd - 1, last.range.location) : last.valueEnd
            } else {
                target = min(NSMaxRange(block), text.length)
            }
        } else {
            return nil
        }
        return target == caret ? nil : target
    }

    /// A caret on a folded list item's hidden line goes to the end of the
    /// list's key line, where the list is edited.
    public static func caretOffFoldedItem(in source: String, caret: Int) -> Int? {
        guard let row = PropertyEditing.rows(in: source).first(where: {
                  NSLocationInRange(caret, $0.range) && caret > $0.valueEnd
              }),
              PropertyListContext.detect(in: source, selection: NSRange(location: row.valueEnd, length: 0)) != nil
        else { return nil }
        return row.valueEnd
    }

    /// Out of the hidden `: ` between a key and its value, where a caret is
    /// invisible. Arriving from the left it goes on to the value, from the
    /// right back to the key's end; a tap goes to the column it landed in
    /// (`clicked`), and leaving Vim's Insert mode keeps the value's side.
    public static func caretOutOfColonGap(
        in source: String, caret: Int, previous: Int?, clicked: (line: Int, inValue: Bool)?,
        leavingInsert: Bool, normal: Bool
    ) -> Int? {
        guard let gap = PropertyEditing.colonGap(in: source, at: caret) else { return nil }
        let end = lineEnd(of: caret, in: source)
        // A Normal-mode cursor stands on a character, and the colon is one.
        let first = normal ? gap.keyEnd : gap.keyEnd + 1
        guard caret >= first, caret < gap.valueStart || (normal && caret == gap.valueStart && gap.valueStart == end) else {
            return nil
        }
        let lineStart = (source as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
        let keyTarget = normal ? max(gap.keyEnd - 1, lineStart) : gap.keyEnd
        let hasValue = gap.valueStart < end
        // In Normal mode the last hidden character before an empty value or
        // a list's input is that value's place, not a gap to leave.
        if normal, !hasValue, caret == gap.valueStart - 1 { return nil }
        let valueTarget = hasValue || !normal ? gap.valueStart : gap.valueStart - 1
        let toValue: Bool
        if let clicked, clicked.line == lineStart {
            toValue = clicked.inValue
        } else if normal, leavingInsert {
            // Esc steps one character back, as Vim's does: from a value's
            // start that is into the gap, and it is still the value's.
            toValue = true
        } else {
            toValue = (previous ?? caret) < caret
        }
        let target = toValue ? valueTarget : keyTarget
        return target == caret ? nil : target
    }

    /// ↑ and ↓ a property at a time: past a list's hidden lines to the end
    /// of the next value, out of the table at its foot, and into it from the
    /// line under it. Nil when the caret is not the table's to move; the
    /// caret itself at the first row going up, where it stays.
    public static func rowMove(in source: String, caret: Int, down: Bool) -> Int? {
        guard let block = PropertyEditing.blockRange(in: source) else { return nil }
        let rows = PropertyEditing.rows(in: source)
        guard !rows.isEmpty else { return nil }
        if let index = rows.firstIndex(where: { NSLocationInRange(caret, $0.range) }) {
            if down { return index + 1 < rows.count ? rows[index + 1].valueEnd : NSMaxRange(block) }
            return index > 0 ? rows[index - 1].valueEnd : caret
        }
        if !down, (source as NSString).lineRange(for: NSRange(location: caret, length: 0)).location == NSMaxRange(block),
           let last = rows.last {
            return last.valueEnd
        }
        return nil
    }

    // MARK: What a tap does

    /// What a tap in a row settles into, once the tap is over.
    public struct Settlement: Equatable {
        /// Edits to make in order, each named for undo when it has one.
        public var edits: [(edit: MarkdownEditing.Edit, name: String?)]
        /// Where the caret goes after them.
        public var caret: Int
        /// The key line given a space after its colon, to take back if it
        /// is left empty.
        public var spacedLine: Int?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.edits.map(\.edit) == rhs.edits.map(\.edit) && lhs.edits.map(\.name) == rhs.edits.map(\.name)
                && lhs.caret == rhs.caret && lhs.spacedLine == rhs.spacedLine
        }
    }

    /// Where a tap on the row at `lineStart` leaves the caret: in the key
    /// column, at most the key's end; in a value, where it landed; in an
    /// empty value, the value's place, given its space; on a list, after
    /// its pills, where the next item is typed. An inline `[a, b]` list
    /// becomes a block list first, so it edits as pills too, as Obsidian
    /// does to one edited in its properties. A key not yet given its colon
    /// gets one when its value column is tapped.
    public static func settlingTap(
        onLineAt lineStart: Int, inValue: Bool, caret: Int, normal: Bool, in source: String
    ) -> Settlement? {
        guard let row = row(startingAt: lineStart, in: source) else { return nil }
        guard let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd) else {
            guard inValue, isKeyWithoutColon(row, in: source) else { return nil }
            let end = row.valueEnd
            let edit = MarkdownEditing.Edit(
                range: NSRange(location: end, length: 0), replacement: ": ",
                selection: NSRange(location: normal ? end + 1 : end + 2, length: 0)
            )
            return Settlement(edits: [(edit, "Edit Property")], caret: edit.selection.location, spacedLine: lineStart)
        }
        let text = source as NSString
        if !inValue {
            let keyEnd = normal ? max(gap.keyEnd - 1, row.range.location) : gap.keyEnd
            return Settlement(edits: [], caret: min(caret, keyEnd), spacedLine: nil)
        }
        let value = text.substring(with: NSRange(location: gap.valueStart, length: row.valueEnd - gap.valueStart))
        if value.hasPrefix("["), value.hasSuffix("]") {
            let key = text.substring(with: NSRange(location: row.range.location, length: gap.keyEnd - row.range.location))
            guard let edit = PropertyEditing.converting(key: key.trimmingCharacters(in: .whitespaces), toList: true, in: source)
            else { return nil }
            let converted = text.replacingCharacters(in: edit.range, with: edit.replacement)
            // A block list now, settled as one.
            guard var then = settlingTap(
                onLineAt: lineStart, inValue: true, caret: edit.selection.location, normal: normal, in: converted
            ) else { return Settlement(edits: [(edit, "Edit List")], caret: edit.selection.location, spacedLine: nil) }
            then.edits.insert((edit, "Edit List"), at: 0)
            return then
        }
        if PropertyListContext.detect(in: source, selection: NSRange(location: row.valueEnd, length: 0)) != nil
            || gap.valueStart >= row.valueEnd {
            // A list's input or an empty value: the space after the colon
            // first, or the caret is drawn against the key. Then the place
            // after it, or in Normal mode on it.
            var edits: [(MarkdownEditing.Edit, String?)] = []
            var spaced: Int?
            var end = row.valueEnd
            if gap.valueStart == gap.keyEnd + 1, gap.valueStart == row.valueEnd {
                let space = MarkdownEditing.Edit(
                    range: NSRange(location: gap.valueStart, length: 0), replacement: " ",
                    selection: NSRange(location: gap.valueStart + 1, length: 0)
                )
                edits.append((space, nil))
                spaced = row.range.location
                end += 1
            }
            return Settlement(edits: edits, caret: normal ? end - 1 : end, spacedLine: spaced)
        }
        return Settlement(edits: [], caret: max(min(caret, row.valueEnd - (normal ? 1 : 0)), gap.valueStart), spacedLine: nil)
    }

    /// The item at `index` of the list at `start` taken away; an inline
    /// `[a, b]` list made a block list first, as it is when edited. Each
    /// edit leaves the caret where it was: the × is a button.
    public static func removingItem(at index: Int, fromListAt start: Int, in source: String)
        -> [(edit: MarkdownEditing.Edit, name: String)] {
        guard let row = row(startingAt: start, in: source) else { return [] }
        let text = source as NSString
        var edits: [(MarkdownEditing.Edit, String)] = []
        var current = source
        let line = text.substring(with: NSRange(location: start, length: row.valueEnd - start))
        if line.contains("["), let colon = line.firstIndex(of: ":"),
           let edit = PropertyEditing.converting(
               key: String(line[..<colon]).trimmingCharacters(in: .whitespaces), toList: true, in: source
           ) {
            edits.append((edit, "Edit List"))
            current = text.replacingCharacters(in: edit.range, with: edit.replacement)
        }
        guard let listRow = self.row(startingAt: start, in: current),
              let list = PropertyListContext.detect(in: current, selection: NSRange(location: listRow.valueEnd, length: 0)),
              let edit = list.removing(at: index, in: current)
        else { return edits }
        edits.append((edit, "Remove Item"))
        return edits
    }

    // MARK: What typing does

    /// Where text typed into the hidden gap between a key and its value
    /// really goes: the value's start, with a space after a bare colon.
    public static func valueInsertion(of typed: String, selection: NSRange, in source: String) -> MarkdownEditing.Edit? {
        guard selection.length == 0, !typed.contains("\n"),
              let gap = PropertyEditing.colonGap(in: source, at: selection.location),
              selection.location > gap.keyEnd, selection.location <= gap.valueStart
        else { return nil }
        let spaced = gap.valueStart > gap.keyEnd + 1
        // At the value's start with its space in place nothing needs moving.
        guard selection.location < gap.valueStart || !spaced else { return nil }
        let replacement = (spaced ? "" : " ") + typed
        return MarkdownEditing.Edit(
            range: NSRange(location: gap.valueStart, length: 0), replacement: replacement,
            selection: NSRange(location: gap.valueStart + (replacement as NSString).length, length: 0)
        )
    }

    /// Whether deleting from the caret would eat into the hidden `: `,
    /// which would run the value into the key.
    public static func deletionCrossesColonGap(selection: NSRange, forward: Bool, in source: String) -> Bool {
        guard selection.length == 0, let gap = PropertyEditing.colonGap(in: source, at: selection.location) else { return false }
        return forward
            ? selection.location >= gap.keyEnd && selection.location < gap.valueStart
            : selection.location > gap.keyEnd && selection.location <= gap.valueStart
    }

    /// Backspace with nothing typed after a list's pills takes the last.
    public static func backspaceRemovingItem(selection: NSRange, in source: String) -> MarkdownEditing.Edit? {
        guard let list = PropertyListContext.detect(in: source, selection: selection),
              list.pending.length == 0, !list.items.isEmpty
        else { return nil }
        return list.removing(at: list.items.count - 1, in: source)
    }

    /// A space typed after a tag ends it, as Obsidian's tag field does.
    public static func tagEndedBySpace(selection: NSRange, in source: String) -> MarkdownEditing.Edit? {
        guard let list = PropertyListContext.detect(in: source, selection: selection),
              ["tags", "tag"].contains(list.key.lowercased())
        else { return nil }
        let typed = (source as NSString).substring(with: list.pending)
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return list.adding(typed, in: source)
    }

    /// Tab with an item typed after a list's pills makes it a pill.
    public static func itemAddedByTab(selection: NSRange, in source: String) -> MarkdownEditing.Edit? {
        guard let list = PropertyListContext.detect(in: source, selection: selection) else { return nil }
        let typed = (source as NSString).substring(with: list.pending)
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return list.adding(typed, in: source)
    }

    /// Return on a list's key line: what was typed becomes its last item;
    /// with nothing typed, a new property starts under the list.
    public static func listReturn(selection: NSRange, in source: String) -> (edit: MarkdownEditing.Edit, name: String)? {
        guard let list = PropertyListContext.detect(in: source, selection: selection) else { return nil }
        let typed = (source as NSString).substring(with: list.pending).trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return (list.adding(typed, in: source), "Add Item") }
        let end = list.items.last.map { NSMaxRange($0.line) } ?? NSMaxRange(list.keyLine)
        return (MarkdownEditing.Edit(
            range: NSRange(location: end, length: 0), replacement: "\n",
            selection: NSRange(location: end + 1, length: 0)
        ), "Add Property")
    }

    /// Tab after a key goes on to its value, as in Obsidian: it writes the
    /// `: ` the table hides.
    public static func movingToValue(selection: NSRange, in source: String) -> MarkdownEditing.Edit? {
        guard let context = PropertyCompletionContext.detect(in: source, selection: selection),
              context.part == .key
        else { return nil }
        let at = NSMaxRange(context.queryRange)
        return MarkdownEditing.Edit(
            range: NSRange(location: at, length: 0), replacement: ": ",
            selection: NSRange(location: at + 2, length: 0)
        )
    }

    // MARK: Whole properties

    /// The property at the caret deleted, list and all, as ⌘⌫ does in
    /// Obsidian; the last one takes the fences with it. The caret goes to
    /// the next property's value, or the one before when it was the last.
    public static func deletingProperty(at caret: Int, in source: String) -> MarkdownEditing.Edit? {
        let rows = PropertyEditing.rows(in: source)
        guard let row = rows.first(where: { NSLocationInRange(caret, $0.range) }),
              let block = PropertyEditing.blockRange(in: source)
        else { return nil }
        let range = rows.count == 1 ? block : row.range
        let result = (source as NSString).replacingCharacters(in: range, with: "")
        let remaining = PropertyEditing.rows(in: result)
        let next = remaining.first(where: { $0.range.location >= range.location }) ?? remaining.last
        return MarkdownEditing.Edit(
            range: range, replacement: "",
            selection: NSRange(location: next?.valueEnd ?? min(range.location, (result as NSString).length), length: 0)
        )
    }

    /// The property at `start` removed; the last one takes the fences.
    public static func removingProperty(atLineAt start: Int, in source: String) -> MarkdownEditing.Edit? {
        let rows = PropertyEditing.rows(in: source)
        guard let row = rows.first(where: { $0.range.location == start }),
              let block = PropertyEditing.blockRange(in: source)
        else { return nil }
        return MarkdownEditing.Edit(
            range: rows.count == 1 ? block : row.range, replacement: "", selection: NSRange(location: start, length: 0)
        )
    }

    /// The property at `start`, key line and items, as its lines.
    public static func propertyText(atLineAt start: Int, in source: String) -> (range: NSRange, text: String)? {
        guard let row = row(startingAt: start, in: source) else { return nil }
        return (row.range, (source as NSString).substring(with: row.range))
    }

    /// `text` as properties to paste, when every line of it is a key line
    /// or a list item under one, so pasting keeps the block YAML.
    public static func pastableProperties(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var text = text
        if !text.hasSuffix("\n") { text += "\n" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.first != " ", first.first != "-",
              lines.allSatisfy({ line in
                  let trimmed = line.trimmingCharacters(in: .whitespaces)
                  return trimmed.hasPrefix("- ") || trimmed == "-"
                      || (line.first != " " && line.first != "\t" && line.contains(":") && !trimmed.hasPrefix("#"))
              })
        else { return nil }
        return text
    }

    /// Pasted properties, after the property at `start`.
    public static func pasting(_ text: String, afterLineAt start: Int, in source: String) -> MarkdownEditing.Edit? {
        guard let property = propertyText(atLineAt: start, in: source), let pasted = pastableProperties(text) else { return nil }
        let at = NSMaxRange(property.range)
        return MarkdownEditing.Edit(range: NSRange(location: at, length: 0), replacement: pasted, selection: NSRange(location: at, length: 0))
    }

    /// What Obsidian would warn of on the row at `start`.
    public static func issue(forLineAt start: Int, in source: String, types: [String: PropertyType]) -> String? {
        guard let row = row(startingAt: start, in: source),
              let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd)
        else { return nil }
        let text = source as NSString
        let key = text.substring(with: NSRange(location: start, length: gap.keyEnd - start)).trimmingCharacters(in: .whitespaces)
        let value = text.substring(with: NSRange(location: gap.valueStart, length: row.valueEnd - gap.valueStart))
        let items = PropertyListContext.detect(in: source, selection: NSRange(location: row.valueEnd, length: 0))?.items.map(\.value) ?? []
        return PropertyRules.issue(key: key, value: value, items: items, type: PropertyTypes.type(of: key, in: types))
    }

    /// Why the row at `start` is red, in words: a key written twice first,
    /// since then Obsidian reads none of the properties.
    public static func warning(forLineAt start: Int, in source: String, types: [String: PropertyType]) -> String? {
        guard let key = key(onLineAt: start, in: source) else { return nil }
        return PropertyEditing.keys(in: source).filter({ $0 == key }).count > 1
            ? "\u{201C}\(key)\u{201D} is there twice, so Obsidian can\u{2019}t read these properties"
            : issue(forLineAt: start, in: source, types: types)
    }

    /// Every row tidied as `PropertyRules` asks, last first so each edit's
    /// range still holds when it is made.
    public static func tidyingAll(in source: String) -> [MarkdownEditing.Edit] {
        var current = source
        var edits: [MarkdownEditing.Edit] = []
        for row in PropertyEditing.rows(in: source).reversed() {
            guard let edit = PropertyRules.tidying(row, in: current) else { continue }
            edits.append(edit)
            current = (current as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        return edits
    }

    /// Add Property: the row a new key is typed into. An empty row already
    /// waiting is it (no edit); otherwise a new line before the closing
    /// fence, or a whole block when the note has none.
    public static func addingProperty(in source: String) -> (edit: MarkdownEditing.Edit?, caret: Int) {
        let text = source as NSString
        if let blank = PropertyEditing.rows(in: source).last(where: {
            text.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return (nil, blank.range.location)
        }
        if let block = PropertyEditing.blockRange(in: source) {
            let closing = text.lineRange(for: NSRange(location: max(NSMaxRange(block) - 1, 0), length: 0))
            let newline = text.substring(with: closing).hasSuffix("\r\n") ? "\r\n" : "\n"
            return (MarkdownEditing.Edit(
                range: NSRange(location: closing.location, length: 0), replacement: newline,
                selection: NSRange(location: closing.location, length: 0)
            ), closing.location)
        }
        return (MarkdownEditing.Edit(
            range: NSRange(location: 0, length: 0), replacement: "---\n\n---\n", selection: NSRange(location: 4, length: 0)
        ), 4)
    }

    // MARK: What leaving a row does

    /// An empty value, or a list's place for its next item, with the caret
    /// at it: its key line's start, and whether it has its space yet. Not
    /// at the key's end, which is the key's.
    public static func emptyValueLine(at location: Int, in source: String, normal: Bool) -> (lineStart: Int, spaced: Bool)? {
        guard let row = row(at: location, in: source),
              let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd),
              gap.valueStart == row.valueEnd,
              location == row.valueEnd || (normal && location == row.valueEnd - 1 && location >= gap.keyEnd)
        else { return nil }
        return (row.range.location, gap.valueStart > gap.keyEnd + 1)
    }

    /// The space an empty value's colon is given while the caret is in it:
    /// the column's gap is a kern on the colon, and a kern on a line's last
    /// character takes no effect, so with nothing after the colon the caret
    /// was drawn against the key. The caret goes after it, or in Normal
    /// mode on it.
    public static func spacingValue(onLineAt start: Int, caret: Int, normal: Bool, in source: String) -> MarkdownEditing.Edit? {
        guard let row = row(startingAt: start, in: source),
              let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd),
              gap.valueStart == gap.keyEnd + 1, gap.valueStart == row.valueEnd,
              caret == row.valueEnd || caret == gap.keyEnd
        else { return nil }
        let at = gap.valueStart
        return MarkdownEditing.Edit(
            range: NSRange(location: at, length: 0), replacement: " ",
            selection: NSRange(location: normal ? at : at + 1, length: 0)
        )
    }

    /// That space taken back from a value left empty.
    public static func unspacingValue(onLineAt start: Int, in source: String) -> NSRange? {
        guard let row = row(startingAt: start, in: source),
              let gap = PropertyEditing.colonGap(in: source, at: row.valueEnd),
              gap.valueStart == row.valueEnd, gap.valueStart > gap.keyEnd + 1
        else { return nil }
        return NSRange(location: gap.keyEnd + 1, length: gap.valueStart - gap.keyEnd - 1)
    }

    /// The blank row the caret is on, by where it starts.
    public static func blankRow(at caret: Int, in source: String) -> Int? {
        let text = source as NSString
        return PropertyEditing.rows(in: source).first {
            NSLocationInRange(caret, $0.range) || caret == $0.valueEnd
        }.flatMap { row in
            text.substring(with: row.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? row.range.location : nil
        }
    }

    /// A blank row the caret has left, removed, as Obsidian drops a new
    /// property left without a name; the last row takes the fences.
    public static func removingBlankRow(at start: Int, caret: Int, in source: String) -> NSRange? {
        let rows = PropertyEditing.rows(in: source)
        let text = source as NSString
        guard let row = rows.first(where: { $0.range.location == start }),
              text.substring(with: row.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !NSLocationInRange(caret, row.range),
              let block = PropertyEditing.blockRange(in: source)
        else { return nil }
        return rows.count == 1 ? block : row.range
    }

    /// The text typed on a list's key line made its last item, once the
    /// caret has left: left there it would be a value and a list at once.
    public static func committingTypedItem(onKeyLineAt start: Int, in source: String) -> MarkdownEditing.Edit? {
        guard let row = row(startingAt: start, in: source),
              let list = PropertyListContext.detect(in: source, selection: NSRange(location: row.valueEnd, length: 0))
        else { return nil }
        let typed = (source as NSString).substring(with: list.pending).trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        return list.adding(typed, in: source)
    }

    /// The row at `start` made YAML once the caret is off it.
    public static func tidyingRow(at start: Int, caret: Int, in source: String) -> MarkdownEditing.Edit? {
        guard let row = row(startingAt: start, in: source),
              !(caret >= row.range.location && caret <= row.valueEnd)
        else { return nil }
        return PropertyRules.tidying(row, in: source)
    }
}

/// Which rows the caret was last on, so that leaving one tidies it: a blank
/// row goes, an empty value loses the space it was given, a key gets its
/// colon, and an item typed after a list's pills becomes one. Each editor
/// keeps one and calls `caretMoved` on every selection change, then carries
/// out what it answers a moment later, when the selection has settled.
public struct PropertyLeaving: Sendable {
    public enum Action: Equatable, Sendable {
        case removeBlankRow(Int)
        case unspaceValue(Int)
        case spaceValue(Int)
        case tidyRow(Int)
        case commitItem(Int)
    }

    /// The blank row the caret is on.
    public var blankRow: Int?
    /// The key line given a space after its colon, to take back.
    public var spacedValueLine: Int?
    /// A key line holding only its key, to give its colon.
    public var bareKeyLine: Int?
    /// The list key line being typed into.
    public var listKeyLine: Int?

    public init() {}

    /// What the caret's move to `selection` leaves to do. `canSpace` is
    /// false while a click is still tracked, when no space may be written;
    /// `asText` is true while the properties show as YAML, where an empty
    /// value needs no space for the caret.
    public mutating func caretMoved(
        to selection: NSRange, in source: String, normal: Bool, canSpace: Bool = true, asText: Bool = false
    ) -> [Action] {
        var actions: [Action] = []
        // A blank row left.
        let onBlank = PropertySurface.blankRow(at: selection.location, in: source)
        if let start = blankRow, start != onBlank, selection.length == 0 { actions.append(.removeBlankRow(start)) }
        blankRow = onBlank
        // An empty value left loses its space; one arrived in gets it.
        if selection.length == 0, !asText {
            let here = PropertySurface.emptyValueLine(at: selection.location, in: source, normal: normal)
            if let start = spacedValueLine, start != here?.lineStart {
                spacedValueLine = nil
                actions.append(.unspaceValue(start))
            }
            if let here, !here.spaced, canSpace { actions.append(.spaceValue(here.lineStart)) }
        }
        // A key left without its colon.
        let row = PropertySurface.row(at: selection.location, in: source)
        if let start = bareKeyLine, start != row?.range.location { actions.append(.tidyRow(start)) }
        bareKeyLine = row?.range.location
        // An item typed after a list's pills, left.
        let editing = PropertyListContext.detect(in: source, selection: selection)?.keyLine.location
        if let start = listKeyLine, start != editing { actions.append(.commitItem(start)) }
        listKeyLine = editing
        return actions
    }
}
