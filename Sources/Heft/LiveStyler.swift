import AppKit
import HeftCore

/// Where a styling pass sends the attributes it produces.
///
/// An incremental restyle has to run every decoration through the styler,
/// because the `LiveLayout` it builds describes widgets for the whole document
/// and TextKit can ask for any fragment at any time. What it must *not* do is
/// write outside the ranges that actually changed: setting an attribute — even
/// to the value already there — throws away the layout for that range, and
/// re-laying out the whole note is precisely the per-keystroke cost being
/// removed. So the passes are written once, against this, and the decorations
/// whose styling is already correct simply drop what they produce.
///
/// Reads go straight through: outside the dirty ranges the storage still holds
/// the previous pass's attributes, which are by definition the right ones.
final class StyleSink {
    let storage: NSTextStorage
    var writes = true

    init(_ storage: NSTextStorage) { self.storage = storage }

    var length: Int { storage.length }

    func attribute(
        _ name: NSAttributedString.Key, at location: Int, effectiveRange: NSRangePointer?
    ) -> Any? {
        storage.attribute(name, at: location, effectiveRange: effectiveRange)
    }

    func enumerateAttribute(
        _ name: NSAttributedString.Key, in range: NSRange,
        using block: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        storage.enumerateAttribute(name, in: range, using: block)
    }

    func addAttribute(_ name: NSAttributedString.Key, value: Any, range: NSRange) {
        guard writes else { return }
        storage.addAttribute(name, value: value, range: range)
    }

    func addAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard writes else { return }
        storage.addAttributes(attributes, range: range)
    }
}

/// Turns `LiveDecorator` output into text attributes, plus a `LiveLayout`
/// describing what the layout fragments must draw.
///
/// Markup is hidden by *collapsing* it: the characters stay in the storage and
/// keep their place in every offset, but get a hairline font and clear colour
/// so they take no visible width. Nothing is deleted, so the buffer always
/// equals the file, and copying across hidden markup yields real source.
///
/// Constructs with no attribute equivalent (tables, formulae, images, bullets)
/// are collapsed the same way and then painted by `HeftLayoutFragment`.
enum LiveStyler {

    /// Rendered size for a heading of `level`, matching the reading renderer.
    static func headingSize(_ level: Int) -> CGFloat {
        let sizes: [CGFloat] = [28, 22, 18, 16, 15, 14]
        return sizes[min(max(level, 1), 6) - 1]
    }

    /// Leading edge of the text inside a quote or callout at `depth`.
    static func quoteIndent(depth: Int, callout: Bool) -> CGFloat {
        (callout ? 36 : 22) + CGFloat(max(0, depth - 1)) * 18
    }

    /// Leading edge of the text in a list item at `depth`. The marker is
    /// collapsed, so both the first and the wrapped lines start here and the
    /// glyph is drawn in the gutter to the left.
    static func listIndent(depth: Int) -> CGFloat { 26 + CGFloat(depth) * 22 }

    /// - Parameters:
    ///   - decorations: the parse of `storage`'s text, when the caller already
    ///     has it. It needs one to work out `dirty`, and parsing twice per
    ///     keystroke is exactly the sort of waste this scoping exists to remove.
    ///   - dirty: the only ranges this pass may write to, or nil for the whole
    ///     document. Every decoration is either wholly inside one of them or
    ///     wholly outside all of them — `RestyleScope` guarantees it — so the
    ///     ranges can be reset to base attributes and rebuilt from scratch,
    ///     while everything else keeps the attributes, and the layout, it has.
    ///
    ///     The returned `LiveLayout` still describes the *whole* document
    ///     either way: a layout fragment can be rebuilt by TextKit at any
    ///     moment, anywhere, and it asks this for the widgets to draw.
    @discardableResult
    static func apply(
        to storage: NSTextStorage,
        reveal: Reveal,
        context: RenderContext,
        baseFont: NSFont = Theme.liveFont,
        drawsWidgets: Bool = true,
        contentWidth: CGFloat = Theme.contentMaxWidth,
        decorations precomputed: [MarkdownDecoration]? = nil,
        incremental: Incremental? = nil
    ) -> LiveLayout {
        let source = storage.string
        let text = source as NSString
        let full = NSRange(location: 0, length: storage.length)

        let body = bodyParagraphStyle()
        let decorations = precomputed ?? LiveDecorator.decorations(in: source)
        let scope = (incremental?.dirty ?? [full]).compactMap { range -> NSRange? in
            let clamped = NSIntersectionRange(range, full)
            return clamped.length > 0 ? clamped : nil
        }
        /// Whether this pass has anything to do for a decoration at all. The
        /// ones it says no to are the ones whose styling is already in the
        /// storage and whose widgets are carried over below.
        func writes(_ range: NSRange) -> Bool {
            guard incremental != nil else { return true }
            return scope.contains { NSIntersectionRange($0, range).length > 0 }
        }

        let sink = StyleSink(storage)
        storage.beginEditing()
        defer { storage.endEditing() }

        for range in scope {
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: body,
            ], range: range)
            styleEmptyBodyLines(in: storage, text: text, within: range)
        }

        // Widgets on paragraphs this pass is not touching are exactly the ones
        // it drew last time, moved along by however much the edit displaced
        // them. Re-deriving them instead would mean measuring every table and
        // typesetting every formula in the note on each keystroke.
        var layout = incremental.map {
            carryOver($0.previous, edit: $0.edit, dirty: scope)
        } ?? LiveLayout()

        // The caret has to be able to re-enter a span it just left, so the
        // ranges that reveal on the caret alone are reported back to the
        // editor: it compares them on every selection change to decide whether
        // a restyle is needed at all.
        layout.revealableSpans = decorations
            .filter { !Reveal.revealsWithItsLine($0.style) }
            .map { $0.revealRange ?? $0.range }
        // A table's cells count too. Moving from one column to the next stays
        // on the same line, so the line test alone would miss it and the caret
        // would keep drawing itself into the cell it had left.
        layout.revealableSpans += decorations.flatMap { decoration -> [NSRange] in
            guard case .table(let table) = decoration.style else { return [] }
            return table.cellRanges.flatMap { $0 }.map {
                NSRange(location: $0.location + decoration.range.location, length: $0.length)
            }
        }

        for decoration in decorations where writes(decoration.range) {
            sink.writes = true
            style(
                decoration, in: sink, base: baseFont, body: body,
                context: context, layout: &layout, drawsWidgets: drawsWidgets,
                revealed: reveal.reveals(decoration)
            )
        }

        // Second pass so collapsing always wins over the styling above.
        for decoration in decorations {
            guard !reveal.reveals(decoration), writes(decoration.range) else { continue }
            sink.writes = true
            for range in decoration.syntax where range.length > 0 && NSMaxRange(range) <= storage.length {
                collapse(range, in: sink)
            }
        }

        guard drawsWidgets else { return layout }

        // Third pass: constructs the editor draws instead of showing. They are
        // hidden whole, not just at their markers, so this cannot run until
        // every attribute above is settled.
        for decoration in decorations where writes(decoration.range) {
            guard !reveal.reveals(decoration) else { continue }
            sink.writes = true
            widget(
                decoration, in: sink, text: text, base: baseFont,
                context: context, layout: &layout, contentWidth: contentWidth,
                state: reveal.state(of: decoration)
            )
        }

        return layout
    }

    /// What one incremental pass needs to know about the one before it.
    struct Incremental {
        /// The only ranges the pass may write to.
        let dirty: [NSRange]
        /// How the text moved, so carried-over widgets move with it.
        let edit: SourceEdit
        /// The widgets the previous pass produced.
        let previous: LiveLayout
    }

    /// The previous pass's widgets, shifted by the edit and stripped of
    /// anything sitting on a paragraph this pass is about to rebuild.
    ///
    /// Keys and the locations inside the entries are absolute document
    /// offsets, so both move. Anything landing inside the edit itself is on a
    /// changed line and therefore dropped: `RestyleScope` guarantees a
    /// decoration is wholly inside the dirty ranges or wholly outside them, so
    /// no widget can be half carried and half rebuilt.
    private static func carryOver(
        _ previous: LiveLayout, edit: SourceEdit, dirty: [NSRange]
    ) -> LiveLayout {
        func moved(_ location: Int) -> Int { edit.mapStart(location) }
        func rebuilt(_ location: Int) -> Bool {
            dirty.contains { NSLocationInRange(location, $0) }
        }

        var layout = LiveLayout()
        for (start, widget) in previous.blocks {
            let start = moved(start)
            guard !rebuilt(start) else { continue }
            // A grid knows where it is in the document, and an edit above it
            // moves it. Carrying that over unchanged would leave clicks and
            // carets in a table below an edit resolving against stale offsets.
            if case .table(var grid) = widget {
                grid.documentStart = start
                layout.blocks[start] = .table(grid)
                continue
            }
            layout.blocks[start] = widget
        }
        for (start, items) in previous.inlineMath {
            let start = moved(start)
            guard !rebuilt(start) else { continue }
            layout.inlineMath[start] = items.map { (moved($0.location), $0.image) }
        }
        for (start, tags) in previous.inlineTags {
            let start = moved(start)
            guard !rebuilt(start) else { continue }
            layout.inlineTags[start] = tags.map {
                (
                    NSRange(location: moved($0.range.location), length: $0.range.length),
                    $0.color, $0.font, $0.ink
                )
            }
        }
        return layout
    }

    /// AppKit considers every newline a paragraph boundary, while Markdown
    /// considers a single newline a soft break. Keep ordinary source lines on
    /// one continuous baseline rhythm; the empty source line in `\n\n` is what
    /// supplies the visible paragraph separation.
    ///
    /// Empty TextKit 2 paragraphs otherwise include line spacing in the caret.
    /// Moving that spacing after the empty paragraph preserves the next
    /// baseline while leaving its insertion point at the font's natural height.
    static func bodyParagraphStyle(compactEmptyLine: Bool = false) -> NSMutableParagraphStyle {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = compactEmptyLine ? 0 : Theme.lineSpacing
        body.paragraphSpacing = compactEmptyLine ? Theme.lineSpacing : 0
        return body
    }

    private static func styleEmptyBodyLines(
        in storage: NSTextStorage, text: NSString, within: NSRange
    ) {
        guard text.length > 0, within.length > 0 else { return }
        let compact = bodyParagraphStyle(compactEmptyLine: true)
        var location = within.location
        while location < NSMaxRange(within) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let contents = text.substring(with: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if contents.isEmpty {
                storage.addAttribute(.paragraphStyle, value: compact, range: line)
            }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
    }

    // MARK: - Widgets

    private static func widget(
        _ decoration: MarkdownDecoration,
        in storage: StyleSink,
        text: NSString,
        base: NSFont,
        context: RenderContext,
        layout: inout LiveLayout,
        contentWidth: CGFloat,
        state: RevealState
    ) {
        let range = decoration.range
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location

        switch decoration.style {
        case .frontmatter:
            // The fences are markup; only what is between them is properties.
            let inner = text.substring(with: range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-\n"))
            guard let card = PropertiesRenderer.card(
                yaml: inner, maxWidth: contentWidth, fontSize: base.pointSize - 1
            ) else { return }
            hideWhole(range, in: storage, text: text, reserving: card.size.height)
            layout.blocks[lineStart] = .properties(card)

        case .table(let table):
            // The caret does not dissolve a table back into pipes: the grid is
            // drawn either way and one cell shows its source instead.
            var active: TableGrid.ActiveCell?
            if case .cell(let row, let column) = state {
                active = TableGrid.ActiveCell(row: row, column: column)
            }
            var grid = TableGrid.measure(
                table, maxWidth: contentWidth, context: context,
                fontSize: base.pointSize - 1, active: active
            )
            guard grid.size.height > 0 else { return }
            // Set after the measurement, which is cached: two identical tables
            // in one note share a grid and differ only in where they sit.
            grid.documentStart = range.location
            grid.accent = context.resolved(context.accentColor)
            hideWhole(range, in: storage, text: text, reserving: grid.contentSize.height)
            layout.blocks[lineStart] = .table(grid)

        case .blockMath(let latex):
            guard let image = MathRenderer.image(
                latex: latex, fontSize: base.pointSize + 3,
                color: context.resolved(.labelColor), display: true
            ) else { return }
            hideWhole(range, in: storage, text: text, reserving: image.size.height)
            layout.blocks[lineStart] = .blockMath(image)

        case .inlineMath(let latex):
            // Sampled one character in, past the `$`: the delimiter is part of
            // the syntax the previous pass already collapsed to a hairline, so
            // reading the size there would typeset the formula at 0.01pt.
            // The +1 undoes the monospace shrink applied to the body.
            let inner = min(range.location + 1, max(0, storage.length - 1))
            let size = max(9, fontSize(at: inner, in: storage, fallback: base) + 1)
            guard let image = MathRenderer.image(
                latex: latex, fontSize: size, color: context.resolved(.labelColor), display: false
            ) else { return }
            collapse(range, in: storage)
            // The collapsed source occupies no width, so the gap the formula
            // needs is bought with kerning on its last character.
            storage.addAttribute(
                .kern, value: image.size.width + 3,
                range: NSRange(location: NSMaxRange(range) - 1, length: 1)
            )
            growLineHeight(to: image.size.height + 2, forLineAt: range.location, in: storage, text: text)
            layout.inlineMath[lineStart, default: []].append((range.location, image))

        case .image(let source, _):
            guard let url = context.resolveResource(source), let image = ImageCache.image(at: url)
            else { return }
            let lead = blockLead(range, text: text, lineStart: lineStart, in: storage, layout: layout)
            hideWhole(
                range, in: storage, text: text, indent: lead.indent,
                reserving: HeftLayoutFragment.displaySize(for: image).height
            )
            layout.blocks[lineStart] = .image(image, lead: lead)

        case .wikiLink(let link):
            guard link.isEmbed,
                  BlockLine.leadingMarkers(before: range, in: text) != nil,
                  let hit = context.resolve(link)
            else { return }
            let lead = blockLead(range, text: text, lineStart: lineStart, in: storage, layout: layout)

            // A markdown target is transcluded; anything else is a picture.
            if hit.isMarkdown {
                guard let embed = EmbedRenderer.render(
                    link: link, note: hit, maxWidth: contentWidth - lead.indent,
                    context: context, fontSize: base.pointSize - 0.5
                ) else { return }
                hideWhole(
                    range, in: storage, text: text, indent: lead.indent,
                    reserving: embed.size.height
                )
                layout.blocks[lineStart] = .embed(embed, lead: lead)
                return
            }

            guard let image = ImageCache.image(at: hit.url) else { return }
            hideWhole(
                range, in: storage, text: text, indent: lead.indent,
                reserving: HeftLayoutFragment.displaySize(for: image).height
            )
            layout.blocks[lineStart] = .image(image, lead: lead)

        case .thematicBreak:
            // The dashes collapse to nothing, so without a reserved height the
            // rule would be drawn into a line with no room and clipped away.
            hideWhole(range, in: storage, text: text, reserving: 2)
            layout.blocks[lineStart] = .thematicBreak

        case .agentGuideBoundary(let isEnd):
            // Enough height for the label the rule carries.
            hideWhole(range, in: storage, text: text, reserving: 14)
            layout.blocks[lineStart] = .agentGuide(isEnd: isEnd)

        default:
            break
        }
    }

    /// True when only whitespace shares the range's line, so the construct can
    /// be given the whole line's height without painting over prose.
    /// What the line a block widget is about to claim still owes the reader.
    ///
    /// A picture on a bullet, or inside a quote, is one line with two things
    /// on it, and the editor draws one widget per line. The marker's own
    /// widget was written in the first pass and is about to be overwritten
    /// here, so what it would have drawn is lifted out of it and carried by
    /// the picture instead.
    ///
    /// The indent is read from the paragraph style that widget's own styling
    /// wrote, rather than recomputed from the marker's depth, so the two
    /// cannot disagree. It must be read *before* `hideWhole`, which replaces
    /// that paragraph style.
    private static func blockLead(
        _ range: NSRange, text: NSString, lineStart: Int,
        in storage: StyleSink, layout: LiveLayout
    ) -> BlockLead {
        guard let markers = BlockLine.leadingMarkers(before: range, in: text), markers > 0
        else { return BlockLead() }
        let indent = (storage.attribute(.paragraphStyle, at: lineStart, effectiveRange: nil)
            as? NSParagraphStyle)?.headIndent ?? 0

        switch layout.blocks[lineStart] {
        case .list(let glyph, let markerOffset, let fontSize):
            return BlockLead(
                indent: indent,
                bullet: LeadingBullet(
                    glyph: glyph, markerOffset: markerOffset, fontSize: fontSize
                )
            )
        case .quote(let quote, _, let isRevealed, let bullet):
            // The quote widget already carries any list written inside it, so
            // `> - ![[shot.png]]` needs nothing further.
            return BlockLead(
                indent: indent, bullet: bullet,
                quote: LeadingQuote(line: quote, isRevealed: isRevealed)
            )
        default:
            return BlockLead()
        }
    }

    /// Hides every line a multi-line construct occupies, then gives its *first*
    /// line enough height for the widget that replaces it.
    ///
    /// The height is bought with `minimumLineHeight` rather than by overriding
    /// the fragment's frame. Line height is ordinary paragraph geometry that
    /// the layout manager has to honour, so the space is really there and the
    /// drawing cannot be clipped to a hairline.
    private static func hideWhole(
        _ range: NSRange, in storage: StyleSink, text: NSString,
        indent: CGFloat = 0, reserving height: CGFloat
    ) {
        collapse(range, in: storage)
        let lines = text.lineRange(for: range)

        // Continuation lines keep their characters but take no space.
        let flat = NSMutableParagraphStyle()
        flat.lineSpacing = 0
        flat.paragraphSpacing = 0
        flat.paragraphSpacingBefore = 0
        flat.maximumLineHeight = 0.01
        flat.minimumLineHeight = 0.01
        storage.addAttribute(.paragraphStyle, value: flat, range: lines)

        let first = text.lineRange(for: NSRange(location: lines.location, length: 0))
        let block = NSMutableParagraphStyle()
        block.lineSpacing = 0
        block.paragraphSpacingBefore = 8
        block.paragraphSpacing = 8
        block.minimumLineHeight = height + HeftLayoutFragment.blockInset * 2
        // A block on a list line keeps the list's indent, because the widget
        // positions its bullet from where the line's text begins.
        block.headIndent = indent
        block.firstLineHeadIndent = indent
        // Deliberately no maximum: it would clamp the height back down.
        storage.addAttribute(.paragraphStyle, value: block, range: first)
    }

    private static func growLineHeight(
        to height: CGFloat, forLineAt location: Int, in storage: StyleSink, text: NSString
    ) {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard line.length > 0 else { return }
        let existing = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil)
        let style = (existing as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.minimumLineHeight = max(style.minimumLineHeight, height)
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    private static func fontSize(at location: Int, in storage: StyleSink, fallback: NSFont) -> CGFloat {
        guard location < storage.length,
              let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        else { return fallback.pointSize }
        return font.pointSize
    }

    private static func collapse(_ range: NSRange, in storage: StyleSink) {
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 0.01),
            .foregroundColor: NSColor.clear,
            .kern: 0,
        ], range: range)
    }

    // MARK: - Attributes

    private static func style(
        _ decoration: MarkdownDecoration,
        in storage: StyleSink,
        base: NSFont,
        body: NSMutableParagraphStyle,
        context: RenderContext,
        layout: inout LiveLayout,
        drawsWidgets: Bool,
        revealed: Bool
    ) {
        let range = decoration.range
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        let text = storage.storage.string as NSString

        switch decoration.style {
        case .frontmatter:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 2, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: range)

        case .comment:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(
                    ofSize: base.pointSize - 2,
                    weight: .regular
                ),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: range)

        case .codeBlock(let language):
            let code = NSMutableParagraphStyle()
            code.lineSpacing = 2
            code.firstLineHeadIndent = 10
            code.headIndent = 10
            code.paragraphSpacingBefore = 0
            code.minimumLineHeight = base.pointSize * 1.55
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: code,
            ], range: range)
            if decoration.syntax.count >= 2, let closing = decoration.syntax.last {
                let footer = code.mutableCopy() as! NSMutableParagraphStyle
                // Keep the opening fence at normal line height so revealing
                // its literal source cannot resize the block. Balance that
                // header space below the code through the closing-fence row.
                footer.minimumLineHeight = base.pointSize * 2.05
                let closingLocation = max(closing.location, NSMaxRange(closing) - 1)
                storage.addAttribute(
                    .paragraphStyle, value: footer,
                    range: text.lineRange(for: NSRange(location: closingLocation, length: 0))
                )
            }
            if storage.writes {
                CodeSyntaxHighlighting.apply(
                    to: storage.storage, decoration: decoration, language: language
                )
            }
            if drawsWidgets {
                addCodeBlockWidgets(
                    decoration: decoration,
                    language: revealed ? nil : language,
                    text: text,
                    layout: &layout
                )
            }

        case .table:
            // Only seen when the caret is inside: the table shows as source.
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 2, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)

        case .heading(let level):
            let heading = NSMutableParagraphStyle()
            heading.lineSpacing = 2
            heading.paragraphSpacingBefore = level <= 2 ? 20 : 14
            heading.paragraphSpacing = level <= 2 ? 12 : 6
            storage.addAttributes([
                .font: NSFont.systemFont(
                    ofSize: headingSize(level), weight: level <= 2 ? .bold : .semibold
                ),
                .paragraphStyle: heading,
            ], range: text.lineRange(for: range))
            if drawsWidgets, context.colorfulFormatting {
                layout.blocks[text.lineRange(for: range).location] =
                    .headingAccent(level: level, color: context.headingColor(level))
            }

        case .quoteLine(let quote):
            let quoteEdge = quoteIndent(depth: quote.depth, callout: quote.isCallout)
            // A list inside a quote is indented from the quote's own text
            // edge, not from the page: the bullet belongs inside the card.
            var indent = quoteEdge
            var quotedBullet: LeadingBullet?
            if case .list(let kind, let depth, let marker) = quote.nested {
                // The full list indent, on top of the quote's own text edge:
                // a quoted list steps in from quoted prose by exactly what an
                // unquoted list steps in from the page. Anything less and the
                // gutter is too narrow for the glyph, which then lands on the
                // quote bar instead of inside the card.
                indent = quoteEdge + listIndent(depth: depth)
                if drawsWidgets, !revealed {
                    let glyph: ListGlyph = switch kind {
                    case .bullet(let shape): .bullet(shape)
                    case .task(let state): .checkbox(state, accent: context.accentColor)
                    case .ordered: .ordered(orderedLabel(marker))
                    }
                    quotedBullet = LeadingBullet(
                        glyph: glyph,
                        markerOffset: listGlyphOffset(marker: marker, kind: kind, font: base),
                        fontSize: base.pointSize
                    )
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Theme.lineSpacing
            // Both edges use the same indent: the `>` markers are collapsed, so
            // the first line has no marker occupying space and would otherwise
            // start further left than the lines it wraps onto.
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.tailIndent = -12
            // The card is one background painted across several paragraphs, so
            // the space belongs outside the block, not between its lines — and
            // it has to be equal on both sides, or the block sits visibly high
            // inside its own background.
            let isFirst = quote.edge == .first || quote.edge == .only
            let isLast = quote.edge == .last || quote.edge == .only
            // Every line already carries `lineSpacing` worth of lead inside its
            // fragment, so the opening line needs only the remainder to match
            // the closing line's trail. Measured with `Heft render`, which
            // prints each fragment's box against the text inside it.
            paragraph.paragraphSpacingBefore = isFirst
                ? max(0, Theme.quoteBlockPadding - Theme.lineSpacing)
                : 0
            paragraph.paragraphSpacing = isLast ? Theme.quoteBlockPadding : 0

            // A callout whose title line carries no text of its own still has
            // an icon and a drawn label to fit. Without the reservation the
            // line is only as tall as an empty paragraph and both get clipped.
            //
            // Only while that label is actually drawn, though. Revealed, the
            // line holds the real `> [!tip]` text, which is shorter than the
            // reservation — and the surplus goes above the glyphs, so the
            // heading appeared to drop as soon as it was clicked. A titled
            // callout never reserved anything and never moved, which is what
            // made the two behave differently.
            // Sized to the line the revealed source produces, so switching
            // between the two states moves nothing at all.
            if quote.needsDrawnTitle, !revealed {
                paragraph.minimumLineHeight = ceil(base.ascender - base.descender + base.leading)
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)

            // Quoted text stays at full contrast. Dimming it is the obvious
            // way to say "this is set apart", but the card already says that,
            // and a quote is usually the passage that matters most on the page.
            if quote.isCalloutHeader {
                // The title is prose and stays visible; only `[!kind]` hides.
                // Weight is what separates it from the body beneath it.
                addTrait(.boldFontMask, to: storage, range: range, base: base)
            }

            // `> ## Heading` is a heading that happens to be quoted, and has
            // to look like one, or a quoted document reads as flat prose.
            if case .heading(let level) = quote.nested {
                storage.addAttribute(
                    .font,
                    value: NSFont.systemFont(
                        ofSize: headingSize(level), weight: level <= 2 ? .bold : .semibold
                    ),
                    range: range
                )
                // Enough room for the larger glyphs, which the quote's own
                // line height knows nothing about.
                paragraph.minimumLineHeight = ceil(headingSize(level) * 1.25)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }

            // The card is drawn even while the source shows, so editing a
            // callout does not make it flicker out of existence. What must not
            // survive is the *drawn* title: with the source visible, the real
            // `> [!tip]` text is on the line and the painted label lands on
            // top of it.
            if drawsWidgets {
                // The card is drawn back from the fragment's own origin, so
                // this has to be the paragraph indent that origin came from —
                // the nested one on a list line. Passing the quote's own edge
                // instead leaves the fragment indented and the card not, which
                // steps the whole card right on every list line.
                layout.blocks[text.lineRange(for: range).location] =
                    .quote(quote, indent: indent, isRevealed: revealed, bullet: quotedBullet)
            }

        case .listMarker(let kind, let depth):
            let indent = listIndent(depth: depth)
            let marker = text.substring(with: range)
            let leading = marker.prefix { $0 == " " || $0 == "\t" }
            let leadingLength = leading.utf16.count
            let visibleMarker = String(marker.dropFirst(leadingLength))
            let visibleMarkerWidth = markerWidth(visibleMarker, font: base)
            let glyphOffset = listGlyphOffset(
                marker: visibleMarker, kind: kind, font: base
            )
            let list = NSMutableParagraphStyle()
            list.lineSpacing = Theme.lineSpacing
            list.paragraphSpacing = 2
            // With no item text, every character in the line is collapsed
            // marker syntax. TextKit would then shrink the fragment to the
            // hairline font, clipping the painted glyph and leaving almost no
            // row to click. Reserve the same height as an ordinary body line.
            list.minimumLineHeight = ceil(base.ascender - base.descender + base.leading)
            list.headIndent = indent
            // Collapsed, the marker takes no width, so the first line starts
            // where the wrapped lines do and the glyph is drawn to its left.
            // Revealed, only the semantic `- [ ] ` marker reappears. Leading
            // source indentation stays collapsed because tabs have different
            // widths in paragraph layout and would shift nested item text.
            list.firstLineHeadIndent = revealed
                ? indent - visibleMarkerWidth
                : indent
            let tabCount = leading.count(where: { $0 == "\t" })
            if tabCount > 0 {
                // A clear, hairline-font tab still advances to a paragraph tab
                // stop. Anchor private stops just beyond the marker origin so
                // source tabs occupy the same subpixel width in both states.
                let markerOrigin = revealed ? indent - visibleMarkerWidth : indent
                list.tabStops = (1...tabCount).map { index in
                    NSTextTab(
                        textAlignment: .left,
                        location: markerOrigin + CGFloat(index) * 0.25
                    )
                }
            }
            let line = text.lineRange(for: range)
            storage.addAttribute(.paragraphStyle, value: list, range: line)
            if revealed, leadingLength > 0 {
                collapse(NSRange(location: range.location, length: leadingLength), in: storage)
            }

            // No glyph while the source is showing: the drawn bullet and the
            // literal `-` would both be visible, which is what the collapsed
            // rendering exists to avoid.
            if drawsWidgets, !revealed {
                let glyph: ListGlyph = switch kind {
                case .bullet(let shape): .bullet(shape)
                case .task(let state): .checkbox(state, accent: context.accentColor)
                case .ordered: .ordered(orderedLabel(marker))
                }
                layout.blocks[line.location] = .list(
                    glyph: glyph, markerOffset: glyphOffset, fontSize: base.pointSize
                )
            }

            // Only a finished task is struck through. `[/]` is in progress
            // and `[-]` is abandoned; striking either would say the work was
            // completed.
            guard case .task(let state) = kind, state.isDone else { break }
            let rest = NSRange(
                location: NSMaxRange(range), length: max(0, NSMaxRange(line) - NSMaxRange(range))
            )
            if rest.length > 0 {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: rest)
            }

        case .bold:
            addTrait(.boldFontMask, to: storage, range: range, base: base)
            if context.colorfulFormatting {
                storage.addAttribute(.foregroundColor, value: context.boldColor, range: range)
            }
        case .italic:
            addTrait(.italicFontMask, to: storage, range: range, base: base)
            if context.colorfulFormatting {
                storage.addAttribute(.foregroundColor, value: context.italicColor, range: range)
            }
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .highlight:
            storage.addAttribute(
                .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.30), range: range
            )

        case .inlineCode:
            // Size comes from whatever font is already there, so inline code
            // inside a heading stays heading-sized.
            monospace(storage, range: range, delta: -1, base: base, color: context.codeColor)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)

        case .wikiLink(let link):
            let resolved = context.index.resolve(link, from: context.current) != nil
            // Same hue either way, so a broken link still reads as a link
            // rather than jumping to an unrelated colour (that used to be
            // `.systemOrange`, which is also the colourful-italic colour, so
            // a link like `*[[missing]]*` looked like plain italic text).
            storage.addAttribute(
                .foregroundColor,
                value: resolved ? context.linkColor : context.linkColor.withAlphaComponent(0.55),
                range: range
            )
            if let url = InlineText.heftURL(target: link.target) {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .link(let destination):
            storage.addAttribute(.foregroundColor, value: context.linkColor, range: range)
            if let url = URL(string: destination), url.scheme != nil {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .image:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)

        case .pendingEmphasis(let level):
            // Applied only while the caret is on this line, which is what
            // `revealsWithItsLine` arranges: this is emphasis being typed, and
            // an unclosed delimiter elsewhere in the note is literal text.
            //
            // Nothing is collapsed — the decoration carries no `syntax` — so
            // the `**` stays on screen while it is being written, which is
            // what tells you the span is still open.
            guard revealed else { break }
            addTrait(
                level >= 2 ? .boldFontMask : .italicFontMask,
                to: storage, range: range, base: base
            )
            // The same colour the finished span gets. Styling the weight but
            // not the colour made a span change appearance twice — once as it
            // opened and again as it closed — which reads as a glitch rather
            // than as the span being completed.
            if context.colorfulFormatting {
                storage.addAttribute(
                    .foregroundColor,
                    value: level >= 2 ? context.boldColor : context.italicColor,
                    range: range
                )
            }

        case .footnoteReference:
            // Raised and small, the way a footnote marker has looked in print
            // for four hundred years. An attribute rather than a widget: this
            // is exactly what baseline offset is for, and a drawn glyph would
            // have to be positioned against text that reflows.
            //
            // Only while it is collapsed. Revealed, the line holds the real
            // `[^1]` and raising that would lift the brackets being edited off
            // the baseline with it.
            if revealed {
                storage.addAttribute(.foregroundColor, value: context.linkColor, range: range)
            } else {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: max(7, base.pointSize * 0.72)),
                    .baselineOffset: base.pointSize * 0.32,
                    .foregroundColor: context.linkColor,
                ], range: range)
            }

        case .footnoteDefinition:
            // The label keeps the reference's colour so the two read as a
            // pair; the definition's prose is left alone.
            storage.addAttribute(.foregroundColor, value: context.linkColor, range: range)
            // A hanging indent, so a definition running to several lines stays
            // a block under its own number instead of unwrapping to the margin.
            let definition = NSMutableParagraphStyle()
            definition.lineSpacing = Theme.lineSpacing
            definition.headIndent = 18
            storage.addAttribute(
                .paragraphStyle, value: definition, range: text.lineRange(for: range)
            )

        case .tag:
            // The pill behind it is drawn by the layout fragment, not set as
            // a `.backgroundColor`: that attribute can only ever paint a
            // square-cornered box tight around the glyphs, and a tag wants
            // Obsidian's rounded capsule with a little room inside it.
            storage.addAttribute(.foregroundColor, value: context.tagColor, range: range)

            // The pill is drawn wider than its text, and drawing alone
            // reserves no room, so without extra space it laps over the
            // spaces either side and all but touches the neighbouring words.
            // Kerning opens that room — but never on the character
            // immediately before one whose position matters, because TextKit
            // reports that next character a couple of points to the left of
            // where it actually draws. The error does not accumulate; only
            // the character right after a kerned one is affected.
            //
            // So the gap in front is opened *before* the space rather than on
            // it, leaving the tag's own reported position exact for placing
            // the pill. The gap behind goes on the tag's last character
            // rather than on the space after it, which leaves the caret
            // sitting where the next typed character will actually land.
            // Kerning that space instead put the gap after it: the caret
            // stopped short of the following letter, and the gap only
            // appeared once something was typed, since a line's trailing
            // whitespace has no width to widen.
            func kern(at location: Int) {
                guard location >= 0, location < storage.length else { return }
                storage.addAttribute(
                    .kern, value: HeftLayoutFragment.tagPadding,
                    range: NSRange(location: location, length: 1)
                )
            }
            func isSpace(at location: Int) -> Bool {
                guard location >= 0, location < storage.length else { return false }
                return text.substring(with: NSRange(location: location, length: 1)) == " "
            }
            // Only against a space: a tag butted against punctuation is
            // better overlapping it slightly than shoving it out of place.
            if isSpace(at: range.location - 1) { kern(at: range.location - 2) }
            if isSpace(at: NSMaxRange(range)) { kern(at: NSMaxRange(range) - 1) }

            // Where the tag's ink actually falls inside the space its glyphs
            // advance through. Centring the pill on the advance box instead
            // left it visibly skewed: `#` carries a wider side bearing than
            // most letters end with, so the drawn text sits right of that
            // box's centre. Ink bounds are what the eye is judging.
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                ?? base
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text.substring(with: range), attributes: [.font: font])
            )
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            layout.inlineTags[lineStart, default: []].append(
                (range, context.tagColor, font, CTLineGetImageBounds(line, nil))
            )

        case .inlineMath, .blockMath:
            monospace(storage, range: range, delta: -1, base: base, color: .systemTeal)

        case .thematicBreak, .agentGuideBoundary:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    /// Width the literal marker occupies once it is visible again.
    private static func markerWidth(_ marker: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: marker, attributes: [.font: font]).size().width
    }

    /// Centre of the rendered glyph relative to the list item's content edge.
    /// It is derived from the literal source marker, so revealing `-`, `1.` or
    /// `[ ]` swaps in place rather than making the marker jump sideways.
    static func listGlyphOffset(
        marker: String, kind: ListMarkerKind, font: NSFont
    ) -> CGFloat {
        let fullWidth = markerWidth(marker, font: font)
        switch kind {
        case .bullet:
            let token = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return -fullWidth + markerWidth(token, font: font) / 2
        case .ordered:
            let token = orderedLabel(marker)
            return -fullWidth + markerWidth(token, font: font) / 2
        case .task:
            let source = marker as NSString
            let box = source.range(of: #"\[[ xX]\]"#, options: .regularExpression)
            guard box.location != NSNotFound else { return -fullWidth / 2 }
            let before = source.substring(with: NSRange(location: 0, length: box.location))
            let token = source.substring(with: box)
            return -fullWidth
                + markerWidth(before, font: font)
                + markerWidth(token, font: font) / 2
        }
    }

    private static func addCodeBlockWidgets(
        decoration: MarkdownDecoration,
        language: String?,
        text: NSString,
        layout: inout LiveLayout
    ) {
        var starts: [Int] = []
        var location = decoration.range.location
        let end = NSMaxRange(decoration.range)
        repeat {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            starts.append(line.location)
            let next = NSMaxRange(line)
            guard next > location, next < end else { break }
            location = next
        } while location <= end

        for (index, start) in starts.enumerated() {
            let edge: CodeBlockEdge
            if starts.count == 1 { edge = .only }
            else if index == 0 { edge = .first }
            else if index == starts.count - 1 { edge = .last }
            else { edge = .middle }
            layout.blocks[start] = .codeBlock(
                edge: edge, language: index == 0 ? language : nil
            )
        }
    }

    /// `1.` / `12)` taken off the front of a matched ordered-list marker.
    private static func orderedLabel(_ marker: String) -> String {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix { $0.isNumber || $0 == "." || $0 == ")" })
    }

    private static func monospace(
        _ storage: StyleSink, range: NSRange, delta: CGFloat, base: NSFont, color: NSColor
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let size = ((value as? NSFont) ?? base).pointSize
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: size + delta, weight: .regular),
                range: subrange
            )
        }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    private static func addTrait(
        _ trait: NSFontTraitMask, to storage: StyleSink, range: NSRange, base: NSFont
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? base
            storage.addAttribute(
                .font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange
            )
        }
    }
}
