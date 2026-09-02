import AppKit
import Foundation
@testable import HeftCore
@testable import Heft

/// Drives the real `HeftTextKit2View` and coordinator over a table.
///
/// `TableCheck` proves the arithmetic; this proves the surface actually uses
/// it. Everything here is a claim about behaviour that is only observable once
/// the editor is assembled: that a click on a drawn cell lands the caret in
/// that cell's source rather than at the table's left edge, that the grid stays
/// a grid while it is being typed into, and that Tab and the `+` strips edit
/// the file rather than the picture of it.
@MainActor
enum TableSurfaceCheck {

    static let document = """
    Before the table.

    | Engine | Throughput | Notes |
    | --- | ---: | :---: |
    | SGLang FP8 | ~112 t/s | **fast** |
    | vLLM FP8 | 115.1 t/s | `stable` |

    After the table.
    """

    static func run() -> SelfCheck.Result {
        var r = SelfCheck.Result()

        func expectTrue(_ condition: Bool, _ label: String) {
            if condition { r.passed += 1 } else { r.failures.append(label) }
        }
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual == expected { r.passed += 1 }
            else { r.failures.append("\(label): expected \(expected), got \(actual)") }
        }

        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "probe.md", generation: 0, generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = document
        coordinator.restyle(view)

        guard let table = view.liveLayout.tables.first else {
            r.failures.append("no table widget in the layout")
            return r
        }
        expect(view.liveLayout.tables.count, 1, "one table in the note")
        expect(
            table.documentStart, (document as NSString).range(of: "| Engine").location,
            "the grid knows where its source starts"
        )
        expect(table.layout.rows.count, 3, "header plus two body rows")

        guard let origin = view.tableOrigin(of: table) else {
            r.failures.append("the table has no laid-out origin")
            return r
        }
        expectTrue(origin.y > 0, "the table is laid out below the paragraph above it")

        func click(_ point: CGPoint, clicks: Int = 1, shift: Bool = false) -> Bool {
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero,
                modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
            return view.handleTableClick(at: point, event: event)
        }

        // MARK: A click lands in the cell it was aimed at

        // Every cell, so a mistake in the column walk cannot hide behind one
        // that happens to be right. The grid is re-read before each click:
        // showing a cell's markers can make its row taller, which moves the
        // rows below it, so geometry from before the last click is stale.
        for target in table.cells.map({ ($0.row, $0.column) }) {
            guard let grid = view.liveLayout.tables.first,
                  let live = view.tableOrigin(of: grid),
                  let cell = grid.cell(row: target.0, column: target.1),
                  cell.source.location != NSNotFound
            else { continue }
            let centre = CGPoint(x: live.x + cell.rect.midX, y: live.y + cell.rect.midY)
            guard click(centre) else {
                r.failures.append("click on r\(cell.row)c\(cell.column) was not handled")
                continue
            }
            let caret = view.selectedRange().location
            let source = NSRange(
                location: grid.documentStart + cell.source.location, length: cell.source.length
            )
            expectTrue(
                caret >= source.location && caret <= NSMaxRange(source),
                "a click on r\(cell.row)c\(cell.column) lands in that cell"
                    + " (\(caret) outside \(source))"
            )
        }

        // MARK: The grid survives the caret

        let bodyCell = (document as NSString).range(of: "115.1 t/s")
        view.setSelectedRange(NSRange(location: bodyCell.location + 3, length: 0))
        coordinator.restyle(view)
        guard let active = view.liveLayout.tables.first else {
            r.failures.append("the table stopped being a widget once clicked")
            return r
        }
        expect(
            active.active, TableGrid.ActiveCell(row: 2, column: 1),
            "the clicked cell is the active one"
        )
        expectTrue(
            view.activeTable?.cursor.offset == 3,
            "the caret's offset inside the active cell"
        )

        // The whole point: the other cells are still rendered, so their drawn
        // text is the display form rather than raw markdown.
        if let bold = active.cell(row: 1, column: 2) {
            expect(bold.text.string, "**fast**", "an inactive cell keeps the source in the buffer")
            let hairline = bold.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            expectTrue(
                (hairline?.pointSize ?? 99) < 1,
                "an inactive cell's markers are collapsed, not deleted"
            )
        } else {
            r.failures.append("no cell r1c2")
        }
        if let activeCell = active.cell(row: 2, column: 2) {
            expect(activeCell.text.string, "`stable`", "cells carry their raw source")
        }

        // And the active cell shows its markers at full size.
        view.setSelectedRange(NSRange(
            location: (document as NSString).range(of: "**fast**").location + 3, length: 0
        ))
        coordinator.restyle(view)
        if let grid = view.liveLayout.tables.first,
           let cell = grid.cell(row: 1, column: 2) {
            expect(grid.active, TableGrid.ActiveCell(row: 1, column: 2), "active cell moved")
            let marker = cell.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            expectTrue(
                (marker?.pointSize ?? 0) > 1,
                "the active cell's markers are visible, not collapsed"
            )
            // The caret has to be drawable inside the cell it belongs to, and
            // has to *advance* with the offset. A loose "somewhere in the
            // cell" bound is not enough: a caret stuck at the cell's left edge
            // satisfies it, and that is exactly what a cell laid out against a
            // released text storage produces.
            let start = grid.caretRect(in: cell, offset: 0)
            let caret = grid.caretRect(in: cell, offset: 3)
            let end = grid.caretRect(in: cell, offset: cell.text.length)
            expectTrue(
                caret.minX >= cell.rect.minX - 1 && caret.minX <= cell.rect.maxX + 3,
                "the caret is drawn inside its cell horizontally (\(caret) in \(cell.rect))"
            )
            expectTrue(
                caret.minY >= cell.rect.minY - 2 && caret.maxY <= cell.rect.maxY + 6,
                "the caret is drawn inside its cell vertically (\(caret) in \(cell.rect))"
            )
            // Three characters of any font at this size are wider than 6pt.
            expectTrue(
                caret.minX - start.minX > 6,
                "the caret advances with the offset (\(start.minX) to \(caret.minX))"
            )
            expectTrue(
                end.minX > caret.minX,
                "the end of the cell is past the middle of it"
            )
            // And a selection has boxes to draw, covering most of the text.
            let rects = grid.selectionRects(
                in: cell, range: NSRange(location: 0, length: cell.text.length)
            )
            expectTrue(rects.count == 1, "a one-line selection is one box")
            expectTrue(
                (rects.first?.width ?? 0) >= end.minX - start.minX - 1,
                "the box covers the text it selects"
            )
        } else {
            r.failures.append("no active grid after moving into the bold cell")
        }

        // MARK: Typing goes into the file, not the picture

        view.setSelectedRange(NSRange(
            location: (document as NSString).range(of: "SGLang FP8").location + 10, length: 0
        ))
        coordinator.restyle(view)
        view.insertText("!", replacementRange: view.selectedRange())
        expectTrue(
            view.string.contains("| SGLang FP8! |"),
            "typing in a cell edits that cell's source"
        )
        expectTrue(
            view.liveLayout.tables.first?.layout.rows[1].first == "SGLang FP8!",
            "the grid re-measures with the typed text"
        )
        view.deleteBackward(nil)
        expect(view.string, document, "backspace puts it back")

        // MARK: Tab, Shift-Tab and Return

        coordinator.restyle(view)
        let engineCell = (document as NSString).range(of: "SGLang FP8")
        view.setSelectedRange(NSRange(location: engineCell.location, length: 0))
        coordinator.restyle(view)
        view.insertTab(nil)
        expect(
            (view.string as NSString).substring(with: view.selectedRange()), "~112 t/s",
            "Tab selects the next cell"
        )
        view.insertBacktab(nil)
        expect(
            (view.string as NSString).substring(with: view.selectedRange()), "SGLang FP8",
            "Shift-Tab comes back"
        )
        view.insertNewline(nil)
        expect(
            (view.string as NSString).substring(with: view.selectedRange()), "vLLM FP8",
            "Return drops a row in the same column"
        )

        // Tab out of the last cell grows the table rather than leaving it.
        let lastCell = (view.string as NSString).range(of: "`stable`")
        view.setSelectedRange(NSRange(location: NSMaxRange(lastCell), length: 0))
        coordinator.restyle(view)
        view.insertTab(nil)
        expectTrue(
            view.string.hasSuffix("|  |  |  |\n\nAfter the table.")
                || view.string.contains("|  |  |  |"),
            "Tab past the last cell appends a blank row"
        )
        expect(
            view.liveLayout.tables.first?.layout.rows.count, 4,
            "the appended row is part of the table"
        )
        expect(
            view.activeTable?.cursor.row, 3,
            "the caret follows into the new row"
        )

        // MARK: The + strips

        view.string = document
        coordinator.restyle(view)
        guard let fresh = view.liveLayout.tables.first,
              let freshOrigin = view.tableOrigin(of: fresh)
        else {
            r.failures.append("the table did not come back after resetting the document")
            return r
        }
        let addRow = fresh.addRowRect
        expectTrue(
            click(CGPoint(x: freshOrigin.x + addRow.midX, y: freshOrigin.y + addRow.midY)),
            "the add-row strip takes the click"
        )
        expect(
            view.liveLayout.tables.first?.layout.rows.count, 4,
            "the add-row strip adds a row"
        )

        view.string = document
        coordinator.restyle(view)
        guard let second = view.liveLayout.tables.first,
              let secondOrigin = view.tableOrigin(of: second)
        else {
            r.failures.append("the table did not come back for the column check")
            return r
        }
        let addColumn = second.addColumnRect
        expectTrue(
            click(CGPoint(x: secondOrigin.x + addColumn.midX, y: secondOrigin.y + addColumn.midY)),
            "the add-column strip takes the click"
        )
        expect(
            view.liveLayout.tables.first?.layout.columnCount, 4,
            "the add-column strip adds a column"
        )
        expectTrue(
            LiveDecorator.parseTable(
                (view.string as NSString).substring(with: NSRange(
                    location: second.documentStart,
                    length: (view.liveLayout.tables.first?.sourceLength ?? 0)
                ))
            ) != nil,
            "the table is still well formed after gaining a column"
        )

        // MARK: Arrow keys move between rows, not between lines

        view.string = document
        coordinator.restyle(view)
        view.setSelectedRange(NSRange(
            location: (document as NSString).range(of: "Throughput").location + 2, length: 0
        ))
        coordinator.restyle(view)
        expectTrue(view.handleTableVerticalMove(down: true), "down from the header is handled")
        expect(view.activeTable?.cursor.row, 1, "down from the header skips the delimiter row")
        expect(view.activeTable?.cursor.column, 1, "and keeps the column")
        expect(view.selectedRange().length, 0, "an arrow key leaves a caret, not a selection")

        expectTrue(view.handleTableVerticalMove(down: false), "up from a body row is handled")
        expect(view.activeTable?.cursor.row, 0, "up from the first body row reaches the header")
        expectTrue(
            !view.handleTableVerticalMove(down: false),
            "up from the header declines, so the caret leaves the table"
        )
        view.setSelectedRange(NSRange(
            location: (document as NSString).range(of: "115.1 t/s").location, length: 0
        ))
        coordinator.restyle(view)
        expectTrue(
            !view.handleTableVerticalMove(down: true),
            "down from the last row declines rather than growing the table"
        )

        // MARK: The row and column menu

        view.string = document
        coordinator.restyle(view)
        if let grid = view.liveLayout.tables.first,
           let menuOrigin = view.tableOrigin(of: grid),
           let cell = grid.cell(row: 1, column: 1) {
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            _ = event
            let menu = view.tableMenu(at: CGPoint(
                x: menuOrigin.x + cell.rect.midX, y: menuOrigin.y + cell.rect.midY
            ))
            expectTrue(menu != nil, "a table offers a row and column menu")
            expect(menu?.items.count, 7, "six commands and a separator")
            expectTrue(
                view.validatesTableCommand(#selector(HeftTextKit2View.deleteTableRow(_:))) == true,
                "a body row can be deleted"
            )
            view.deleteTableRow(nil)
            expectTrue(
                !view.string.contains("SGLang FP8"),
                "the menu deletes the row it was opened on"
            )
            expect(
                view.liveLayout.tables.first?.layout.rows.count, 2,
                "the table is one row shorter"
            )
        } else {
            r.failures.append("no grid for the menu check")
        }

        // The header cannot be deleted, and neither can the last column.
        view.string = document
        coordinator.restyle(view)
        if let grid = view.liveLayout.tables.first,
           let menuOrigin = view.tableOrigin(of: grid),
           let header = grid.cell(row: 0, column: 0) {
            _ = view.tableMenu(at: CGPoint(
                x: menuOrigin.x + header.rect.midX, y: menuOrigin.y + header.rect.midY
            ))
            expectTrue(
                view.validatesTableCommand(#selector(HeftTextKit2View.deleteTableRow(_:))) == false,
                "the header row is not deletable"
            )
            view.deleteTableColumn(nil)
            expect(
                view.liveLayout.tables.first?.layout.columnCount, 2,
                "the menu deletes the column it was opened on"
            )
        }

        // MARK: The caret is drawn where the cell is

        view.string = document
        coordinator.restyle(view)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(
            location: (document as NSString).range(of: "115.1 t/s").location + 3, length: 0
        ))
        coordinator.restyle(view)
        view.updateTableCaret()
        expectTrue(view.tableCaretIsActive, "the caret is the table's while it is in a cell")
        expectTrue(
            view.insertionPointColor == .clear,
            "and the native insertion point is switched off"
        )
        if let overlay = view.tableCaretOverlayIfLoaded,
           let grid = view.liveLayout.tables.first,
           let caretOrigin = view.tableOrigin(of: grid),
           let cell = grid.cell(row: 2, column: 1) {
            expectTrue(!overlay.isHidden, "the caret overlay is up")
            expect(overlay.frame.origin, caretOrigin, "the overlay sits on the grid")
            expect(overlay.frame.size, grid.size, "and covers it")
            let caret = grid.caretRect(in: cell, offset: 3)
            expectTrue(
                caret.minX > cell.rect.minX && caret.minX < cell.rect.maxX,
                "the caret is three characters into the cell, not at its edge"
            )
        } else {
            r.failures.append("no caret overlay for a caret inside a cell")
        }

        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle(view)
        view.updateTableCaret()
        expectTrue(!view.tableCaretIsActive, "leaving the table takes the drawn caret down")
        expectTrue(
            view.tableCaretOverlayIfLoaded?.isHidden == true,
            "and hides its overlay"
        )
        expectTrue(
            view.insertionPointColor != .clear,
            "and gives the native insertion point back"
        )
        window.contentView = nil

        // MARK: The delimiter row is the way back to plain source

        view.string = document
        coordinator.restyle(view)
        let delimiter = (document as NSString).range(of: "| --- | ---: | :---: |")
        view.setSelectedRange(NSRange(location: delimiter.location + 3, length: 0))
        coordinator.restyle(view)
        expectTrue(
            view.liveLayout.tables.isEmpty,
            "a caret on the delimiter row shows the table as source"
        )
        expectTrue(view.activeTable == nil, "and there is no cell to draw a caret in")

        return r
    }
}
