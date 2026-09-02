import Foundation
@testable import HeftCore

/// Assertions over the table parse and the structural edits built on it.
///
/// The in-place table editor rests entirely on one claim: `cellRanges[r][c]` is
/// exactly the span of the file that `rawRows[r][c]` was read from. Everything
/// else — the caret drawn inside a cell, Tab walking the row, a column being
/// added — is arithmetic on top of that, and gets it wrong silently if the
/// claim does not hold. So the first thing checked here is the claim itself,
/// against every table shape the vault actually contains.
public enum TableCheck {

    public static func run() -> SelfCheck.Result {
        var r = SelfCheck.Result()

        func expectTrue(_ condition: Bool, _ label: String) {
            if condition { r.passed += 1 } else { r.failures.append(label) }
        }
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual == expected { r.passed += 1 }
            else { r.failures.append("\(label): expected \(expected), got \(actual)") }
        }

        let simple = """
        | Name | Value |
        | --- | ---: |
        | a | 1 |
        | bb | 22 |
        """

        guard let table = LiveDecorator.parseTable(simple) else {
            r.failures.append("simple table did not parse")
            return r
        }

        expect(table.rows.count, 3, "row count includes the header, not the delimiter")
        expect(table.columnCount, 2, "column count")
        expect(table.alignments, [.leading, .trailing], "alignments from the delimiter row")

        // The load-bearing invariant, checked on every cell of every fixture.
        func checkRanges(_ source: String, _ layout: TableLayout, _ label: String) {
            let text = source as NSString
            for (rowIndex, row) in layout.rawRows.enumerated() {
                for (columnIndex, raw) in row.enumerated() {
                    let range = layout.cellRanges[rowIndex][columnIndex]
                    guard NSMaxRange(range) <= text.length else {
                        r.failures.append("\(label): cell \(rowIndex),\(columnIndex) out of bounds")
                        continue
                    }
                    expect(
                        text.substring(with: range), raw,
                        "\(label): cell \(rowIndex),\(columnIndex) range matches its text"
                    )
                }
            }
            expect(layout.sourceLength, text.length, "\(label): source length")
        }

        checkRanges(simple, table, "simple")

        // Ragged rows, blank cells, and a hand-aligned table are all legal and
        // all present in real vaults.
        let awkward = """
        |  Left   |   Right |  Third |
        |:--------|--------:|:------:|
        | one     |         |        |
        | two     | 2       |
        """
        guard let ragged = LiveDecorator.parseTable(awkward) else {
            r.failures.append("ragged table did not parse")
            return r
        }
        checkRanges(awkward, ragged, "ragged")
        expect(ragged.alignments, [.leading, .trailing, .center], "alignment markers")
        expect(ragged.rows[2].count, 2, "a short row keeps its own cell count")
        expectTrue(ragged.cellRanges[1][1].length == 0, "a blank cell has an empty range")
        // Typing into that blank cell has to land between the pipes, not on one.
        let blank = ragged.cellRanges[1][1].location
        expectTrue(
            (awkward as NSString).substring(
                with: NSRange(location: blank - 1, length: 2)
            ) == "  ",
            "a blank cell's caret sits inside its padding"
        )

        // Obsidian writes `\|` for a literal pipe. It must not split the cell,
        // and the raw text must stay the length of the range it came from.
        let escaped = """
        | Image | Note |
        | --- | --- |
        | ![[chart.png\\|500]] | ok |
        """
        guard let piped = LiveDecorator.parseTable(escaped) else {
            r.failures.append("escaped-pipe table did not parse")
            return r
        }
        checkRanges(escaped, piped, "escaped pipe")
        expect(piped.rows[1].count, 2, "an escaped pipe is not a cell boundary")
        expect(piped.rows[1][0], "![[chart.png|500]]", "display text unescapes the pipe")
        expect(piped.rawRows[1][0], "![[chart.png\\|500]]", "raw text keeps the escape")

        // MARK: Cursor mapping

        // Offsets are into `simple`, with the table starting at 100 in a
        // notional document, so an off-by-one in the shift shows up.
        let start = 100
        func cursor(at offset: Int, length: Int = 0) -> TableCursor? {
            table.cursor(
                for: NSRange(location: start + offset, length: length), tableStart: start
            )
        }

        let header = (simple as NSString).range(of: "Name")
        expect(cursor(at: header.location)?.row, 0, "caret at a header cell is row 0")
        expect(cursor(at: header.location)?.column, 0, "caret at a header cell is column 0")
        expect(cursor(at: header.location + 2)?.offset, 2, "offset inside the cell")

        // The leading pipe, the padding, and the trailing pipe all belong to a
        // cell: a click near a table's edge must not fall out of it.
        expect(cursor(at: 0)?.column, 0, "the leading pipe belongs to the first cell")
        let valueCell = (simple as NSString).range(of: "Value")
        expect(cursor(at: valueCell.location)?.column, 1, "second header cell")
        expect(
            cursor(at: NSMaxRange(valueCell) + 1)?.column, 1,
            "the trailing pipe belongs to the last cell"
        )

        // The delimiter row has no cell, which is the one place the table falls
        // back to plain source.
        expectTrue(
            cursor(at: table.delimiterRange.location + 2) == nil,
            "the delimiter row has no cursor"
        )

        // A selection spanning two cells has no single active cell either.
        expectTrue(
            cursor(at: header.location, length: 12) == nil,
            "a selection across cells has no cursor"
        )
        expect(
            cursor(at: header.location, length: 4)?.selection,
            NSRange(location: 0, length: 4),
            "a selection inside one cell survives"
        )

        // MARK: Reveal state

        let document = "Intro\n\n" + simple + "\n\nAfter\n"
        let decorations = LiveDecorator.decorations(in: document)
        guard let tableDecoration = decorations.first(where: {
            if case .table = $0.style { return true } else { return false }
        }) else {
            r.failures.append("no table decoration in the document")
            return r
        }
        let tableStart = tableDecoration.range.location
        let source = document as NSString

        func state(at offset: Int) -> RevealState {
            Reveal(selection: NSRange(location: offset, length: 0), in: source)
                .state(of: tableDecoration)
        }

        expect(state(at: 0), .hidden, "a caret outside the table hides its markup")
        expect(state(at: tableStart + 3), .cell(row: 0, column: 0), "a caret in the header")
        guard case .table(let parsed) = tableDecoration.style else {
            r.failures.append("table decoration carried no layout")
            return r
        }
        expect(
            state(at: tableStart + parsed.cellRanges[2][1].location),
            .cell(row: 2, column: 1),
            "a caret in the last cell"
        )
        expect(
            state(at: tableStart + parsed.delimiterRange.location + 1), .revealed,
            "a caret on the delimiter row reveals the whole table"
        )

        // MARK: Structural edits

        func apply(_ action: TableEditing.Action?, to text: String) -> String? {
            guard let action, let replace = action.replace else { return nil }
            let mutable = NSMutableString(string: text)
            mutable.replaceCharacters(in: replace, with: action.replacement)
            return mutable as String
        }

        let bodyCursor = TableCursor(
            row: 1, column: 0, offset: 0, selection: NSRange(location: 0, length: 0)
        )
        expect(
            apply(TableEditing.insertRow(in: table, after: 1, tableStart: 0), to: simple),
            """
            | Name | Value |
            | --- | ---: |
            | a | 1 |
            |  |  |
            | bb | 22 |
            """,
            "insert row after the first body row"
        )
        expect(
            apply(TableEditing.insertRow(in: table, after: 0, tableStart: 0), to: simple),
            """
            | Name | Value |
            | --- | ---: |
            |  |  |
            | a | 1 |
            | bb | 22 |
            """,
            "a row inserted after the header lands below the delimiter"
        )
        // The caret lands in the new row's first cell, not on a pipe.
        if let action = TableEditing.insertRow(in: table, after: 1, tableStart: 0),
           let updated = apply(action, to: simple) {
            expect(
                (updated as NSString).substring(
                    with: NSRange(location: action.selection.location - 1, length: 2)
                ),
                "| ",
                "the caret in a new row sits just inside the first cell"
            )
        } else {
            r.failures.append("insert row produced no edit")
        }

        expect(
            apply(TableEditing.deleteRow(in: table, at: 1, tableStart: 0), to: simple),
            """
            | Name | Value |
            | --- | ---: |
            | bb | 22 |
            """,
            "delete a body row"
        )
        // The caret has to land in a cell, not on the delimiter row the
        // deleted line used to sit under.
        if let action = TableEditing.deleteRow(in: table, at: 1, tableStart: 0),
           let updated = apply(action, to: simple) {
            expect(
                (updated as NSString).substring(with: action.selection), "bb",
                "deleting a row selects the row that takes its place"
            )
        }
        if let action = TableEditing.deleteRow(in: table, at: 2, tableStart: 0),
           let updated = apply(action, to: simple) {
            expect(
                (updated as NSString).substring(with: action.selection), "a",
                "deleting the last row falls back to the row above"
            )
        }
        expectTrue(
            TableEditing.deleteRow(in: table, at: 0, tableStart: 0) == nil,
            "the header row cannot be deleted on its own"
        )

        expect(
            apply(TableEditing.insertColumn(in: table, after: 0, tableStart: 0), to: simple),
            """
            | Name |  | Value |
            | --- | --- | ---: |
            | a |  | 1 |
            | bb |  | 22 |
            """,
            "insert a column, keeping the other columns' alignment"
        )
        expect(
            apply(TableEditing.deleteColumn(in: table, at: 1, tableStart: 0), to: simple),
            """
            | Name |
            | --- |
            | a |
            | bb |
            """,
            "delete a column"
        )
        expectTrue(
            TableEditing.deleteColumn(in: ragged, at: 0, tableStart: 0) != nil,
            "a ragged table can lose a column"
        )
        if let action = TableEditing.deleteColumn(in: ragged, at: 0, tableStart: 0),
           let updated = apply(action, to: awkward) {
            expectTrue(
                LiveDecorator.parseTable(updated)?.columnCount == 2,
                "a ragged table stays a table after losing a column"
            )
        }

        // MARK: Walking cells

        func move(_ action: TableEditing.Action?) -> String {
            guard let action else { return "<none>" }
            if let replace = action.replace {
                let mutable = NSMutableString(string: simple)
                mutable.replaceCharacters(in: replace, with: action.replacement)
                return (mutable as NSString).substring(with: action.selection)
            }
            return (simple as NSString).substring(with: action.selection)
        }

        expect(
            move(TableEditing.nextCell(in: table, from: bodyCursor, tableStart: 0)), "1",
            "Tab moves to the next cell and selects it"
        )
        let lastCell = TableCursor(
            row: 2, column: 1, offset: 0, selection: NSRange(location: 0, length: 0)
        )
        let grown = TableEditing.nextCell(in: table, from: lastCell, tableStart: 0)
        expectTrue(grown?.replace != nil, "Tab past the last cell adds a row")
        expect(
            apply(grown, to: simple),
            """
            | Name | Value |
            | --- | ---: |
            | a | 1 |
            | bb | 22 |
            |  |  |
            """,
            "the row Tab adds is blank and well formed"
        )
        expect(
            move(TableEditing.previousCell(in: table, from: bodyCursor, tableStart: 0)), "Value",
            "Shift-Tab from the first cell of a row wraps to the row above"
        )
        expectTrue(
            TableEditing.previousCell(
                in: table,
                from: TableCursor(row: 0, column: 0, offset: 0, selection: NSRange(location: 0, length: 0)),
                tableStart: 0
            ) == nil,
            "Shift-Tab in the first header cell stays put"
        )
        expect(
            move(TableEditing.cellBelow(in: table, from: bodyCursor, tableStart: 0)), "bb",
            "Return moves down a row in the same column"
        )

        return r
    }
}
