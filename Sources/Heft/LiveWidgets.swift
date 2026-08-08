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
            revealedLine: NSRange(location: NSNotFound, length: 0),
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
