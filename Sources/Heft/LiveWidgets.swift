import AppKit
import HeftCore

/// Things the editor draws itself, in place of markdown source it has hidden.
///
/// The text storage always holds the file byte-for-byte. Constructs that no
/// attribute can express -- a table grid, a typeset formula, an embedded image,
/// a list bullet sitting in the gutter -- are collapsed to zero width and then
/// painted by `HeftLayoutFragment`. This is the whole reason the editor is on
/// TextKit 2: `NSTextLayoutFragment` is subclassable, so a paragraph can be
/// given extra height and arbitrary drawing, which TextKit 1 cannot do without
/// inserting attachment characters into the user's document.
enum BlockWidget {
    /// A drawn bullet, numeral or checkbox in the gutter of a list line.
    case list(glyph: ListGlyph, markerOffset: CGFloat, fontSize: CGFloat)
    /// A compact, level-coloured indicator beside a heading. The colour is
    /// resolved once at style time, when `RenderContext` is in scope, rather
    /// than re-read from `AppearanceSettings` on every draw: that keeps a
    /// colour change picked up by the same restyle-on-change path every
    /// other custom colour already uses, instead of a second, untracked one.
    case headingAccent(level: Int, color: NSColor)
    case codeBlock(edge: CodeBlockEdge, language: String?)
    case thematicBreak
    /// A labelled rule where the agent guide begins or ends.
    case agentGuide(isEnd: Bool)
    case blockMath(NSImage)
    /// A picture, and whatever the line it claimed still owes the reader.
    case image(NSImage, lead: BlockLead = BlockLead())
    /// Drawn as a grid; the widget owns every line of the table.
    case table(TableGrid)
    /// One line's slice of a quote bar, or of a callout's tinted card.
    /// `isRevealed` means the line's real source is on screen, so nothing may
    /// be drawn where that source sits.
    case quote(QuoteLine, indent: CGFloat, isRevealed: Bool, bullet: LeadingBullet? = nil)
    /// Another note's content, transcluded by `![[Note]]`.
    case embed(EmbeddedNote, lead: BlockLead = BlockLead())
    /// YAML frontmatter, drawn as a key/value table.
    case properties(PropertiesCard)
}

/// A bullet, numeral or checkbox belonging to a list whose line is drawn by
/// some other widget: a quote bar, or a picture pasted onto the bullet.
///
/// Carried by that widget rather than emitted as a `.list` of its own, because
/// the editor draws one widget per line and something else already owns that
/// line's key. Same three numbers `.list` takes, so both go through exactly the
/// same drawing code.
struct LeadingBullet {
    let glyph: ListGlyph
    let markerOffset: CGFloat
    let fontSize: CGFloat
}

/// What a line already owed the reader before a picture or a transclusion
/// claimed its one widget slot.
///
/// The editor draws one widget per line, keyed by line start, so a picture
/// written onto a bullet inside a quote displaces both the bullet and the
/// quote bar. Rather than let the last writer win, the picture carries them:
/// `indent` is how far the paragraph is already inset (room the picture does
/// not have), `bullet` is the list glyph, and `quote` is the bar or callout
/// card to paint behind it all.
struct BlockLead {
    var indent: CGFloat = 0
    var bullet: LeadingBullet?
    var quote: LeadingQuote?
}

/// A quote bar or callout card whose line some other widget took over.
struct LeadingQuote {
    let line: QuoteLine
    let isRevealed: Bool
}

/// A note's frontmatter, measured as a two-column table.
///
/// Drawn rather than styled in place because the useful shape of `tags: [a, b]`
/// is a row of values under a label, and no run of text attributes turns YAML
/// into that. Putting the caret anywhere in the block brings the real YAML
/// back, so it stays editable as the text it actually is.
struct PropertiesCard {
    struct Row {
        let key: NSAttributedString
        let values: [NSAttributedString]
        /// True for `tags`, whose values are drawn as pills.
        let isTagRow: Bool
    }

    let rows: [Row]
    let keyColumnWidth: CGFloat
    let size: CGSize

    static let rowHeight: CGFloat = 24
    static let padding = CGSize(width: 12, height: 9)
    static let gutter: CGFloat = 12
}

/// A transcluded note, already styled and measured so drawing is a straight
/// paint.
///
/// The body is rendered through the same styler the prose uses, but with
/// widgets turned off. That is a deliberate bound as well as a saving: a note
/// embedding itself, directly or in a cycle, cannot recurse, because the pass
/// that would produce the inner embed never runs.
struct EmbeddedNote {
    let title: String
    let body: NSAttributedString
    let size: CGSize
    /// True when the note was longer than an embed is allowed to grow, so the
    /// card can say as much rather than appear to be the whole note.
    let isTruncated: Bool

    static let padding = CGSize(width: 14, height: 10)
    /// A fragment cannot scroll, so an embedded note has to stop somewhere.
    static let maximumHeight: CGFloat = 420
}

enum CodeBlockEdge: Equatable {
    case only
    case first
    case middle
    case last
}

enum ListGlyph {
    case bullet(BulletShape)
    case ordered(String)
    /// The accent is resolved at style time, where `RenderContext` is in
    /// scope, for the same reason `headingAccent` carries its colour: reading
    /// `AppearanceSettings` here instead would sidestep the restyle-on-change
    /// path and leave open windows showing the old colour.
    case checkbox(TaskState, accent: NSColor)
}

/// Widget placement for one restyle pass, keyed by the document offset of the
/// line each widget belongs to.
struct LiveLayout {
    var blocks: [Int: BlockWidget] = [:]
    /// Formulae drawn inside a line, keyed by that line's start offset.
    var inlineMath: [Int: [(location: Int, image: NSImage)]] = [:]
    /// Tag pills drawn behind their own text, keyed the same way. The colour
    /// travels with the range because it is resolved from the render context
    /// while styling, which is where the user's setting is in scope.
    var inlineTags: [Int: [(range: NSRange, color: NSColor, font: NSFont, ink: CGRect)]] = [:]
    /// Ranges of the inline spans that reveal on the caret rather than on their
    /// line. The editor keeps these to tell an ordinary cursor move apart from
    /// one that crosses into or out of a span and so needs a restyle.
    var revealableSpans: [NSRange] = []

    /// Every drawn table in the note, in document order. The editor needs these
    /// outside a draw pass — to put the caret in a cell, to work out what a
    /// click landed on, to know what Tab should do — and a widget keyed by the
    /// paragraph it hangs off is not a convenient way to ask.
    var tables: [TableGrid] {
        blocks.values
            .compactMap { if case .table(let grid) = $0 { grid } else { nil } }
            .sorted { $0.documentStart < $1.documentStart }
    }

    /// The table containing `location`, if any.
    func table(containing location: Int) -> TableGrid? {
        tables.first {
            location >= $0.documentStart && location <= $0.documentStart + $0.sourceLength
        }
    }

    /// Cheap identity for "did the set of widgets change". Compared to decide
    /// whether a full layout invalidation is needed; the images themselves are
    /// deliberately not part of it, because editing inside a formula already
    /// invalidates that paragraph through its attributes.
    var signature: String {
        let blockKeys = blocks.keys.sorted().map(String.init).joined(separator: ",")
        let mathKeys = inlineMath.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        let tagKeys = inlineTags.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        return blockKeys + "|" + mathKeys + "|" + tagKeys
    }
}

// MARK: - Table measurement

/// A table measured into concrete rectangles, so drawing is a straight paint.
///
/// One cell may be *active*: the caret is inside it, so it shows its markdown
/// source while every other cell stays rendered. That is the whole point of the
/// grid outliving the caret. The alternative — what this editor used to do, and
/// what a naive live-preview does — is to dissolve the entire table back into
/// pipes the moment it is clicked, which is exactly when its shape is most
/// useful to look at.
struct TableGrid {
    /// Which cell the caret is in, in `TableLayout.rows` coordinates.
    struct ActiveCell: Hashable {
        let row: Int
        let column: Int
    }

    struct Cell {
        let text: NSAttributedString
        let rect: CGRect
        let alignment: MDColumnAlignment
        let row: Int
        let column: Int
        /// The cell's source range, relative to the table's own start.
        /// `NSNotFound` for a cell that only exists because its row is short
        /// of the table's column count, and so has nothing behind it in the
        /// file to put a caret in.
        let source: NSRange
    }

    var cells: [Cell] = []
    var rowHeights: [CGFloat] = []
    var columnWidths: [CGFloat] = []
    var size: CGSize = .zero
    var headerHeight: CGFloat = 0
    var active: ActiveCell?
    /// The parse the grid was measured from, carried along so the editor can
    /// answer questions about the table — which cell is at this offset, what
    /// Tab does next, what a new column would look like — without re-parsing
    /// the document to find out.
    var layout = TableLayout(rows: [], alignments: [])
    /// How much of the document the table occupies, from `documentStart`.
    var sourceLength: Int { layout.sourceLength }
    /// Where the table begins in the document. Filled in after the measurement
    /// is fetched, because two identical tables in one note share one cached
    /// grid and only differ in where they are.
    var documentStart = 0
    /// Resolved at style time, like every other custom colour a fragment draws
    /// with: reading `AppearanceSettings` inside `draw` would sidestep the
    /// restyle-on-change fingerprint and leave open windows on the old accent.
    var accent: NSColor = .controlAccentColor

    static let padding = CGSize(width: 11, height: 7)
    /// The narrowest a column is drawn at, whatever its content measures.
    ///
    /// Widths come from the rendered text, so a table whose cells are still
    /// empty measured only the three spaces `blankTable` writes into each one:
    /// a fresh 2x2 grid came out barely wider than its own borders, with
    /// nothing to aim a click at. Leaves room for roughly ten characters.
    static let minimumColumnWidth: CGFloat = 96
    /// Thickness of the add-row strip under the table and the add-column strip
    /// beside it.
    ///
    /// The space is reserved whether or not the strips are drawn. Reserving it
    /// only while the table is active would make clicking one shove the rest of
    /// the note down by this much, and clicking away shove it back.
    static let affordance: CGFloat = 17

    /// Including the affordance strips, which is what the line has to be tall
    /// enough for.
    var contentSize: CGSize {
        CGSize(width: size.width + Self.affordance, height: size.height + Self.affordance)
    }

    /// In grid coordinates: the strip that adds a row, under the last one.
    var addRowRect: CGRect {
        CGRect(x: 0, y: size.height + 1, width: size.width, height: Self.affordance - 1)
    }

    /// In grid coordinates: the strip that adds a column, past the last one.
    var addColumnRect: CGRect {
        CGRect(x: size.width + 1, y: 0, width: Self.affordance - 1, height: size.height)
    }

    func cell(row: Int, column: Int) -> Cell? {
        cells.first { $0.row == row && $0.column == column }
    }

    /// Measuring a table styles every cell, which is far too much work to redo
    /// on each caret move. Keyed by everything the result depends on.
    private struct CacheKey: Hashable {
        let layout: TableLayout
        let maxWidth: CGFloat
        let fontSize: CGFloat
        let active: ActiveCell?
        let vault: String
    }

    private static var cache: [CacheKey: TableGrid] = [:]

    static func measure(
        _ layout: TableLayout, maxWidth: CGFloat, context: RenderContext, fontSize: CGFloat,
        active: ActiveCell? = nil
    ) -> TableGrid {
        let key = CacheKey(
            layout: layout, maxWidth: maxWidth, fontSize: fontSize, active: active,
            // Link colour inside a cell depends on whether the target resolves,
            // so a changed index must not reuse an earlier measurement.
            vault: "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")"
        )
        if let hit = cache[key] { return hit }
        let grid = compute(
            layout, maxWidth: maxWidth, context: context, fontSize: fontSize, active: active
        )
        // Plain eviction: notes hold a handful of tables, and the key changes
        // on every window resize, so the map must not grow without bound.
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = grid
        return grid
    }

    /// Lays the table out within `maxWidth`. Columns take their natural width
    /// where they fit, and are scaled down proportionally when they do not.
    private static func compute(
        _ layout: TableLayout, maxWidth: CGFloat, context: RenderContext, fontSize: CGFloat,
        active: ActiveCell?
    ) -> TableGrid {
        let columnCount = layout.columnCount
        guard columnCount > 0, !layout.rows.isEmpty else { return TableGrid() }

        // Every cell is styled through the same decorator the prose uses, so a
        // link or `**bold**` inside a cell looks the same as it does outside.
        let display: [[NSAttributedString]] = layout.rows.enumerated().map { rowIndex, row in
            (0..<columnCount).map { column in
                let source = column < row.count ? row[column] : ""
                return CellText.render(
                    source, bold: rowIndex == 0, fontSize: fontSize, context: context
                )
            }
        }

        // Measured the same way the cells are later drawn. `size()` reports a
        // hair less than `boundingRect` does, which is enough to make a header
        // wrap inside the column that was sized for it.
        //
        // Deliberately measured from the *rendered* text even for the active
        // cell, whose drawn text is longer because its markup is showing. A
        // column that resized as the caret entered and left it would make the
        // whole table twitch on every click.
        var natural = [CGFloat](repeating: 0, count: columnCount)
        for row in display {
            for (column, cell) in row.enumerated() {
                let bounds = cell.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                natural[column] = max(natural[column], ceil(bounds.width) + 1 + padding.width * 2)
            }
        }

        // Capped at an equal share of the space available, so the floor itself
        // can never be what pushes a table into scaling down: a six-column
        // table stays as wide as it fits and no wider.
        let minimum = min(minimumColumnWidth, maxWidth / CGFloat(columnCount))
        for column in natural.indices {
            natural[column] = max(natural[column], minimum)
        }

        let total = natural.reduce(0, +)
        var widths = natural
        if total > maxWidth, total > 0 {
            let scale = maxWidth / total
            // Narrow columns stay legible; the overflow comes off the wide ones.
            let floorWidth: CGFloat = 64
            widths = natural.map { max(min($0, floorWidth), $0 * scale) }
            let corrected = widths.reduce(0, +)
            if corrected > maxWidth {
                widths = widths.map { $0 * (maxWidth / corrected) }
            }
        }

        var styled = display
        if let active, active.row < styled.count, active.column < styled[active.row].count {
            // The cell under the caret shows what is actually in the file, so
            // the markers being edited are visible and every offset inside it
            // is an offset into the document.
            let raw = active.row < layout.rawRows.count
                && active.column < layout.rawRows[active.row].count
                ? layout.rawRows[active.row][active.column] : ""
            let revealed = CellText.render(
                raw, bold: active.row == 0, fontSize: fontSize, context: context, revealed: true
            )
            styled[active.row][active.column] = revealed

            // Markup appearing makes the cell's text longer, and a cell that
            // wraps onto a second line makes its row taller and shoves the rest
            // of the note down. Where the table is narrower than the text
            // column there is slack going spare, so spend it on this one column
            // rather than on the document's vertical rhythm. No other column
            // changes width, so nothing outside the table moves at all.
            let wanted = ceil(revealed.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width) + 1 + padding.width * 2
            let spare = maxWidth - widths.reduce(0, +)
            if spare > 0, wanted > widths[active.column] {
                widths[active.column] += min(spare, wanted - widths[active.column])
            }
        }

        var grid = TableGrid()
        grid.columnWidths = widths
        grid.active = active
        grid.layout = layout

        var y: CGFloat = 0
        for (rowIndex, row) in styled.enumerated() {
            var height: CGFloat = 0
            var measured: [(NSAttributedString, CGFloat)] = []
            for (column, cell) in row.enumerated() {
                let available = widths[column] - padding.width * 2
                let bounds = cell.boundingRect(
                    with: CGSize(width: max(available, 1), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let cellHeight = ceil(bounds.height) + padding.height * 2
                height = max(height, cellHeight)
                measured.append((cell, available))
            }
            height = max(height, fontSize + padding.height * 2 + 4)

            var x: CGFloat = 0
            for (column, entry) in measured.enumerated() {
                let source = rowIndex < layout.cellRanges.count
                    && column < layout.cellRanges[rowIndex].count
                    ? layout.cellRanges[rowIndex][column]
                    : NSRange(location: NSNotFound, length: 0)
                grid.cells.append(Cell(
                    text: entry.0,
                    rect: CGRect(
                        x: x + padding.width, y: y + padding.height,
                        width: entry.1, height: height - padding.height * 2
                    ),
                    alignment: column < layout.alignments.count ? layout.alignments[column] : .leading,
                    row: rowIndex,
                    column: column,
                    source: source
                ))
                x += widths[column]
            }
            if rowIndex == 0 { grid.headerHeight = height }
            grid.rowHeights.append(height)
            y += height
        }

        grid.size = CGSize(width: widths.reduce(0, +), height: y)
        return grid
    }

    // MARK: Hit testing

    /// The cell a point in grid coordinates falls in, snapped to the nearest
    /// one rather than missing between borders.
    func cell(at point: CGPoint) -> Cell? {
        guard !rowHeights.isEmpty, !columnWidths.isEmpty else { return nil }
        var row = rowHeights.count - 1
        var y: CGFloat = 0
        for (index, height) in rowHeights.enumerated() {
            if point.y < y + height { row = index; break }
            y += height
        }
        var column = columnWidths.count - 1
        var x: CGFloat = 0
        for (index, width) in columnWidths.enumerated() {
            if point.x < x + width { column = index; break }
            x += width
        }
        return cell(row: max(0, row), column: max(0, column))
    }

    /// Lays a cell's text out on its own and runs `body` against it, so
    /// positions inside the cell can be asked for.
    ///
    /// TextKit 1 rather than `boundingRect`, because a cell wraps and a caret
    /// has to follow it onto the second line. The container is set up the way
    /// `draw(with:options:)` lays the same string out: no line-fragment
    /// padding, one container the width of the cell's text rect.
    ///
    /// Closure-shaped rather than returning the three objects, and that is the
    /// whole point: `NSLayoutManager` does not retain its text storage, so
    /// handing the trio back left every caller free to drop the storage on the
    /// spot and lay out against a deallocated one. It does not crash — it
    /// quietly answers 0 for every position, which reads as a caret pinned to
    /// the left edge of the cell and a selection with no rectangles at all.
    private func typeset<T>(
        _ cell: Cell, _ body: (NSLayoutManager, NSTextContainer) -> T
    ) -> T {
        let storage = NSTextStorage(attributedString: cell.text)
        let container = NSTextContainer(
            size: CGSize(width: max(cell.rect.width, 1), height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        // Forces glyph generation as well as layout.
        _ = manager.glyphRange(for: container)
        return withExtendedLifetime(storage) { body(manager, container) }
    }

    /// Where a caret sitting `offset` characters into `cell` is drawn, in grid
    /// coordinates.
    ///
    /// Measured from the bounding box of the glyph the caret sits before —
    /// its trailing edge for the position past the last one. That is the one
    /// query that is reliable here: the per-glyph location is relative to a
    /// line fragment that may not have been laid out yet, and answers 0 when
    /// it has not.
    func caretRect(in cell: Cell, offset: Int) -> CGRect {
        let clamped = min(max(0, offset), cell.text.length)
        let origin = CGPoint(
            x: cell.rect.minX + alignmentOffset(for: cell), y: cell.rect.minY
        )
        return typeset(cell) { manager, container in
            guard manager.numberOfGlyphs > 0 else {
                return CGRect(x: origin.x, y: origin.y, width: 2, height: max(cell.rect.height, 12))
            }
            let atEnd = clamped >= cell.text.length
            let probe = min(
                manager.glyphIndexForCharacter(at: atEnd ? cell.text.length - 1 : clamped),
                manager.numberOfGlyphs - 1
            )
            let box = manager.boundingRect(
                forGlyphRange: NSRange(location: probe, length: 1), in: container
            )
            return CGRect(
                x: origin.x + (atEnd ? box.maxX : box.minX), y: origin.y + box.minY,
                width: 2, height: max(box.height, 12)
            )
        }
    }

    /// The boxes a selection inside one cell covers, in grid coordinates.
    func selectionRects(in cell: Cell, range: NSRange) -> [CGRect] {
        let clamped = NSIntersectionRange(
            range, NSRange(location: 0, length: cell.text.length)
        )
        guard clamped.length > 0 else { return [] }
        let origin = CGPoint(
            x: cell.rect.minX + alignmentOffset(for: cell), y: cell.rect.minY
        )
        return typeset(cell) { manager, container in
            let glyphs = manager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            var rects: [CGRect] = []
            // `{NSNotFound, 0}` for the selected range is what asks for the
            // plain enclosing rectangles. Passing the same range twice asks
            // instead for its intersection with a selection this layout manager
            // does not have, and comes back empty every time.
            manager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            return rects
        }
    }

    /// The character offset a point in grid coordinates falls on inside `cell`.
    func characterOffset(in cell: Cell, at point: CGPoint) -> Int {
        guard cell.text.length > 0 else { return 0 }
        let local = CGPoint(
            x: point.x - cell.rect.minX - alignmentOffset(for: cell),
            y: min(max(point.y - cell.rect.minY, 0), max(cell.rect.height - 1, 0))
        )
        return typeset(cell) { manager, container in
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(
                for: local, in: container, fractionOfDistanceThroughGlyph: &fraction
            )
            let character = manager.characterIndexForGlyph(
                at: min(glyph, max(0, manager.numberOfGlyphs - 1))
            )
            // Past the midpoint of a glyph the caret belongs after it, which is
            // what makes clicking the right half of a letter feel accurate.
            let offset = fraction > 0.5 ? character + 1 : character
            return min(max(0, offset), cell.text.length)
        }
    }

    /// The shift `draw` applies for a centred or right-aligned column, so the
    /// caret lands on the glyphs rather than beside them.
    func alignmentOffset(for cell: Cell) -> CGFloat {
        guard cell.alignment != .leading else { return 0 }
        let bounds = cell.text.boundingRect(
            with: CGSize(width: cell.rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return switch cell.alignment {
        case .center: max(0, (cell.rect.width - bounds.width) / 2)
        case .trailing: max(0, cell.rect.width - bounds.width)
        case .leading: 0
        }
    }
}

/// Reads, styles and measures the note behind an `![[Note]]` embed.
enum EmbedRenderer {

    /// Keyed on the file's modification date as well as its path, so an embed
    /// updates when the note it shows is edited elsewhere, and costs nothing
    /// when it is not. Without this the file would be re-read and re-styled on
    /// every keystroke in the host note.
    private struct CacheKey: Hashable {
        let path: String
        let modified: Date?
        let heading: String?
        let blockID: String?
        let width: CGFloat
        let fontSize: CGFloat
        let appearance: String
    }

    private static var cache: [CacheKey: EmbeddedNote] = [:]

    static func render(
        link: WikiLink, note: NoteRef, maxWidth: CGFloat,
        context: RenderContext, fontSize: CGFloat
    ) -> EmbeddedNote? {
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: note.url.path))?[.modificationDate] as? Date
        let key = CacheKey(
            path: note.relativePath, modified: modified,
            heading: link.heading, blockID: link.blockID,
            width: maxWidth, fontSize: fontSize,
            appearance: context.appearance?.name.rawValue ?? ""
        )
        if let hit = cache[key] { return hit }

        guard let source = try? String(contentsOf: note.url, encoding: .utf8),
              let body = NoteText.embedBody(
                of: source, heading: link.heading, blockID: link.blockID
              ),
              !body.isEmpty
        else { return nil }

        let base = NSFont.systemFont(ofSize: fontSize)
        let storage = NSTextStorage(string: body, attributes: [
            .font: base,
            .foregroundColor: NSColor.labelColor,
        ])
        // Widgets off: an embedded note is styled, not laid out with its own
        // tables and pictures, and that is also what stops a cycle of embeds
        // from recursing.
        _ = LiveStyler.apply(
            to: storage, reveal: .none, context: context,
            baseFont: base, drawsWidgets: false
        )

        let available = maxWidth - EmbeddedNote.padding.width * 2
        let measured = storage.boundingRect(
            with: CGSize(width: max(available, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let natural = ceil(measured.height) + titleHeight + EmbeddedNote.padding.height * 2
        let embed = EmbeddedNote(
            title: link.heading.map { "\(note.name) › \($0)" } ?? note.name,
            body: storage,
            size: CGSize(width: maxWidth, height: min(natural, EmbeddedNote.maximumHeight)),
            isTruncated: natural > EmbeddedNote.maximumHeight
        )

        // Plain eviction: a note holds few embeds, and the key changes on every
        // window resize, so the map must not grow without bound.
        if cache.count > 48 { cache.removeAll(keepingCapacity: true) }
        cache[key] = embed
        return embed
    }

    static let titleHeight: CGFloat = 18
}

/// Lays a note's frontmatter out as a properties table.
enum PropertiesRenderer {

    static func card(yaml: String, maxWidth: CGFloat, fontSize: CGFloat) -> PropertiesCard? {
        let properties = Frontmatter.parse(yaml)
        guard !properties.isEmpty else { return nil }

        let keyFont = NSFont.systemFont(ofSize: fontSize - 1)
        let valueFont = NSFont.systemFont(ofSize: fontSize)

        var rows: [PropertiesCard.Row] = []
        var keyWidth: CGFloat = 0

        for property in properties {
            let key = NSAttributedString(string: property.key, attributes: [
                .font: keyFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            keyWidth = max(keyWidth, ceil(key.size().width))

            let isTagRow = ["tags", "tag"].contains(property.key.lowercased())
            let items = property.value.items
            let values = (items.isEmpty ? [property.value.display] : items).map { value in
                NSAttributedString(string: value, attributes: [
                    .font: valueFont,
                    .foregroundColor: isTagRow ? NSColor.systemPurple : NSColor.labelColor,
                ])
            }
            rows.append(PropertiesCard.Row(key: key, values: values, isTagRow: isTagRow))
        }

        // Cap the key column so one long key cannot squeeze every value out.
        keyWidth = min(keyWidth, maxWidth * 0.3)
        let height = CGFloat(rows.count) * PropertiesCard.rowHeight
            + PropertiesCard.padding.height * 2
        return PropertiesCard(
            rows: rows,
            keyColumnWidth: keyWidth,
            size: CGSize(width: maxWidth, height: height)
        )
    }
}

/// Renders one table cell's markdown source to an attributed string.
enum CellText {
    /// - Parameter revealed: show the cell's markup rather than collapsing it.
    ///   True for the one cell the caret is in, so that what is on screen is
    ///   what is in the file and a caret offset means the same thing in both.
    static func render(
        _ source: String, bold: Bool, fontSize: CGFloat, context: RenderContext,
        revealed: Bool = false
    ) -> NSAttributedString {
        let base = bold
            ? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: fontSize)
        let storage = NSTextStorage(string: source, attributes: [
            .font: base,
            .foregroundColor: NSColor.labelColor,
        ])
        // Reuse the prose styler so cells and body text cannot drift apart.
        let whole = NSRange(location: 0, length: (source as NSString).length)
        _ = LiveStyler.apply(
            to: storage,
            reveal: revealed
                ? Reveal(line: whole, selection: whole)
                : .none,
            context: context,
            baseFont: base,
            drawsWidgets: false
        )
        return storage
    }
}

// MARK: - Fragment

/// Draws the widgets for one paragraph and reserves the height they need.
final class HeftLayoutFragment: NSTextLayoutFragment {
    var widget: BlockWidget?
    var inlineMath: [(location: Int, image: NSImage)] = []
    var inlineTags: [(range: NSRange, color: NSColor, font: NSFont, ink: CGRect)] = []
    var elementStart = 0

    /// Vertical breathing room around a drawn block. `LiveStyler` adds twice
    /// this to the line height it reserves, so the two must agree.
    static let blockInset: CGFloat = 10

    /// Size a block widget occupies, and therefore the height its line must
    /// reserve. Nothing here consults layout, so `LiveStyler` can ask before
    /// any fragment exists.
    private var contentSize: CGSize? {
        switch widget {
        case .blockMath(let image): image.size
        case .image(let image, _): Self.displaySize(for: image)
        case .table(let grid): grid.contentSize
        case .embed(let embed, _): embed.size
        case .properties(let card): card.size
        default: nil
        }
    }

    /// What the line this widget claimed still owes the reader, if anything.
    private var blockLead: BlockLead? {
        switch widget {
        case .image(_, let lead), .embed(_, let lead): lead
        default: nil
        }
    }

    /// How far a block widget is drawn in from the fragment's own origin.
    /// Non-zero only for one sitting on a list or quote line.
    private var blockIndent: CGFloat {
        switch widget {
        case .image(_, let lead), .embed(_, let lead): lead.indent
        default: 0
        }
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let contentSize {
            // The line is already tall enough; this only widens the clip so a
            // grid or picture wider than its (collapsed, empty) text is drawn.
            // Full container width, not the content's: display math is centred,
            // so a bounds box the size of the formula clips its right half.
            bounds = bounds.union(CGRect(
                x: 0, y: 0,
                width: max(bounds.width, containerWidth - blockIndent, contentSize.width) + 2,
                height: contentSize.height + Self.blockInset * 2
            ))
        }
        // Heading accents and list glyphs draw into the gutter to the left.
        switch widget {
        case .thematicBreak:
            bounds = bounds.union(CGRect(
                x: 0, y: -8, width: containerWidth, height: bounds.height + 16
            ))
        case .agentGuide:
            bounds = bounds.union(CGRect(
                x: 0, y: -8, width: containerWidth, height: bounds.height + 16
            ))
        case .headingAccent:
            bounds = bounds.union(CGRect(x: -16, y: 0, width: bounds.width + 16, height: bounds.height))
        case .codeBlock:
            bounds = bounds.union(CGRect(
                x: -10, y: -1, width: containerWidth, height: bounds.height + 2
            ))
        case .list:
            bounds = bounds.union(CGRect(x: -44, y: 0, width: 44, height: bounds.height))
        // A picture or transclusion that took a list line's widget slot draws
        // that list's bullet in the same gutter, and a clip starting at the
        // fragment's own origin shaves it off completely. A quote's card is
        // painted back to the container's own edge, which is further still.
        case .image(_, let lead), .embed(_, let lead):
            if lead.quote != nil {
                bounds = bounds.union(CGRect(
                    x: -lead.indent, y: -2, width: containerWidth, height: bounds.height + 4
                ))
            } else if lead.bullet != nil {
                bounds = bounds.union(CGRect(x: -44, y: 0, width: 44, height: bounds.height))
            }
        case .quote(_, let indent, _, _):
            // The card and the bars are painted in the gutter the paragraph's
            // head indent opened up, which is to the left of every glyph.
            // Only a little vertical slack, for the callout icon centred on a
            // line box that may be shorter than it is. Anything more and the
            // card paints over the paragraph below.
            bounds = bounds.union(CGRect(
                x: -indent, y: -2, width: containerWidth, height: bounds.height + 4
            ))
        default:
            break
        }
        // A tag pill is wider than the glyphs it sits behind, and the clip is
        // sized to the glyphs, so without this the rounded ends are shaved off.
        if !inlineTags.isEmpty {
            bounds = bounds.insetBy(dx: -(Self.tagPadding + 1), dy: -(Self.tagInset + 1))
        }
        return bounds
    }

    /// System colours resolve against `NSAppearance.current`, which is not set
    /// during fragment drawing. Without this the gutter glyphs are painted in
    /// the light-mode palette and vanish against a dark editor.
    override func draw(at point: CGPoint, in context: CGContext) {
        guard let appearance = textLayoutManager?.textContainer?.textView?.effectiveAppearance else {
            drawContents(at: point, in: context)
            return
        }
        appearance.performAsCurrentDrawingAppearance {
            drawContents(at: point, in: context)
        }
    }

    private func drawContents(at point: CGPoint, in context: CGContext) {
        if case .codeBlock(let edge, let language) = widget {
            drawCodeBlockBackground(edge: edge, language: language, at: point, in: context)
        }
        if case .quote(let quote, let indent, let isRevealed, _) = widget {
            drawQuoteBackground(
                quote, indent: indent, isRevealed: isRevealed, at: point, in: context
            )
        }
        // The same card, for a line a picture or transclusion took over. It is
        // painted from the fragment's own origin back by the indent, so the
        // indent the block was laid out at is the one to pass.
        if let lead = blockLead, let quote = lead.quote {
            drawQuoteBackground(
                quote.line, indent: lead.indent, isRevealed: quote.isRevealed,
                at: point, in: context
            )
        }
        switch widget {
        case .blockMath(let image):
            // The source is fully collapsed, so there is no text to draw.
            drawCentred(image, size: image.size, at: point, in: context)
            return
        case .image(let image, let lead):
            let size = Self.displaySize(for: image)
            drawBesideBlock(lead.bullet, height: size.height, at: point, in: context)
            drawLeading(image, size: size, at: point, in: context)
            return
        case .table(let grid):
            draw(grid, at: point, in: context)
            return
        case .embed(let embed, let lead):
            drawBesideBlock(lead.bullet, height: embed.size.height, at: point, in: context)
            draw(embed, at: point, in: context)
            return
        case .properties(let card):
            draw(card, at: point, in: context)
            return
        default:
            break
        }

        // Behind the glyphs, so it has to precede the text, not follow it.
        for tag in inlineTags { drawTagPill(tag, at: point, in: context) }

        super.draw(at: point, in: context)

        switch widget {
        case .list(let glyph, let markerOffset, let fontSize):
            draw(glyph, markerOffset: markerOffset, fontSize: fontSize, at: point, in: context)
        case .headingAccent(_, let color):
            drawHeadingAccent(color: color, at: point, in: context)
        case .thematicBreak:
            drawThematicBreak(at: point, in: context)
        case .agentGuide(let isEnd):
            drawAgentGuideBoundary(isEnd: isEnd, at: point, in: context)
        case .quote(_, _, let isRevealed, let bullet):
            // Nothing drawn while the source shows, for the same reason a
            // plain list draws nothing then: the real `- ` is on screen and
            // the glyph would sit beside it.
            if let bullet, !isRevealed {
                draw(
                    bullet.glyph, markerOffset: bullet.markerOffset,
                    fontSize: bullet.fontSize, at: point, in: context
                )
            }
        default:
            break
        }

        for item in inlineMath { drawInline(item, at: point, in: context) }
    }

    private func drawCodeBlockBackground(
        edge: CodeBlockEdge,
        language: String?,
        at point: CGPoint,
        in context: CGContext
    ) {
        guard let line = textLineFragments.first else { return }
        let radius: CGFloat = 7
        let rect = CGRect(
            x: point.x - 10,
            y: point.y,
            width: containerWidth,
            height: max(line.typographicBounds.height, layoutFragmentFrame.height)
        )

        context.saveGState()
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        switch edge {
        case .only:
            let path = CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.75)
            context.addPath(path)
            context.strokePath()
        case .first:
            paintCodeBlockEdge(
                roundedRect: CGRect(
                    x: rect.minX, y: rect.minY,
                    width: rect.width, height: rect.height + radius
                ), clippedTo: rect, in: context
            )
        case .middle:
            context.fill(rect)
            strokeCodeBlockSides(of: rect, in: context)
        case .last:
            paintCodeBlockEdge(
                roundedRect: CGRect(
                    x: rect.minX, y: rect.minY - radius,
                    width: rect.width, height: rect.height + radius
                ), clippedTo: rect, in: context
            )
        }
        context.restoreGState()

        guard (edge == .first || edge == .only), let language, !language.isEmpty else { return }
        let label = NSAttributedString(string: language.uppercased(), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = label.size()
        withAppKitContext(context) {
            label.draw(at: CGPoint(x: rect.maxX - size.width - 9, y: rect.minY + 5))
        }
    }

    // MARK: Quotes and callouts

    /// Paints one line's share of a quote bar, or of a callout's card.
    ///
    /// The block is drawn a paragraph at a time because that is the unit a
    /// layout fragment covers. Continuity comes from the rounded rectangle
    /// being oversized past the edges this line does not own and then clipped
    /// back to it, which is the same trick the code-block background uses.
    private func drawQuoteBackground(
        _ quote: QuoteLine, indent: CGFloat, isRevealed: Bool,
        at point: CGPoint, in context: CGContext
    ) {
        guard let line = textLineFragments.first else { return }
        let left = point.x - indent
        let tint = Theme.calloutNSTint(quote.callout)

        // Both `paragraphSpacingBefore` and `paragraphSpacing` land *inside*
        // the layout fragment, so the padding at each end of the block is
        // already part of this height. Adding it again on the closing line
        // pushed the card a whole line past the block and it was drawn over
        // the paragraph underneath.
        let rect = CGRect(
            x: left, y: point.y, width: containerWidth,
            height: max(line.typographicBounds.height, layoutFragmentFrame.height)
        )

        context.saveGState()
        // No alpha adjustment on the neutral fill: `withAlphaComponent` on a
        // dynamic system colour resolves it there and then, outside the
        // appearance this is being drawn in, which turned the dark-mode quote
        // into a near-white slab.
        context.setFillColor(
            quote.isCallout
                ? tint.withAlphaComponent(0.11).cgColor
                : NSColor.quaternarySystemFill.cgColor
        )
        fill(rect, edge: quote.edge, radius: 8, in: context)
        context.restoreGState()

        // Only a plain quote gets bars, one per nesting level so `> >` reads as
        // two. A callout already announces itself with a tinted card and an
        // icon, and a coloured stripe on top of that is just noise.
        if !quote.isCallout {
            context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
            for level in 0..<max(1, quote.depth) {
                let x = left + 5 + CGFloat(level) * 18
                context.fill(CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
            }
        }

        guard quote.isCalloutHeader else { return }
        drawCalloutIcon(
            quote, tint: tint, at: CGPoint(x: left + 16, y: point.y),
            line: line, isRevealed: isRevealed, in: context
        )
    }

    /// Rounds only the corners this line actually owns.
    /// The rounded rect to fill for one line of a multi-line quote or callout.
    ///
    /// Each line is filled separately, clipped to its own slice, so a corner
    /// is only round where the block genuinely ends. The rect is therefore
    /// pushed `radius` past every end the block continues through, putting
    /// those corners outside the clip and leaving a straight edge to meet the
    /// next line with.
    static func grownFill(_ rect: CGRect, edge: QuoteEdge, radius: CGFloat) -> CGRect {
        let opensAbove = edge != .first   // .first owns the top of the card
        let opensBelow = edge != .last    // .last owns the bottom
        return CGRect(
            x: rect.minX,
            y: opensAbove ? rect.minY - radius : rect.minY,
            width: rect.width,
            height: rect.height
                + (opensAbove ? radius : 0)
                + (opensBelow ? radius : 0)
        )
    }

    private func fill(_ rect: CGRect, edge: QuoteEdge, radius: CGFloat, in context: CGContext) {
        switch edge {
        case .only:
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.fillPath()
        case .first, .last, .middle:
            // Grow past every *open* end, so those corners fall outside the
            // clip and the fill meets the neighbouring paragraph with a
            // straight edge. A middle line has two open ends and must grow at
            // both: growing only downwards left its rounded top corners
            // sitting on the clip's edge, so every interior line of a callout
            // drew its own little roof and the card came out notched.
            let grown = Self.grownFill(rect, edge: edge, radius: radius)
            context.saveGState()
            context.clip(to: rect)
            context.addPath(CGPath(
                roundedRect: grown, cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }
    }

    private static let symbolCache = NSCache<NSString, NSImage>()

    /// An SF Symbol drawn in `tint`, with its detail intact.
    ///
    /// Not `SymbolConfiguration(paletteColors:)`, which is the obvious way and
    /// silently **flattens the symbol**: every `.fill` symbol comes out as a
    /// solid silhouette, so `pencil.circle.fill` is a plain disc and
    /// `info.circle.fill` a plain disc too. It is wrong on screen as well as
    /// in a PDF; it simply reads as "a coloured blob" at 14pt and was noticed
    /// only once an export made it big enough to look at.
    ///
    /// A template image keeps the knocked-out detail but ignores the fill
    /// colour, so the two are combined: draw the mask, then recolour it with
    /// `.sourceIn`, which repaints every opaque pixel and leaves the negative
    /// space transparent — so the callout's own card shows through the pencil,
    /// which is what Obsidian does.
    static func tintedSymbol(_ name: String, side: CGFloat, tint: NSColor) -> NSImage? {
        let key = "\(name)|\(side)|\(tint.hexish)" as NSString
        if let hit = symbolCache.object(forKey: key) { return hit }

        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: side * 0.86, weight: .semibold)
            )
        else { return nil }
        glyph.isTemplate = true

        let box = NSRect(x: 0, y: 0, width: side, height: side)
        let tinted = NSImage(size: box.size)
        tinted.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        box.fill(using: .sourceIn)
        tinted.unlockFocus()

        symbolCache.setObject(tinted, forKey: key)
        return tinted
    }

    private func drawCalloutIcon(
        _ quote: QuoteLine, tint: NSColor, at origin: CGPoint,
        line: NSTextLineFragment, isRevealed: Bool, in context: CGContext
    ) {
        let side: CGFloat = 14
        let centreY = origin.y + line.typographicBounds.midY
        guard let symbol = Self.tintedSymbol(
            quote.callout?.symbol ?? "quote.bubble.fill", side: side, tint: tint
        ) else { return }

        withAppKitContext(context) {
            symbol.draw(
                in: CGRect(x: origin.x, y: centreY - side / 2, width: side, height: side),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil
            )

            // `> [!tip]` with nothing after it still shows a heading in
            // Obsidian: the kind's own name. There is no text on the line to
            // style into one, so it is drawn — but only while the source is
            // hidden. With the caret on the line the literal `> [!tip]` is
            // visible in exactly that spot, and both would be painted over
            // each other.
            guard !isRevealed, quote.needsDrawnTitle, let raw = quote.rawCallout
            else { return }
            let label = NSAttributedString(string: raw.capitalized, attributes: [
                .font: NSFont.systemFont(ofSize: Theme.bodySize, weight: .semibold),
                .foregroundColor: tint,
            ])
            label.draw(at: CGPoint(
                x: origin.x + side + 6, y: centreY - label.size().height / 2
            ))
        }
    }

    private func paintCodeBlockEdge(
        roundedRect: CGRect,
        clippedTo clip: CGRect,
        in context: CGContext
    ) {
        let path = CGPath(
            roundedRect: roundedRect, cornerWidth: 7, cornerHeight: 7, transform: nil
        )
        context.saveGState()
        context.clip(to: clip)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.75)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func strokeCodeBlockSides(of rect: CGRect, in context: CGContext) {
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.75)
        context.beginPath()
        context.move(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.strokePath()
    }

    // MARK: Blocks

    static func displaySize(for image: NSImage) -> CGSize {
        let natural = image.size
        guard natural.width > 0 else { return natural }
        let maxWidth: CGFloat = 460
        guard natural.width > maxWidth else { return natural }
        return CGSize(width: maxWidth, height: natural.height * (maxWidth / natural.width))
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    private func drawCentred(_ image: NSImage, size: CGSize, at point: CGPoint, in context: CGContext) {
        let origin = CGPoint(
            x: point.x + max(0, (containerWidth - size.width) / 2),
            y: point.y + Self.blockInset
        )
        paint(image, in: CGRect(origin: origin, size: size), context: context)
    }

    private func drawLeading(_ image: NSImage, size: CGSize, at point: CGPoint, in context: CGContext) {
        let rect = CGRect(
            origin: CGPoint(x: point.x, y: point.y + Self.blockInset), size: size
        )
        context.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(clip)
        context.clip()
        paint(image, in: rect, context: context)
        context.restoreGState()
    }

    private func draw(_ card: PropertiesCard, at point: CGPoint, in context: CGContext) {
        let frame = CGRect(
            origin: CGPoint(x: point.x, y: point.y + Self.blockInset), size: card.size
        )
        // A separator underneath rather than a box around: properties are the
        // note's header, and a card would make them look like content.
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: frame.minX, y: (frame.maxY).rounded() + 0.5))
        context.addLine(to: CGPoint(x: frame.maxX, y: (frame.maxY).rounded() + 0.5))
        context.strokePath()

        let padding = PropertiesCard.padding
        withAppKitContext(context) {
            for (index, row) in card.rows.enumerated() {
                let y = frame.minY + padding.height + CGFloat(index) * PropertiesCard.rowHeight
                row.key.draw(at: CGPoint(x: frame.minX + padding.width, y: y + 3))

                var x = frame.minX + padding.width + card.keyColumnWidth + PropertiesCard.gutter
                for value in row.values {
                    let width = ceil(value.size().width)
                    guard x + width < frame.maxX - padding.width else { break }
                    if row.isTagRow {
                        let pill = CGRect(x: x - 6, y: y + 1, width: width + 12, height: 18)
                        context.setFillColor(NSColor.systemPurple.withAlphaComponent(0.14).cgColor)
                        context.addPath(CGPath(
                            roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil
                        ))
                        context.fillPath()
                    }
                    value.draw(at: CGPoint(x: x, y: y + 2))
                    x += width + (row.isTagRow ? 20 : 10)
                }
            }
        }
    }

    private func draw(_ embed: EmbeddedNote, at point: CGPoint, in context: CGContext) {
        let frame = CGRect(
            origin: CGPoint(x: point.x, y: point.y + Self.blockInset), size: embed.size
        )
        let outline = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)

        // Semantic fills already carry a deliberately low, appearance-aware
        // alpha. `withAlphaComponent(0.5)` replaced that alpha with 50%, which
        // made the card glaring white in dark mode and charcoal in light mode.
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        context.addPath(outline)
        context.fillPath()
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.75)
        context.addPath(outline)
        context.strokePath()

        let padding = EmbeddedNote.padding
        withAppKitContext(context) {
            NSAttributedString(string: embed.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: CGPoint(x: frame.minX + padding.width, y: frame.minY + padding.height - 3))

            // A note longer than the card is cut off rather than allowed to
            // paint over the paragraphs below it.
            context.saveGState()
            context.addPath(outline)
            context.clip()
            embed.body.draw(
                with: CGRect(
                    x: frame.minX + padding.width,
                    y: frame.minY + padding.height + EmbedRenderer.titleHeight,
                    width: frame.width - padding.width * 2,
                    height: frame.height - padding.height * 2 - EmbedRenderer.titleHeight
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            context.restoreGState()
        }

        guard embed.isTruncated else { return }
        // Fade the cut edge, so a clipped line reads as "there is more" rather
        // than as a rendering fault.
        context.saveGState()
        context.addPath(outline)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.textBackgroundColor.withAlphaComponent(0).cgColor,
                NSColor.textBackgroundColor.cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: frame.minX, y: frame.maxY - 34),
                end: CGPoint(x: frame.minX, y: frame.maxY),
                options: []
            )
        }
        context.restoreGState()
    }

    private func draw(_ grid: TableGrid, at point: CGPoint, in context: CGContext) {
        guard grid.size.height > 0 else { return }
        let origin = CGPoint(x: point.x, y: point.y + Self.blockInset)
        let frame = CGRect(origin: origin, size: grid.size)

        context.saveGState()
        let border = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)

        // Header band, clipped to the rounded outline so its top corners round.
        context.addPath(border)
        context.clip()
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        context.fill(CGRect(
            x: frame.minX, y: frame.minY, width: frame.width, height: grid.headerHeight
        ))
        context.restoreGState()

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)

        var y = frame.minY
        for height in grid.rowHeights.dropLast() {
            y += height
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        var x = frame.minX
        for width in grid.columnWidths.dropLast() {
            x += width
            context.move(to: CGPoint(x: x, y: frame.minY))
            context.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        context.strokePath()

        context.addPath(border)
        context.strokePath()

        if let active = grid.active, let cell = grid.cell(row: active.row, column: active.column) {
            drawActiveCell(cell, in: grid, origin: origin, context: context)
        }

        withAppKitContext(context) {
            for cell in grid.cells {
                cell.text.draw(with: CGRect(
                    x: origin.x + cell.rect.minX + grid.alignmentOffset(for: cell),
                    y: origin.y + cell.rect.minY,
                    width: cell.rect.width,
                    height: cell.rect.height
                ), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }

        if grid.active != nil { drawTableAffordances(grid, origin: origin, in: context) }
    }

    /// A tinted box around the cell being edited.
    ///
    /// Without it the table reads as static rendered output that has somehow
    /// grown a caret. The box is what says "this one is text you are typing
    /// into, the rest is a picture of your table".
    private func drawActiveCell(
        _ cell: TableGrid.Cell, in grid: TableGrid, origin: CGPoint, context: CGContext
    ) {
        let box = CGRect(
            x: origin.x + cell.rect.minX - TableGrid.padding.width + 1,
            y: origin.y + cell.rect.minY - TableGrid.padding.height + 1,
            width: cell.rect.width + TableGrid.padding.width * 2 - 2,
            height: cell.rect.height + TableGrid.padding.height * 2 - 2
        )
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.saveGState()
        context.setFillColor(grid.accent.withAlphaComponent(0.10).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(grid.accent.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// The `+` strips below and beside an active table.
    ///
    /// Only drawn while the caret is in the table, but the space they occupy is
    /// reserved always: appearing and disappearing is free, growing and
    /// shrinking would shove the rest of the note about on every click.
    private func drawTableAffordances(
        _ grid: TableGrid, origin: CGPoint, in context: CGContext
    ) {
        for rect in [grid.addRowRect, grid.addColumnRect] {
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.width > 4, frame.height > 4 else { continue }
            let path = CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.saveGState()
            context.setFillColor(NSColor.quaternarySystemFill.cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            context.addPath(path)
            context.strokePath()

            let arm = min(4.5, min(frame.width, frame.height) / 2 - 2)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: frame.midX - arm, y: frame.midY))
            context.addLine(to: CGPoint(x: frame.midX + arm, y: frame.midY))
            context.move(to: CGPoint(x: frame.midX, y: frame.midY - arm))
            context.addLine(to: CGPoint(x: frame.midX, y: frame.midY + arm))
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: Line decoration

    /// The bullet whose line a picture or transclusion has taken over.
    ///
    /// Aligned near the top of the block rather than centred on it: the line is
    /// as tall as the picture, and a bullet floating halfway down a 400pt
    /// photograph does not read as belonging to the item it starts.
    private func drawBesideBlock(
        _ bullet: LeadingBullet?, height: CGFloat, at point: CGPoint, in context: CGContext
    ) {
        guard let bullet else { return }
        draw(
            bullet.glyph, markerOffset: bullet.markerOffset, fontSize: bullet.fontSize,
            at: point, in: context,
            centredAt: point.y + Self.blockInset + bullet.fontSize * 0.62
        )
    }

    private func draw(
        _ glyph: ListGlyph, markerOffset: CGFloat, fontSize: CGFloat,
        at point: CGPoint, in context: CGContext, centredAt overrideY: CGFloat? = nil
    ) {
        guard let line = textLineFragments.first else { return }
        let centreY = overrideY ?? (point.y + line.typographicBounds.midY)
        // The fragment is already positioned at the paragraph's head indent, so
        // the text's leading edge is the origin and the gutter is behind it.
        // Deriving this from `indent` instead would double-count the indent.
        let textLeft = point.x + line.typographicBounds.minX
        let markerCentre = textLeft + markerOffset

        switch glyph {
        case .bullet(let shape):
            // One optical size for all three. A stroked ring and a square both
            // read larger than a filled dot of the same radius, so the ring
            // keeps the dot's outer edge and the square is drawn slightly
            // smaller than its bounding circle would be.
            let radius: CGFloat = 2.75
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            switch shape {
            case .disc:
                context.fillEllipse(in: CGRect(
                    x: markerCentre - radius, y: centreY - radius,
                    width: radius * 2, height: radius * 2
                ))
            case .circle:
                let line: CGFloat = 1.2
                context.setLineWidth(line)
                context.strokeEllipse(in: CGRect(
                    x: markerCentre - radius + line / 2,
                    y: centreY - radius + line / 2,
                    width: radius * 2 - line, height: radius * 2 - line
                ))
            case .square:
                let side = radius * 1.8
                context.fill(CGRect(
                    x: markerCentre - side / 2, y: centreY - side / 2,
                    width: side, height: side
                ))
            }

        case .ordered(let label):
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.92),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            withAppKitContext(context) {
                text.draw(at: CGPoint(
                    x: markerCentre - size.width / 2, y: centreY - size.height / 2
                ))
            }

        case .checkbox(let state, let accent):
            let side: CGFloat = 13
            let box = CGRect(
                x: markerCentre - side / 2, y: centreY - side / 2,
                width: side, height: side
            )
            let path = CGPath(roundedRect: box, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            switch state {
            case .done:
                context.setFillColor(accent.cgColor)
                context.addPath(path)
                context.fillPath()
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.8)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: box.minX + 3.2, y: box.midY + 0.2))
                context.addLine(to: CGPoint(x: box.minX + 5.4, y: box.maxY - 3.4))
                context.addLine(to: CGPoint(x: box.maxX - 3.0, y: box.minY + 3.6))
                context.strokePath()
            case .unchecked:
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                context.setLineWidth(1.3)
                context.addPath(path)
                context.strokePath()
            case .other(let marker):
                // The character itself inside the box, which is what the
                // conventions mean and what every theme that popularised them
                // draws: `/` in progress, `-` abandoned, `?` uncertain. Drawing
                // a tick or a blank instead would state something the author
                // did not write.
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(1.3)
                context.addPath(path)
                context.strokePath()
                let glyph = NSAttributedString(
                    string: String(marker),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: side * 0.72, weight: .semibold),
                        .foregroundColor: accent,
                    ]
                )
                let size = glyph.size()
                glyph.draw(at: CGPoint(
                    x: box.midX - size.width / 2,
                    y: box.midY - size.height / 2
                ))
            }
        }
    }

    private func drawHeadingAccent(color: NSColor, at point: CGPoint, in context: CGContext) {
        guard let line = textLineFragments.first else { return }
        let lineBounds = line.typographicBounds
        let height = max(8, lineBounds.height - 8)
        let rect = CGRect(
            x: point.x - 12,
            y: point.y + lineBounds.midY - height / 2,
            width: 3,
            height: height
        )
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
    }

    /// A rule with the boundary's meaning written on it. The label is drawn
    /// rather than stored in the note: it is the editor explaining a marker,
    /// not text the vault should carry to every other program.
    private func drawAgentGuideBoundary(
        isEnd: Bool, at point: CGPoint, in context: CGContext
    ) {
        guard let line = textLineFragments.first else { return }
        let y = (point.y + line.typographicBounds.midY).rounded() + 0.5
        let label = AgentGuide.boundaryLabel(isEnd: isEnd)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let gap: CGFloat = 8
        let textX = point.x + max(0, (containerWidth - size.width) / 2)

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        if textX - gap > point.x {
            context.move(to: CGPoint(x: point.x, y: y))
            context.addLine(to: CGPoint(x: textX - gap, y: y))
        }
        let rightStart = textX + size.width + gap
        if rightStart < point.x + containerWidth {
            context.move(to: CGPoint(x: rightStart, y: y))
            context.addLine(to: CGPoint(x: point.x + containerWidth, y: y))
        }
        context.strokePath()
        text.draw(at: CGPoint(x: textX, y: y - size.height / 2))
    }

    private func drawThematicBreak(at point: CGPoint, in context: CGContext) {
        guard let line = textLineFragments.first else { return }
        let y = (point.y + line.typographicBounds.midY).rounded() + 0.5
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: point.x, y: y))
        context.addLine(to: CGPoint(x: point.x + containerWidth, y: y))
        context.strokePath()
    }

    /// Paints a formula into the gap that `LiveStyler` reserved with kerning.
    private func drawInline(
        _ item: (location: Int, image: NSImage), at point: CGPoint, in context: CGContext
    ) {
        let index = item.location - elementStart
        guard index >= 0 else { return }
        for line in textLineFragments {
            let range = line.characterRange
            guard index >= range.location, index < NSMaxRange(range) else { continue }
            let local = line.locationForCharacter(at: index)
            let bounds = line.typographicBounds
            let size = item.image.size
            // Sit on the text baseline, not in the middle of the line box. The
            // baseline is below the box's centre, so centring the formula makes
            // it ride visibly high above the words around it. The fraction is
            // how much of a typeset expression hangs below the baseline: enough
            // for parentheses and subscripts to clear the following line.
            let baseline = point.y + bounds.minY + line.glyphOrigin.y
            let origin = CGPoint(
                x: point.x + bounds.minX + local.x + 1,
                y: baseline - size.height + max(2, size.height * 0.24)
            )
            paint(item.image, in: CGRect(origin: origin, size: size), context: context)
            return
        }
    }

    /// Horizontal room between a tag's text and the end of its pill, and how
    /// far the pill extends past the text's ascender and descender.
    /// `LiveStyler` kerns the neighbouring spaces by `tagPadding` so the pill
    /// has that room to overhang into, so the two must agree.
    static let tagPadding: CGFloat = 5
    private static let tagInset: CGFloat = 1.5

    /// The rounded capsule behind a `#tag`, which is Obsidian's treatment and
    /// cannot be had from a `.backgroundColor` attribute.
    private func drawTagPill(
        _ tag: (range: NSRange, color: NSColor, font: NSFont, ink: CGRect),
        at point: CGPoint, in context: CGContext
    ) {
        let start = tag.range.location - elementStart
        guard start >= 0 else { return }

        for line in textLineFragments {
            let lineRange = line.characterRange
            guard start >= lineRange.location, start < NSMaxRange(lineRange) else { continue }

            // A tag has no spaces in it and so never wraps: it ends on the
            // line it starts on, and its width is the ink measured at style
            // time. Taking the width from the *next* character's position
            // instead would have to clamp at a line's last character, and
            // would silently come out short for a tag that ends a line.
            let leading = line.locationForCharacter(at: start).x
            guard tag.ink.width > 0 else { return }

            // Horizontally the pill hugs the ink, not the advance box the
            // glyphs sit in: `#` has a wider side bearing than most letters
            // end with, so a pill on the advance box looks shifted left.
            //
            // Vertically it is sized off the font instead, and deliberately:
            // ascender to descender is the same band for every tag, whereas
            // ink is not, and pills that changed height depending on whether
            // the word happened to contain a `p` would be worse than
            // slightly uneven ones. A line box is no good either, being
            // taller than its glyphs with the text sitting at the bottom.
            let bounds = line.typographicBounds
            let baseline = point.y + bounds.minY + line.glyphOrigin.y
            let rect = CGRect(
                x: point.x + bounds.minX + leading + tag.ink.minX - Self.tagPadding,
                y: baseline - tag.font.ascender - Self.tagInset,
                width: tag.ink.width + Self.tagPadding * 2,
                height: tag.font.ascender - tag.font.descender + Self.tagInset * 2
            )
            // Safe to resolve here, unlike at styling time: `draw(at:in:)` has
            // already made the view's appearance current.
            context.setFillColor(
                tag.color.withAlphaComponent(Theme.tagBackgroundOpacity).cgColor
            )
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                transform: nil
            ))
            context.fillPath()
            return
        }
    }

    // MARK: Drawing helpers

    private func paint(_ image: NSImage, in rect: CGRect, context: CGContext) {
        withAppKitContext(context) {
            // `respectFlipped` is not optional here: without it the image is
            // drawn upside down, because the text container is flipped.
            image.draw(
                in: rect, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil
            )
        }
    }

    private func withAppKitContext(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
