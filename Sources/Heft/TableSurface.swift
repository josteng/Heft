import AppKit
import HeftCore

/// Editing a table in place, without ever taking the grid off the screen.
///
/// Everywhere else in this editor the caret is TextKit's business: the source
/// is in the buffer, the buffer is laid out, and the insertion point falls out
/// of that. A table is the one construct where it cannot be, because the drawn
/// grid bears no relation to the line the source occupies — a four-row table is
/// one 150pt paragraph followed by three hairlines, and TextKit would put the
/// caret at the left edge of the first of them regardless of which cell is
/// being typed into.
///
/// So the caret inside a table is drawn here instead: an overlay view placed
/// from the measured grid, with the native insertion point switched off while
/// it is up. Everything it needs — which cell an offset is in, where in that
/// cell it sits — is arithmetic over `TableGrid`, and the document itself is
/// never touched to make any of it work. Typing goes into the real buffer at
/// the real offset, exactly as it does in prose.
extension HeftTextKit2View {

    /// The table the caret is in, with where the caret sits inside it.
    var activeTable: (grid: TableGrid, cursor: TableCursor)? {
        let selection = selectedRange()
        guard selection.location != NSNotFound,
              let grid = liveLayout.table(containing: selection.location),
              let cursor = grid.layout.cursor(for: selection, tableStart: grid.documentStart)
        else { return nil }
        return (grid, cursor)
    }

    /// Where a grid is drawn, in this view's coordinates.
    ///
    /// The widget hangs off the table's first line, and the fragment for that
    /// line is the only thing that knows where the whole construct ended up
    /// after layout.
    func tableOrigin(of grid: TableGrid) -> CGPoint? {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(
                content.documentRange.location,
                offsetBy: min(max(0, grid.documentStart), string.utf16.count)
              ),
              let fragment = manager.textLayoutFragment(for: location)
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        return CGPoint(
            x: frame.minX + textContainerInset.width,
            // The fragment reserves `blockInset` above the grid it draws.
            y: frame.minY + textContainerInset.height + HeftLayoutFragment.blockInset
        )
    }

    // MARK: - The caret

    /// Positions the drawn caret and any selection inside the active cell, and
    /// takes the native insertion point down while they are up.
    func updateTableCaret() {
        guard window?.firstResponder === self,
              let (grid, cursor) = activeTable,
              let cell = grid.cell(row: cursor.row, column: cursor.column),
              let origin = tableOrigin(of: grid)
        else {
            hideTableCaret()
            return
        }

        tableCaretIsActive = true
        let overlay = tableCaretOverlay
        overlay.frame = CGRect(origin: origin, size: grid.size)
        overlay.isHidden = false

        let selectionColor = selectedTextAttributes[.backgroundColor] as? NSColor
            ?? .selectedTextBackgroundColor
        overlay.selection = cursor.selection.length > 0
            ? grid.selectionRects(in: cell, range: cursor.selection)
            : []
        overlay.selectionColor = selectionColor
        overlay.cellText = overlay.selection.isEmpty ? nil : (
            cell.text,
            CGRect(
                x: cell.rect.minX + grid.alignmentOffset(for: cell), y: cell.rect.minY,
                width: cell.rect.width, height: cell.rect.height
            )
        )

        var caret = grid.caretRect(in: cell, offset: cursor.selection.length > 0
            ? NSMaxRange(cursor.selection) : cursor.offset)
        // Vim's Normal mode covers the character rather than sitting before it,
        // and that shape is how the mode is read at a glance. It has to survive
        // being drawn here, since the block cursor this replaces has no idea
        // where the cell is.
        let block = wantsVimBlockCursor
        if block, cursor.offset < cell.text.length {
            caret.size.width = max(
                4, grid.caretRect(in: cell, offset: cursor.offset + 1).minX - caret.minX
            )
        }
        overlay.setCaret(
            caret,
            color: block ? vimCaretColor.withAlphaComponent(0.52) : vimCaretColor,
            blinking: !block && cursor.selection.length == 0
        )

        // Two carets on screen at once is worse than none: the native one has
        // no idea about the grid and would sit at the table's left edge.
        updateVimCursor()
    }

    func hideTableCaret() {
        guard tableCaretIsActive || tableCaretOverlayIfLoaded?.isHidden == false else { return }
        tableCaretIsActive = false
        tableCaretOverlayIfLoaded?.isHidden = true
        tableCaretOverlayIfLoaded?.setCaret(nil, color: vimCaretColor, blinking: false)
        updateVimCursor()
    }

    // MARK: - Clicking

    /// Handles a click that landed on a drawn table: in a cell, or on one of
    /// the two `+` strips. Returns false for anything else, so an ordinary
    /// click keeps its ordinary behaviour.
    func handleTableClick(at point: CGPoint, event: NSEvent) -> Bool {
        guard let grid = liveLayout.tables.first(where: { grid in
            guard let origin = tableOrigin(of: grid) else { return false }
            return CGRect(origin: origin, size: grid.contentSize).contains(point)
        }), let origin = tableOrigin(of: grid) else { return false }

        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)

        if grid.addRowRect.contains(local) {
            addRow(to: grid)
            return true
        }
        if grid.addColumnRect.contains(local) {
            addColumn(to: grid)
            return true
        }
        guard local.x <= grid.size.width, local.y <= grid.size.height,
              let cell = grid.cell(at: local)
        else { return false }

        let anchor = documentOffset(of: cell, in: grid, at: local)
        if event.modifierFlags.contains(.shift) {
            let existing = selectedRange()
            let start = min(existing.location, anchor)
            setSelectedRange(NSRange(location: start, length: abs(anchor - existing.location)))
            return true
        }
        if event.clickCount >= 2, cell.source.location != NSNotFound {
            selectWord(around: anchor, in: cell, grid: grid)
            return true
        }
        setSelectedRange(NSRange(location: anchor, length: 0))
        trackTableSelection(from: anchor, in: grid, cell: cell, origin: origin)
        return true
    }

    /// Extends the selection while the button stays down.
    ///
    /// A private tracking loop rather than `super.mouseDown`: AppKit's would
    /// hit-test against the collapsed source, where a whole table is a handful
    /// of zero-width characters on one line, and drag out a selection that has
    /// nothing to do with what is under the pointer.
    private func trackTableSelection(
        from anchor: Int, in grid: TableGrid, cell: TableGrid.Cell, origin: CGPoint
    ) {
        guard let window else { return }
        withMouseTracking {
            while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if event.type == .leftMouseUp { break }
                let point = convert(event.locationInWindow, from: nil)
                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                // Confined to the cell the drag began in. A selection running
                // across cells would take in the pipes between them, which is
                // never what dragging across a rendered grid looks like it does.
                let head = documentOffset(of: cell, in: grid, at: local)
                setSelectedRange(NSRange(
                    location: min(anchor, head), length: abs(head - anchor)
                ))
                updateTableCaret()
            }
        }
    }

    /// The document offset a point inside `cell` corresponds to.
    private func documentOffset(
        of cell: TableGrid.Cell, in grid: TableGrid, at local: CGPoint
    ) -> Int {
        guard cell.source.location != NSNotFound else {
            // A cell that exists only because the table is ragged: there is no
            // source behind it, so the nearest real position is the end of its
            // row.
            let row = grid.layout.cellRanges.indices.contains(cell.row)
                ? grid.layout.cellRanges[cell.row] : []
            guard let last = row.last else { return grid.documentStart }
            return grid.documentStart + NSMaxRange(last)
        }
        let offset = grid.characterOffset(in: cell, at: local)
        return grid.documentStart + cell.source.location + offset
    }

    private func selectWord(around location: Int, in cell: TableGrid.Cell, grid: TableGrid) {
        let source = string as NSString
        let bounds = NSRange(
            location: grid.documentStart + cell.source.location, length: cell.source.length
        )
        guard bounds.length > 0 else {
            setSelectedRange(NSRange(location: location, length: 0))
            return
        }
        let separators = CharacterSet.whitespaces.union(.punctuationCharacters)
        var start = min(max(location, bounds.location), NSMaxRange(bounds))
        var end = start
        func isWord(_ index: Int) -> Bool {
            guard index >= bounds.location, index < NSMaxRange(bounds) else { return false }
            guard let scalar = Unicode.Scalar(source.character(at: index)) else { return false }
            return !separators.contains(scalar)
        }
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        setSelectedRange(end > start
            ? NSRange(location: start, length: end - start)
            : bounds)
    }

    // MARK: - Structural commands

    /// Tab and Shift-Tab walk the cells; Return drops to the row below. All
    /// three grow the table by a row rather than running out of it, which is
    /// what makes a table something you can fill in rather than lay out first.
    func handleTableTab(forward: Bool) -> Bool {
        guard let (grid, cursor) = activeTable else { return false }
        let action = forward
            ? TableEditing.nextCell(in: grid.layout, from: cursor, tableStart: grid.documentStart)
            : TableEditing.previousCell(in: grid.layout, from: cursor, tableStart: grid.documentStart)
        return apply(action)
    }

    func handleTableReturn() -> Bool {
        guard let (grid, cursor) = activeTable else { return false }
        return apply(
            TableEditing.cellBelow(in: grid.layout, from: cursor, tableStart: grid.documentStart)
        )
    }

    /// Up and down move between rows, not between the lines the rows happen to
    /// occupy. At the top and bottom edges this declines, so the arrow key
    /// leaves the table the ordinary way.
    ///
    /// Down never grows the table, unlike Return: an arrow key that adds a row
    /// makes it impossible to arrow *out* of a table at all.
    func handleTableVerticalMove(down: Bool) -> Bool {
        guard let (grid, cursor) = activeTable else { return false }
        let action = down
            ? (cursor.row + 1 < grid.layout.cellRanges.count
                ? TableEditing.cellBelow(
                    in: grid.layout, from: cursor, tableStart: grid.documentStart
                )
                : nil)
            : TableEditing.cellAbove(
                in: grid.layout, from: cursor, tableStart: grid.documentStart
            )
        guard let action, action.replace == nil else { return false }
        // A caret, not a selection: an arrow key is a move, and selecting the
        // cell it lands in would make the next keystroke replace it.
        setSelectedRange(NSRange(location: action.selection.location, length: 0))
        updateTableCaret()
        return true
    }

    // MARK: - The context menu

    /// Row and column commands for the table under the pointer.
    ///
    /// The `+` strips cover adding, which is the common case and wants to be a
    /// single click. Deleting a row or column is rarer and destructive enough
    /// to want naming, so it lives here rather than as a third and fourth strip
    /// to misclick on.
    func tableMenu(at point: CGPoint) -> NSMenu? {
        guard let grid = liveLayout.tables.first(where: { grid in
            guard let origin = tableOrigin(of: grid) else { return false }
            return CGRect(origin: origin, size: grid.contentSize).contains(point)
        }), let origin = tableOrigin(of: grid) else { return nil }

        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let cell = grid.cell(at: local) else { return nil }
        pendingTableCommand = (grid, cell.row, cell.column)

        let menu = NSMenu()
        let groups: [[(String, Selector)]] = [
            [
                ("Insert Row Above", #selector(HeftTextKit2View.insertTableRowAbove(_:))),
                ("Insert Row Below", #selector(HeftTextKit2View.insertTableRowBelow(_:))),
                ("Delete Row", #selector(HeftTextKit2View.deleteTableRow(_:))),
            ],
            [
                ("Insert Column Before", #selector(HeftTextKit2View.insertTableColumnBefore(_:))),
                ("Insert Column After", #selector(HeftTextKit2View.insertTableColumnAfter(_:))),
                ("Delete Column", #selector(HeftTextKit2View.deleteTableColumn(_:))),
            ],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, action) in group {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Runs a menu command against the cell the menu was opened on, since the
    /// caret may never have been in that table at all.
    private func runTableCommand(
        _ body: (TableLayout, Int, Int, Int) -> TableEditing.Action?
    ) {
        guard let (grid, row, column) = pendingTableCommand else { return }
        _ = apply(body(grid.layout, row, column, grid.documentStart))
    }

    /// Greys out the commands that cannot apply: a table has to keep its
    /// header row and at least one column.
    func validatesTableCommand(_ action: Selector) -> Bool? {
        guard let (grid, row, _) = pendingTableCommand else { return nil }
        switch action {
        case #selector(HeftTextKit2View.insertTableRowAbove(_:)),
             #selector(HeftTextKit2View.deleteTableRow(_:)):
            return row > 0
        case #selector(HeftTextKit2View.deleteTableColumn(_:)):
            return grid.layout.columnCount > 1
        case #selector(HeftTextKit2View.insertTableRowBelow(_:)),
             #selector(HeftTextKit2View.insertTableColumnBefore(_:)),
             #selector(HeftTextKit2View.insertTableColumnAfter(_:)):
            return true
        default:
            return nil
        }
    }

    @objc func insertTableRowAbove(_ sender: Any?) {
        runTableCommand { table, row, _, start in
            // "Above row 1" is "after row 0", and above the header there is
            // nowhere legal to put a row at all.
            row > 0 ? TableEditing.insertRow(in: table, after: row - 1, tableStart: start) : nil
        }
    }

    @objc func insertTableRowBelow(_ sender: Any?) {
        runTableCommand { table, row, _, start in
            TableEditing.insertRow(in: table, after: row, tableStart: start)
        }
    }

    @objc func deleteTableRow(_ sender: Any?) {
        runTableCommand { table, row, _, start in
            TableEditing.deleteRow(in: table, at: row, tableStart: start)
        }
    }

    @objc func insertTableColumnBefore(_ sender: Any?) {
        runTableCommand { table, _, column, start in
            TableEditing.insertColumn(in: table, after: column - 1, tableStart: start)
        }
    }

    @objc func insertTableColumnAfter(_ sender: Any?) {
        runTableCommand { table, _, column, start in
            TableEditing.insertColumn(in: table, after: column, tableStart: start)
        }
    }

    @objc func deleteTableColumn(_ sender: Any?) {
        runTableCommand { table, _, column, start in
            TableEditing.deleteColumn(in: table, at: column, tableStart: start)
        }
    }

    private func addRow(to grid: TableGrid) {
        let after = activeTable.map(\.cursor.row) ?? (grid.layout.rowRanges.count - 1)
        _ = apply(TableEditing.insertRow(
            in: grid.layout,
            after: grid.active == nil ? grid.layout.rowRanges.count - 1 : after,
            tableStart: grid.documentStart
        ))
    }

    private func addColumn(to grid: TableGrid) {
        let after = grid.active?.column ?? (grid.layout.columnCount - 1)
        _ = apply(TableEditing.insertColumn(
            in: grid.layout,
            after: grid.active == nil ? grid.layout.columnCount - 1 : after,
            tableStart: grid.documentStart
        ))
    }

    @discardableResult
    private func apply(_ action: TableEditing.Action?) -> Bool {
        guard let action else { return false }
        guard let replace = action.replace else {
            setSelectedRange(action.selection)
            updateTableCaret()
            return true
        }
        guard shouldChangeText(in: replace, replacementString: action.replacement) else {
            return false
        }
        textStorage?.replaceCharacters(in: replace, with: action.replacement)
        didChangeText()
        setSelectedRange(action.selection)
        updateTableCaret()
        return true
    }
}

// MARK: - The overlay

/// Draws the caret, and any selection, inside a table cell.
///
/// A view rather than something painted by the layout fragment, and
/// deliberately so: a fragment only redraws when its attributes or its layout
/// change, and moving the caret from one character to the next inside a cell
/// changes neither. Restyling on every arrow key to get a caret redrawn would
/// undo the whole point of scoped restyling.
final class TableCaretOverlay: NSView {
    var selection: [CGRect] = [] { didSet { needsDisplay = true } }
    var selectionColor: NSColor = .selectedTextBackgroundColor { didSet { needsDisplay = true } }
    /// The active cell's text and where it sits, so the highlight can be put
    /// behind it.
    ///
    /// Every subview of an `NSTextView` is composited over the text the view
    /// drew itself, so a selection filled here covers the glyphs it is meant to
    /// sit behind. Painting the same string again on top of the fill is what
    /// puts it back — the layout is identical, so the second pass lands exactly
    /// where the first one did.
    var cellText: (text: NSAttributedString, rect: CGRect)? { didSet { needsDisplay = true } }

    private let caret = CALayer()
    private var caretColor: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        caret.isHidden = true
        layer?.addSublayer(caret)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks belong to the text view underneath; this is decoration only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    func setCaret(_ rect: CGRect?, color: NSColor, blinking: Bool) {
        caretColor = color
        guard let rect else {
            caret.isHidden = true
            caret.removeAllAnimations()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = rect
        caret.backgroundColor = color.cgColor
        caret.cornerRadius = 1
        caret.isHidden = false
        CATransaction.commit()

        caret.removeAllAnimations()
        guard blinking else { return }
        // Restarted on every move, so the caret is solid the moment it lands
        // and only then begins to blink — the cadence AppKit's own uses.
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 1.06
        blink.calculationMode = .discrete
        blink.repeatCount = .infinity
        caret.add(blink, forKey: "blink")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !selection.isEmpty else { return }
        selectionColor.setFill()
        for rect in selection { rect.fill() }
        guard let cellText else { return }
        cellText.text.draw(
            with: cellText.rect, options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}
