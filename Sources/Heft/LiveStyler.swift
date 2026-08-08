import AppKit
import HeftCore

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

    @discardableResult
    static func apply(
        to storage: NSTextStorage,
        reveal: Reveal,
        context: RenderContext,
        baseFont: NSFont = Theme.liveFont,
        drawsWidgets: Bool = true,
        contentWidth: CGFloat = Theme.contentMaxWidth
    ) -> LiveLayout {
        let source = storage.string
        let text = source as NSString
        let full = NSRange(location: 0, length: storage.length)

        let body = bodyParagraphStyle()

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: body,
        ], range: full)
        styleEmptyBodyLines(in: storage, text: text)

        let decorations = LiveDecorator.decorations(in: source)
        var layout = LiveLayout()

        // The caret has to be able to re-enter a span it just left, so the
        // ranges that reveal on the caret alone are reported back to the
        // editor: it compares them on every selection change to decide whether
        // a restyle is needed at all.
        layout.revealableSpans = decorations
            .filter { !Reveal.revealsWithItsLine($0.style) }
            .map(\.range)

        for decoration in decorations {
            style(
                decoration, in: storage, base: baseFont, body: body,
                context: context, layout: &layout, drawsWidgets: drawsWidgets,
                revealed: reveal.reveals(decoration)
            )
        }

        // Second pass so collapsing always wins over the styling above.
        for decoration in decorations {
            guard !reveal.reveals(decoration) else { continue }
            for range in decoration.syntax where range.length > 0 && NSMaxRange(range) <= storage.length {
                collapse(range, in: storage)
            }
        }

        guard drawsWidgets else { return layout }

        // Third pass: constructs the editor draws instead of showing. They are
        // hidden whole, not just at their markers, so this cannot run until
        // every attribute above is settled.
        for decoration in decorations {
            guard !reveal.reveals(decoration) else { continue }
            widget(
                decoration, in: storage, text: text, base: baseFont,
                context: context, layout: &layout, contentWidth: contentWidth
            )
        }

        return layout
    }

    /// Empty TextKit 2 paragraphs otherwise use their full line-spacing box as
    /// the insertion point. Moving that spacing after the paragraph preserves
    /// the next baseline while leaving the caret at the font's natural height.
    static func bodyParagraphStyle(compactEmptyLine: Bool = false) -> NSMutableParagraphStyle {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = compactEmptyLine ? 0 : Theme.lineSpacing
        body.paragraphSpacing = 9 + (compactEmptyLine ? Theme.lineSpacing : 0)
        return body
    }

    private static func styleEmptyBodyLines(in storage: NSTextStorage, text: NSString) {
        guard text.length > 0 else { return }
        let compact = bodyParagraphStyle(compactEmptyLine: true)
        var location = 0
        while location < text.length {
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
        in storage: NSTextStorage,
        text: NSString,
        base: NSFont,
        context: RenderContext,
        layout: inout LiveLayout,
        contentWidth: CGFloat
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
            let grid = TableGrid.measure(
                table, maxWidth: contentWidth, context: context, fontSize: base.pointSize - 1
            )
            guard grid.size.height > 0 else { return }
            hideWhole(range, in: storage, text: text, reserving: grid.size.height)
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
            hideWhole(
                range, in: storage, text: text,
                reserving: HeftLayoutFragment.displaySize(for: image).height
            )
            layout.blocks[lineStart] = .image(image)

        case .wikiLink(let link):
            guard link.isEmbed, ownsItsLine(range, text), let hit = context.resolve(link)
            else { return }

            // A markdown target is transcluded; anything else is a picture.
            if hit.isMarkdown {
                guard let embed = EmbedRenderer.render(
                    link: link, note: hit, maxWidth: contentWidth,
                    context: context, fontSize: base.pointSize - 0.5
                ) else { return }
                hideWhole(range, in: storage, text: text, reserving: embed.size.height)
                layout.blocks[lineStart] = .embed(embed)
                return
            }

            guard let image = ImageCache.image(at: hit.url) else { return }
            hideWhole(
                range, in: storage, text: text,
                reserving: HeftLayoutFragment.displaySize(for: image).height
            )
            layout.blocks[lineStart] = .image(image)

        case .thematicBreak:
            // The dashes collapse to nothing, so without a reserved height the
            // rule would be drawn into a line with no room and clipped away.
            hideWhole(range, in: storage, text: text, reserving: 2)
            layout.blocks[lineStart] = .thematicBreak

        default:
            break
        }
    }

    /// True when only whitespace shares the range's line, so the construct can
    /// be given the whole line's height without painting over prose.
    private static func ownsItsLine(_ range: NSRange, _ text: NSString) -> Bool {
        let line = text.lineRange(for: range)
        let before = text.substring(with: NSRange(
            location: line.location, length: range.location - line.location
        ))
        let after = text.substring(with: NSRange(
            location: NSMaxRange(range), length: NSMaxRange(line) - NSMaxRange(range)
        ))
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Hides every line a multi-line construct occupies, then gives its *first*
    /// line enough height for the widget that replaces it.
    ///
    /// The height is bought with `minimumLineHeight` rather than by overriding
    /// the fragment's frame. Line height is ordinary paragraph geometry that
    /// the layout manager has to honour, so the space is really there and the
    /// drawing cannot be clipped to a hairline.
    private static func hideWhole(
        _ range: NSRange, in storage: NSTextStorage, text: NSString, reserving height: CGFloat
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
        // Deliberately no maximum: it would clamp the height back down.
        storage.addAttribute(.paragraphStyle, value: block, range: first)
    }

    private static func growLineHeight(
        to height: CGFloat, forLineAt location: Int, in storage: NSTextStorage, text: NSString
    ) {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard line.length > 0 else { return }
        let existing = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil)
        let style = (existing as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.minimumLineHeight = max(style.minimumLineHeight, height)
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    private static func fontSize(at location: Int, in storage: NSTextStorage, fallback: NSFont) -> CGFloat {
        guard location < storage.length,
              let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        else { return fallback.pointSize }
        return font.pointSize
    }

    private static func collapse(_ range: NSRange, in storage: NSTextStorage) {
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 0.01),
            .foregroundColor: NSColor.clear,
            .kern: 0,
        ], range: range)
    }

    // MARK: - Attributes

    private static func style(
        _ decoration: MarkdownDecoration,
        in storage: NSTextStorage,
        base: NSFont,
        body: NSMutableParagraphStyle,
        context: RenderContext,
        layout: inout LiveLayout,
        drawsWidgets: Bool,
        revealed: Bool
    ) {
        let range = decoration.range
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        let text = storage.string as NSString

        switch decoration.style {
        case .frontmatter:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 2, weight: .regular),
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
            CodeSyntaxHighlighting.apply(
                to: storage, decoration: decoration, language: language
            )
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
                layout.blocks[text.lineRange(for: range).location] = .headingAccent(level: level)
            }

        case .quoteLine(let quote):
            let indent = quoteIndent(depth: quote.depth, callout: quote.isCallout)
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
            paragraph.paragraphSpacingBefore = isFirst ? Theme.quoteBlockPadding : 0
            paragraph.paragraphSpacing = isLast ? Theme.quoteBlockPadding : 0

            // A callout whose title line carries no text of its own still has
            // an icon and a drawn label to fit. Without the reservation the
            // line is only as tall as an empty paragraph and both get clipped.
            if quote.isTitleLine, quote.title?.isEmpty == true {
                paragraph.minimumLineHeight = Theme.bodySize + 8
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)

            // Quoted text stays at full contrast. Dimming it is the obvious
            // way to say "this is set apart", but the card already says that,
            // and a quote is usually the passage that matters most on the page.
            if quote.isTitleLine {
                // The title is prose and stays visible; only `[!kind]` hides.
                // Weight is what separates it from the body beneath it.
                addTrait(.boldFontMask, to: storage, range: range, base: base)
            }

            if drawsWidgets {
                layout.blocks[text.lineRange(for: range).location] = .quote(quote, indent: indent)
            }

        case .listMarker(let kind, let depth):
            let indent = listIndent(depth: depth)
            let marker = text.substring(with: range)
            let leading = marker.prefix { $0 == " " || $0 == "\t" }
            let leadingLength = leading.utf16.count
            let visibleMarker = String(marker.dropFirst(leadingLength))
            let visibleMarkerWidth = markerWidth(visibleMarker, font: base)
            let list = NSMutableParagraphStyle()
            list.lineSpacing = Theme.lineSpacing
            list.paragraphSpacing = 2
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
                case .bullet: .bullet
                case .task(let checked): .checkbox(checked)
                case .ordered: .ordered(orderedLabel(marker))
                }
                layout.blocks[line.location] = .list(
                    glyph: glyph, indent: indent, fontSize: base.pointSize
                )
            }

            guard case .task(true) = kind else { break }
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
                storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
            }
        case .italic:
            addTrait(.italicFontMask, to: storage, range: range, base: base)
            if context.colorfulFormatting {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
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
            monospace(storage, range: range, delta: -1, base: base, color: .systemPink)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)

        case .wikiLink(let link):
            let resolved = context.index.resolve(link, from: context.current) != nil
            storage.addAttribute(
                .foregroundColor,
                value: resolved ? NSColor.controlAccentColor : NSColor.systemOrange,
                range: range
            )
            if let url = InlineText.heftURL(target: link.target) {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .link(let destination):
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            if let url = URL(string: destination), url.scheme != nil {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .image:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)

        case .tag:
            storage.addAttributes([
                .foregroundColor: NSColor.systemPurple,
                .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.14),
            ], range: range)

        case .inlineMath, .blockMath:
            monospace(storage, range: range, delta: -1, base: base, color: .systemTeal)

        case .thematicBreak:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    /// Width the literal marker occupies once it is visible again.
    private static func markerWidth(_ marker: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: marker, attributes: [.font: font]).size().width
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
        _ storage: NSTextStorage, range: NSRange, delta: CGFloat, base: NSFont, color: NSColor
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
        _ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange, base: NSFont
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? base
            storage.addAttribute(
                .font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange
            )
        }
    }
}
