import Foundation

/// Where a caret sits inside a drawn table.
///
/// The editor never rewrites a table to edit it: the buffer still holds the
/// pipes, and this is the translation between "offset 214 in the document" and
/// "the second cell of the third row, three characters in", which is what the
/// grid needs in order to draw the caret in the right box.
public struct TableCursor: Equatable, Sendable {
    /// Index into `TableLayout.rows`; 0 is the header. The delimiter row has
    /// no index, because a caret on it has no cell to be in.
    public let row: Int
    public let column: Int
    /// UTF-16 offset within that cell's source text.
    public let offset: Int
    /// The selection inside the cell, relative to its start. Length 0 for a
    /// plain caret.
    public let selection: NSRange

    public init(row: Int, column: Int, offset: Int, selection: NSRange) {
        self.row = row
        self.column = column
        self.offset = offset
        self.selection = selection
    }
}

extension TableLayout {

    /// Which cell a document selection lands in, or nil when there is no one
    /// cell it belongs to.
    ///
    /// Nil has two causes and they mean the same thing to the editor — show
    /// the table as plain source: the caret is on the delimiter row, which has
    /// no editable content, or the selection spans more than one cell, where
    /// there is nothing sensible to draw a single active box around.
    public func cursor(for selection: NSRange, tableStart: Int) -> TableCursor? {
        guard selection.location != NSNotFound, !cellRanges.isEmpty else { return nil }
        let start = selection.location - tableStart
        let end = start + selection.length
        guard start >= 0, end <= sourceLength else { return nil }

        if delimiterRange.location != NSNotFound,
           start >= delimiterRange.location, start <= NSMaxRange(delimiterRange) {
            return nil
        }

        guard let row = rowRanges.firstIndex(where: {
            start >= $0.location && start <= NSMaxRange($0)
        }) else { return nil }
        guard row < cellRanges.count, !cellRanges[row].isEmpty else { return nil }

        let cells = cellRanges[row]
        let rowEnd = NSMaxRange(rowRanges[row])
        var column = cells.count - 1
        for (index, cell) in cells.enumerated() {
            let next = index + 1 < cells.count ? cells[index + 1].location : rowEnd
            // The pipe and its padding belong to whichever cell they are
            // nearer, so clicking just past a word stays in that word's box.
            let boundary = NSMaxRange(cell) + (next - NSMaxRange(cell)) / 2
            if start <= boundary {
                column = index
                break
            }
        }

        let cell = cells[column]
        let offset = min(max(0, start - cell.location), cell.length)
        guard selection.length == 0 else {
            guard end >= cell.location, end <= NSMaxRange(cell) else { return nil }
            return TableCursor(
                row: row, column: column, offset: offset,
                selection: NSRange(location: offset, length: end - cell.location - offset)
            )
        }
        return TableCursor(
            row: row, column: column, offset: offset,
            selection: NSRange(location: offset, length: 0)
        )
    }

    /// The document range of one cell's source.
    public func range(ofRow row: Int, column: Int, tableStart: Int) -> NSRange? {
        guard row >= 0, row < cellRanges.count,
              column >= 0, column < cellRanges[row].count
        else { return nil }
        let cell = cellRanges[row][column]
        return NSRange(location: cell.location + tableStart, length: cell.length)
    }
}

/// Structural edits to a GFM table: rows and columns in and out, and the cell
/// walk that Tab and Return perform.
///
/// Pure, like `MarkdownEditing`: source and a caret in, a replacement and where
/// the selection ends up out. None of it needs a text view, so all of it is
/// testable — which matters here more than usual, because the interesting cases
/// (the last cell, the header, a ragged row) are exactly the ones that are
/// tedious to reach by hand in the GUI.
public enum TableEditing {

    /// One table command's effect. `replace` is nil when only the selection
    /// moves, so tabbing between existing cells puts nothing on the undo stack.
    public struct Action: Equatable, Sendable {
        public let replace: NSRange?
        public let replacement: String
        public let selection: NSRange

        public init(replace: NSRange?, replacement: String, selection: NSRange) {
            self.replace = replace
            self.replacement = replacement
            self.selection = selection
        }

        public static func move(to selection: NSRange) -> Action {
            Action(replace: nil, replacement: "", selection: selection)
        }
    }

    // MARK: - Walking cells

    /// The cell after `cursor`, wrapping to the next row and growing the table
    /// by one row past the last cell, the way Tab does in every other editor
    /// with tables.
    /// How many newlines a block needs before it at `offset`: none at the
    /// start of an empty line, one to finish the current line, two to leave a
    /// blank line after prose. A table only parses as one when it begins a
    /// line, so one asked for mid-paragraph would otherwise stay prose.
    public static func newlinesNeededForBlock(in text: NSString, at offset: Int) -> Int {
        let caret = max(0, min(offset, text.length))
        guard caret > 0 else { return 0 }
        if caret >= 2, text.substring(with: NSRange(location: caret - 2, length: 2)) == "\n\n" {
            return 0
        }
        if text.substring(with: NSRange(location: caret - 1, length: 1)) == "\n" { return 1 }
        return 2
    }

    /// A blank table to start from, and where the caret goes inside it.
    ///
    /// Written in the canonical `| a | b |` form the column operations already
    /// produce, so a table made this way and a table grown by adding a column
    /// are the same shape. The caret lands in the first header cell, because
    /// that is the cell the user is about to name.
    ///
    /// `newlinesBefore` keeps a table off the end of a line of prose: a table
    /// only parses as one when it starts a line, and one typed after text
    /// would silently stay text.
    public static func blankTable(
        rows: Int, columns: Int, newlinesBefore: Int
    ) -> (text: String, caretOffset: Int) {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let lead = String(repeating: "\n", count: max(0, newlinesBefore))
        let header = "| " + (0..<columns).map { _ in "   " }.joined(separator: " | ") + " |"
        let divider = "| " + (0..<columns).map { _ in "---" }.joined(separator: " | ") + " |"
        let body = (0..<rows).map { _ in header }.joined(separator: "\n")
        let text = lead + header + "\n" + divider + "\n" + body + "\n"
        // Just inside the first header cell, past "| ".
        return (text, lead.count + 2)
    }

    public static func nextCell(
        in table: TableLayout, from cursor: TableCursor, tableStart: Int
    ) -> Action? {
        let cells = table.cellRanges[cursor.row]
        if cursor.column + 1 < cells.count {
            return select(table, cursor.row, cursor.column + 1, tableStart)
        }
        if cursor.row + 1 < table.cellRanges.count {
            return select(table, cursor.row + 1, 0, tableStart)
        }
        return appendRow(to: table, tableStart: tableStart)
    }

    /// The cell before `cursor`. Stops at the first header cell rather than
    /// leaving the table: Shift-Tab out of a table has no obvious destination,
    /// and staying put is the least surprising thing to do.
    public static func previousCell(
        in table: TableLayout, from cursor: TableCursor, tableStart: Int
    ) -> Action? {
        if cursor.column > 0 {
            return select(table, cursor.row, cursor.column - 1, tableStart)
        }
        guard cursor.row > 0 else { return nil }
        let previous = cursor.row - 1
        return select(table, previous, max(0, table.cellRanges[previous].count - 1), tableStart)
    }

    /// The same column one row up, or nil at the header, where the caret
    /// should leave the table rather than land on the delimiter line.
    public static func cellAbove(
        in table: TableLayout, from cursor: TableCursor, tableStart: Int
    ) -> Action? {
        let previous = cursor.row - 1
        guard previous >= 0, previous < table.cellRanges.count else { return nil }
        let column = min(cursor.column, max(0, table.cellRanges[previous].count - 1))
        return select(table, previous, column, tableStart)
    }

    /// The same column one row down, adding a row when there is none. This is
    /// what Return does inside a table; the alternative — a literal newline —
    /// splits the table in two, which is never what was meant.
    public static func cellBelow(
        in table: TableLayout, from cursor: TableCursor, tableStart: Int
    ) -> Action? {
        let next = cursor.row + 1
        guard next < table.cellRanges.count else {
            return appendRow(to: table, tableStart: tableStart, column: cursor.column)
        }
        let column = min(cursor.column, max(0, table.cellRanges[next].count - 1))
        return select(table, next, column, tableStart)
    }

    private static func select(
        _ table: TableLayout, _ row: Int, _ column: Int, _ tableStart: Int
    ) -> Action? {
        // Selecting the cell's whole text, not just placing a caret in it, so
        // that tabbing through a table and typing replaces each cell the way
        // tabbing through a form does.
        table.range(ofRow: row, column: column, tableStart: tableStart).map(Action.move(to:))
    }

    // MARK: - Rows

    /// A blank row inserted after `row`, with the caret in its first cell.
    /// `row` is an index into `TableLayout.rows`, so 0 is the header and the
    /// new line lands below the delimiter, not above it.
    public static func insertRow(
        in table: TableLayout, after row: Int, tableStart: Int, column: Int = 0
    ) -> Action? {
        let columns = max(1, table.columnCount)
        guard row >= 0, row < table.rowRanges.count else { return nil }
        var insertion = NSMaxRange(table.rowRanges[row])
        if row == 0, table.delimiterRange.location != NSNotFound {
            insertion = max(insertion, NSMaxRange(table.delimiterRange))
        }
        let line = blankRow(columns: columns)
        let target = min(column, columns - 1)
        return Action(
            replace: NSRange(location: tableStart + insertion, length: 0),
            replacement: "\n" + line,
            // One for the newline, then the cell's own offset inside the row.
            selection: NSRange(
                location: tableStart + insertion + 1 + cellOffset(inBlankRow: target),
                length: 0
            )
        )
    }

    private static func appendRow(
        to table: TableLayout, tableStart: Int, column: Int = 0
    ) -> Action? {
        insertRow(in: table, after: table.rowRanges.count - 1, tableStart: tableStart, column: column)
    }

    /// Removes `row`. The header row is refused: a table without one is not a
    /// table, and silently taking the whole construct away is not what
    /// "delete row" reads as.
    public static func deleteRow(
        in table: TableLayout, at row: Int, tableStart: Int
    ) -> Action? {
        guard row > 0, row < table.rowRanges.count else { return nil }
        let line = table.rowRanges[row]
        // Take the newline in front of the line, so the row above keeps its own.
        let start = max(0, line.location - 1)
        let removed = NSMaxRange(line) - start

        // The caret goes into whatever row takes this one's place, or into the
        // row above when there is none. Leaving it where the deleted line was
        // would drop it on the delimiter row, and the whole table would fall
        // back to plain source the moment a row was removed.
        var target: NSRange
        if row + 1 < table.cellRanges.count, let next = table.cellRanges[row + 1].first {
            target = NSRange(location: next.location - removed, length: next.length)
        } else if let previous = table.cellRanges[row - 1].first {
            target = previous
        } else {
            target = NSRange(location: start, length: 0)
        }
        return Action(
            replace: NSRange(location: tableStart + start, length: removed),
            replacement: "",
            selection: NSRange(location: tableStart + target.location, length: target.length)
        )
    }

    private static func blankRow(columns: Int) -> String {
        "|" + String(repeating: "  |", count: columns)
    }

    /// Where the caret goes in a cell of `blankRow`: past that many `  |`
    /// groups, then one space in.
    private static func cellOffset(inBlankRow column: Int) -> Int {
        1 + column * 3
    }

    // MARK: - Columns

    /// A blank column inserted after `column`, with the caret in its header.
    ///
    /// Unlike a row, this rewrites the whole table into canonical `| a | b |`
    /// form. Splicing a cell into each line instead would preserve hand-aligned
    /// padding, but the padding no longer lines up once a column has been added
    /// anyway, so the tidier result is also the more honest one.
    public static func insertColumn(
        in table: TableLayout, after column: Int, tableStart: Int
    ) -> Action? {
        let columns = max(1, table.columnCount)
        let at = min(max(0, column + 1), columns)
        var rows = padded(table)
        for index in rows.indices { rows[index].insert("", at: at) }
        var alignments = padded(table.alignments, to: columns)
        alignments.insert(.leading, at: at)
        return rewrite(table, rows: rows, alignments: alignments, tableStart: tableStart, caret: (0, at))
    }

    /// Removes `column` everywhere, including from the delimiter row. A table
    /// has to keep one column, so the last one cannot be deleted this way.
    public static func deleteColumn(
        in table: TableLayout, at column: Int, tableStart: Int
    ) -> Action? {
        let columns = table.columnCount
        guard columns > 1, column >= 0, column < columns else { return nil }
        var rows = padded(table)
        for index in rows.indices { rows[index].remove(at: column) }
        var alignments = padded(table.alignments, to: columns)
        alignments.remove(at: column)
        return rewrite(
            table, rows: rows, alignments: alignments, tableStart: tableStart,
            caret: (0, min(column, columns - 2))
        )
    }

    /// Rows as a rectangle. A ragged table is legal markdown and common in the
    /// wild, and a column operation has to have something to act on in every
    /// row.
    private static func padded(_ table: TableLayout) -> [[String]] {
        let columns = max(1, table.columnCount)
        return table.rawRows.map { padded($0, to: columns) }
    }

    private static func padded<Element>(
        _ row: [Element], to count: Int, filling filler: Element
    ) -> [Element] {
        row.count >= count ? Array(row.prefix(count)) : row + Array(repeating: filler, count: count - row.count)
    }

    private static func padded(_ row: [String], to count: Int) -> [String] {
        padded(row, to: count, filling: "")
    }

    private static func padded(_ row: [MDColumnAlignment], to count: Int) -> [MDColumnAlignment] {
        padded(row, to: count, filling: .leading)
    }

    private static func rewrite(
        _ table: TableLayout,
        rows: [[String]],
        alignments: [MDColumnAlignment],
        tableStart: Int,
        caret: (row: Int, column: Int)
    ) -> Action? {
        guard !rows.isEmpty else { return nil }
        let source = render(rows: rows, alignments: alignments)
        guard let rendered = LiveDecorator.parseTable(source),
              let cell = rendered.range(ofRow: caret.row, column: caret.column, tableStart: tableStart)
        else { return nil }
        return Action(
            replace: NSRange(location: tableStart, length: table.sourceLength),
            replacement: source,
            selection: cell
        )
    }

    /// Canonical `| a | b |` source for a table, delimiter row included.
    public static func render(rows: [[String]], alignments: [MDColumnAlignment]) -> String {
        guard let header = rows.first else { return "" }
        let columns = max(header.count, alignments.count)
        func line(_ cells: [String]) -> String {
            "| " + padded(cells, to: columns).joined(separator: " | ") + " |"
        }
        let delimiter = padded(alignments, to: columns).map { alignment in
            switch alignment {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        return ([line(header), line(delimiter)] + rows.dropFirst().map(line))
            .joined(separator: "\n")
    }
}
