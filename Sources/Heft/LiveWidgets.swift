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
    case list(glyph: ListGlyph, indent: CGFloat, fontSize: CGFloat)
    /// A compact, level-coloured indicator beside a heading.
    case headingAccent(level: Int)
    case codeBlock(edge: CodeBlockEdge, language: String?)
    case thematicBreak
    case blockMath(NSImage)
    case image(NSImage)
    /// Drawn as a grid; the widget owns every line of the table.
    case table(TableGrid)
    /// One line's slice of a quote bar, or of a callout's tinted card.
    /// `isRevealed` means the line's real source is on screen, so nothing may
    /// be drawn where that source sits.
    case quote(QuoteLine, indent: CGFloat, isRevealed: Bool)
    /// Another note's content, transcluded by `![[Note]]`.
    case embed(EmbeddedNote)
    /// YAML frontmatter, drawn as a key/value table.
    case properties(PropertiesCard)
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
    case bullet
    case ordered(String)
    case checkbox(Bool)
}

/// Widget placement for one restyle pass, keyed by the document offset of the
/// line each widget belongs to.
struct LiveLayout {
    var blocks: [Int: BlockWidget] = [:]
    /// Formulae drawn inside a line, keyed by that line's start offset.
    var inlineMath: [Int: [(location: Int, image: NSImage)]] = [:]
    /// Ranges of the inline spans that reveal on the caret rather than on their
    /// line. The editor keeps these to tell an ordinary cursor move apart from
    /// one that crosses into or out of a span and so needs a restyle.
    var revealableSpans: [NSRange] = []

    /// Cheap identity for "did the set of widgets change". Compared to decide
    /// whether a full layout invalidation is needed; the images themselves are
    /// deliberately not part of it, because editing inside a formula already
    /// invalidates that paragraph through its attributes.
    var signature: String {
        let blockKeys = blocks.keys.sorted().map(String.init).joined(separator: ",")
        let mathKeys = inlineMath.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        return blockKeys + "|" + mathKeys
    }
}

// MARK: - Table measurement

/// A table measured into concrete rectangles, so drawing is a straight paint.
struct TableGrid {
    struct Cell {
        let text: NSAttributedString
        let rect: CGRect
        let alignment: MDColumnAlignment
    }

    var cells: [Cell] = []
    var rowHeights: [CGFloat] = []
    var columnWidths: [CGFloat] = []
    var size: CGSize = .zero
    var headerHeight: CGFloat = 0

    static let padding = CGSize(width: 11, height: 7)

    /// Measuring a table styles every cell, which is far too much work to redo
    /// on each caret move. Keyed by everything the result depends on.
    private struct CacheKey: Hashable {
        let layout: TableLayout
        let maxWidth: CGFloat
        let fontSize: CGFloat
        let vault: String
    }

    private static var cache: [CacheKey: TableGrid] = [:]

    static func measure(
        _ layout: TableLayout, maxWidth: CGFloat, context: RenderContext, fontSize: CGFloat
    ) -> TableGrid {
        let key = CacheKey(
            layout: layout, maxWidth: maxWidth, fontSize: fontSize,
            // Link colour inside a cell depends on whether the target resolves,
            // so a changed index must not reuse an earlier measurement.
            vault: "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")"
        )
        if let hit = cache[key] { return hit }
        let grid = compute(layout, maxWidth: maxWidth, context: context, fontSize: fontSize)
        // Plain eviction: notes hold a handful of tables, and the key changes
        // on every window resize, so the map must not grow without bound.
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = grid
        return grid
    }

    /// Lays the table out within `maxWidth`. Columns take their natural width
    /// where they fit, and are scaled down proportionally when they do not.
    private static func compute(
        _ layout: TableLayout, maxWidth: CGFloat, context: RenderContext, fontSize: CGFloat
    ) -> TableGrid {
        let columnCount = layout.columnCount
        guard columnCount > 0, !layout.rows.isEmpty else { return TableGrid() }

        // Every cell is styled through the same decorator the prose uses, so a
        // link or `**bold**` inside a cell looks the same as it does outside.
        let styled: [[NSAttributedString]] = layout.rows.enumerated().map { rowIndex, row in
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
        var natural = [CGFloat](repeating: 0, count: columnCount)
        for row in styled {
            for (column, cell) in row.enumerated() {
                let bounds = cell.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                natural[column] = max(natural[column], ceil(bounds.width) + 1 + padding.width * 2)
            }
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

        var grid = TableGrid()
        grid.columnWidths = widths

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
                grid.cells.append(Cell(
                    text: entry.0,
                    rect: CGRect(
                        x: x + padding.width, y: y + padding.height,
                        width: entry.1, height: height - padding.height * 2
                    ),
                    alignment: column < layout.alignments.count ? layout.alignments[column] : .leading
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
    static func render(
        _ source: String, bold: Bool, fontSize: CGFloat, context: RenderContext
    ) -> NSAttributedString {
        let base = bold
            ? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: fontSize)
        let storage = NSTextStorage(string: source, attributes: [
            .font: base,
            .foregroundColor: NSColor.labelColor,
        ])
        // Reuse the prose styler so cells and body text cannot drift apart.
        // Nothing is revealed: a cell is never the caret's line, because a
        // table with the caret in it is shown as source instead of drawn.
        _ = LiveStyler.apply(
            to: storage,
            reveal: .none,
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
        case .image(let image): Self.displaySize(for: image)
        case .table(let grid): grid.size
        case .embed(let embed): embed.size
        case .properties(let card): card.size
        default: nil
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
                width: max(bounds.width, containerWidth, contentSize.width) + 2,
                height: contentSize.height + Self.blockInset * 2
            ))
        }
        // Heading accents and list glyphs draw into the gutter to the left.
        switch widget {
        case .thematicBreak:
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
        case .quote(_, let indent, _):
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
        if case .quote(let quote, let indent, let isRevealed) = widget {
            drawQuoteBackground(
                quote, indent: indent, isRevealed: isRevealed, at: point, in: context
            )
        }
        switch widget {
        case .blockMath(let image):
            // The source is fully collapsed, so there is no text to draw.
            drawCentred(image, size: image.size, at: point, in: context)
            return
        case .image(let image):
            drawLeading(image, size: Self.displaySize(for: image), at: point, in: context)
            return
        case .table(let grid):
            draw(grid, at: point, in: context)
            return
        case .embed(let embed):
            draw(embed, at: point, in: context)
            return
        case .properties(let card):
            draw(card, at: point, in: context)
            return
        default:
            break
        }

        super.draw(at: point, in: context)

        switch widget {
        case .list(let glyph, let indent, let fontSize):
            draw(glyph, indent: indent, fontSize: fontSize, at: point, in: context)
        case .headingAccent(let level):
            drawHeadingAccent(level: level, at: point, in: context)
        case .thematicBreak:
            drawThematicBreak(at: point, in: context)
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
    private func fill(_ rect: CGRect, edge: QuoteEdge, radius: CGFloat, in context: CGContext) {
        switch edge {
        case .only:
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.fillPath()
        case .first, .last, .middle:
            // Grow past the open end so its corners fall outside the clip and
            // the fill meets the neighbouring paragraph with a straight edge.
            let grown = CGRect(
                x: rect.minX,
                y: edge == .last ? rect.minY - radius : rect.minY,
                width: rect.width,
                height: rect.height + (edge == .middle ? radius * 2 : radius)
            )
            context.saveGState()
            context.clip(to: rect)
            context.addPath(CGPath(
                roundedRect: grown, cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }
    }

    private func drawCalloutIcon(
        _ quote: QuoteLine, tint: NSColor, at origin: CGPoint,
        line: NSTextLineFragment, isRevealed: Bool, in context: CGContext
    ) {
        let side: CGFloat = 14
        let centreY = origin.y + line.typographicBounds.midY
        guard let symbol = NSImage(
            systemSymbolName: quote.callout?.symbol ?? "quote.bubble.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
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

        context.setFillColor(NSColor.quaternarySystemFill.withAlphaComponent(0.5).cgColor)
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

        withAppKitContext(context) {
            for cell in grid.cells {
                let bounds = cell.text.boundingRect(
                    with: CGSize(width: cell.rect.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let offset: CGFloat = switch cell.alignment {
                case .leading: 0
                case .center: max(0, (cell.rect.width - bounds.width) / 2)
                case .trailing: max(0, cell.rect.width - bounds.width)
                }
                cell.text.draw(with: CGRect(
                    x: origin.x + cell.rect.minX + offset,
                    y: origin.y + cell.rect.minY,
                    width: cell.rect.width,
                    height: cell.rect.height
                ), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    // MARK: Line decoration

    private func draw(
        _ glyph: ListGlyph, indent: CGFloat, fontSize: CGFloat, at point: CGPoint, in context: CGContext
    ) {
        guard let line = textLineFragments.first else { return }
        let centreY = point.y + line.typographicBounds.midY
        // The fragment is already positioned at the paragraph's head indent, so
        // the text's leading edge is the origin and the gutter is behind it.
        // Deriving this from `indent` instead would double-count the indent.
        let textLeft = point.x + line.typographicBounds.minX

        switch glyph {
        case .bullet:
            let radius: CGFloat = 2.75
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.fillEllipse(in: CGRect(
                x: textLeft - 16 - radius, y: centreY - radius,
                width: radius * 2, height: radius * 2
            ))

        case .ordered(let label):
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.92),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            withAppKitContext(context) {
                text.draw(at: CGPoint(
                    x: textLeft - 9 - size.width, y: centreY - size.height / 2
                ))
            }

        case .checkbox(let checked):
            let side: CGFloat = 13
            let box = CGRect(
                x: textLeft - 20, y: centreY - side / 2, width: side, height: side
            )
            let path = CGPath(roundedRect: box, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            if checked {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
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
            } else {
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                context.setLineWidth(1.3)
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    private func drawHeadingAccent(level: Int, at point: CGPoint, in context: CGContext) {
        guard let line = textLineFragments.first else { return }
        let lineBounds = line.typographicBounds
        let height = max(8, lineBounds.height - 8)
        let rect = CGRect(
            x: point.x - 12,
            y: point.y + lineBounds.midY - height / 2,
            width: 3,
            height: height
        )
        context.setFillColor(Theme.headingAccentNSColor(level).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
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
