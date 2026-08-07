import AppKit
import HeftCore
import SwiftUI

/// The editing surface, in either raw source or live (hybrid) mode.
///
/// Live mode hides markdown syntax and styles the text in place, revealing the
/// raw source on the line the cursor is in — the same model as Obsidian's Live
/// Preview and CodeMirror decorations.
///
/// Crucially, hiding is done through `NSLayoutManager` glyph properties rather
/// than by editing the text. The text storage stays byte-for-byte identical to
/// the file on disk, so what is saved is exactly what was loaded and a rendering
/// bug can never corrupt a note. Selecting and copying across hidden markup also
/// yields the real source.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    /// Changes when the document is replaced from outside the editor.
    let generation: Int
    let isLive: Bool
    let onAttachment: (NSPasteboard) -> String?
    let onFollowLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than `NSTextView.scrollableTextView()`: that
        // helper configures the view it returns, and swapping in a subclass
        // afterwards leaves the replacement unconfigured (an empty pane).
        let storage = NSTextStorage()
        let layoutManager = LiveLayoutManager()
        storage.addLayoutManager(layoutManager)
        layoutManager.delegate = context.coordinator

        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: CGFloat(0), height: unbounded))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = HeftTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: CGFloat(0), height: CGFloat(0))
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.onAttachment = onAttachment
        textView.onFollowLink = onFollowLink

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 22, height: 24)
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.linkTextAttributes = [:]  // styling comes from the decorator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.string = text
        context.coordinator.lastGeneration = generation
        context.coordinator.attach(textView)
        context.coordinator.restyle(textView)
        context.coordinator.observeSnippets(into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HeftTextView else { return }
        let modeChanged = context.coordinator.parent.isLive != isLive
        context.coordinator.parent = self
        textView.onAttachment = onAttachment
        textView.onFollowLink = onFollowLink

        if context.coordinator.lastGeneration != generation {
            context.coordinator.lastGeneration = generation
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scroll(.zero)
            }
            context.coordinator.restyle(textView)
        } else if textView.string != text {
            // External mutation of the same document, e.g. a snippet insert.
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length), length: 0
            ))
            context.coordinator.restyle(textView)
        } else if modeChanged {
            context.coordinator.restyle(textView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: SourceEditor
        var lastGeneration = -1

        /// Character indices whose glyphs are suppressed. Recomputed whenever
        /// the cursor moves to a different line.
        private var hidden = IndexSet()
        private var decorations: [MarkdownDecoration] = []
        private var revealedLine = NSRange(location: NSNotFound, length: 0)
        private var restyleTask: Task<Void, Never>?
        private var snippetObserver: NSObjectProtocol?
        private weak var textView: NSTextView?

        init(_ parent: SourceEditor) { self.parent = parent }

        deinit {
            if let snippetObserver { NotificationCenter.default.removeObserver(snippetObserver) }
        }

        func attach(_ textView: NSTextView) { self.textView = textView }

        // MARK: Text changes

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            scheduleRestyle(textView)
        }

        /// Debounced: restyling on every keystroke stutters on long notes, and
        /// the delay is imperceptible.
        private func scheduleRestyle(_ textView: NSTextView) {
            restyleTask?.cancel()
            restyleTask = Task { @MainActor [weak textView] in
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled, let textView else { return }
                self.restyle(textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.isLive, let textView = notification.object as? NSTextView else { return }
            updateReveal(in: textView)
        }

        // MARK: Styling

        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string

            decorations = parent.isLive ? LiveDecorator.decorations(in: source) : []

            if parent.isLive {
                MarkdownStyler.applyLive(decorations, to: storage)
                liveLayoutManager?.mathBlocks = MarkdownStyler.mathBlocks(decorations, in: storage)
                liveLayoutManager?.listMarkers = MarkdownStyler.listMarkers(decorations, in: storage)
            } else {
                MarkdownStyler.applySource(to: storage)
                liveLayoutManager?.mathBlocks = []
                liveLayoutManager?.listMarkers = []
            }

            // Force a full recompute of what is hidden for the new decorations.
            revealedLine = NSRange(location: NSNotFound, length: 0)
            updateReveal(in: textView, forceFullInvalidation: true)
        }

        private var liveLayoutManager: LiveLayoutManager? {
            textView?.layoutManager as? LiveLayoutManager
        }

        // MARK: Reveal-on-cursor

        private func updateReveal(in textView: NSTextView, forceFullInvalidation: Bool = false) {
            guard let layoutManager = textView.layoutManager else { return }
            let source = textView.string as NSString
            let full = NSRange(location: 0, length: source.length)

            let newLine: NSRange
            if parent.isLive {
                let selection = textView.selectedRange()
                let clamped = NSRange(
                    location: min(selection.location, source.length),
                    length: min(selection.length, max(0, source.length - min(selection.location, source.length)))
                )
                newLine = source.lineRange(for: clamped)
            } else {
                newLine = NSRange(location: NSNotFound, length: 0)
            }

            let previousLine = revealedLine
            guard forceFullInvalidation || !NSEqualRanges(previousLine, newLine) else { return }
            revealedLine = newLine

            var next = IndexSet()
            if parent.isLive {
                let math = liveLayoutManager?.mathBlocks ?? []

                for decoration in decorations {
                    guard !isRevealed(decoration, line: newLine) else { continue }
                    for range in decoration.syntax where range.length > 0 {
                        next.insert(integersIn: range.location..<NSMaxRange(range))
                    }
                    // Rendered math hides its source; the image stands in. Inline
                    // math keeps its final character, which carries the reserved
                    // width as kerning.
                    guard let block = math.first(where: { NSEqualRanges($0.range, decoration.range) })
                    else { continue }
                    next.insert(integersIn: block.range.location..<NSMaxRange(block.range))
                }
            }

            guard forceFullInvalidation || next != hidden else { return }
            hidden = next
            liveLayoutManager?.revealedLine = newLine

            // Only the previously and newly revealed lines can have changed
            // state, so invalidating the whole document is unnecessary except
            // when the decorations themselves were rebuilt.
            let invalid: NSRange
            if forceFullInvalidation {
                invalid = full
            } else {
                invalid = NSUnionRange(
                    previousLine.location == NSNotFound ? newLine : previousLine,
                    newLine.location == NSNotFound ? previousLine : newLine
                )
            }
            let safe = NSIntersectionRange(invalid, full)
            guard safe.length > 0 || full.length == 0 else { return }

            layoutManager.invalidateGlyphs(
                forCharacterRange: safe, changeInLength: 0, actualCharacterRange: nil
            )
            layoutManager.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
            textView.needsDisplay = true
        }

        private func isRevealed(_ decoration: MarkdownDecoration, line: NSRange) -> Bool {
            guard line.location != NSNotFound else { return false }
            return NSIntersectionRange(decoration.range, line).length > 0
                // A cursor sitting exactly at a boundary still counts as inside,
                // otherwise markup flickers as you arrow past it.
                || NSLocationInRange(decoration.range.location, line)
                || NSMaxRange(decoration.range) == line.location
        }

        // MARK: Glyph suppression

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard !hidden.isEmpty else { return 0 }

            var adjusted = [NSLayoutManager.GlyphProperty](
                UnsafeBufferPointer(start: properties, count: glyphRange.length)
            )
            var changed = false
            for offset in 0..<glyphRange.length where hidden.contains(characterIndexes[offset]) {
                // `.null` removes the glyph from layout entirely: zero width,
                // no drawing, while the character stays in the storage.
                adjusted[offset] = .null
                changed = true
            }
            guard changed else { return 0 }

            adjusted.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                layoutManager.setGlyphs(
                    glyphs, properties: base, characterIndexes: characterIndexes,
                    font: font, forGlyphRange: glyphRange
                )
            }
            return glyphRange.length
        }

        // MARK: Links

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            parent.onFollowLink(url)
            return true
        }

        func observeSnippets(into textView: NSTextView) {
            snippetObserver = NotificationCenter.default.addObserver(
                forName: .heftInsertSnippet, object: nil, queue: .main
            ) { [weak textView] note in
                guard let textView, let snippet = note.object as? String else { return }
                textView.insertText(snippet, replacementRange: textView.selectedRange())
            }
        }
    }
}

// MARK: - Text view

/// NSTextView with vault-aware paste and drop.
final class HeftTextView: NSTextView {
    var onAttachment: ((NSPasteboard) -> String?)?
    var onFollowLink: ((URL) -> Void)?

    override func paste(_ sender: Any?) {
        if let markdown = onAttachment?(NSPasteboard.general) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }

    /// Clicking a drawn checkbox toggles the task, as in Obsidian. Everything
    /// else falls through to normal text interaction.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let manager = layoutManager as? LiveLayoutManager,
           let marker = manager.taskMarker(at: point, origin: textContainerOrigin),
           case .task(let checked) = marker.kind {
            toggleTask(marker.range, currentlyChecked: checked)
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleTask(_ markerRange: NSRange, currentlyChecked: Bool) {
        let text = string as NSString
        guard NSMaxRange(markerRange) <= text.length else { return }
        // Replace only the character between the brackets, so indentation and
        // the bullet style of the original line are preserved exactly.
        let marker = text.substring(with: markerRange)
        guard let box = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return }
        let innerOffset = marker.distance(from: marker.startIndex, to: box.lowerBound) + 1
        let target = NSRange(location: markerRange.location + innerOffset, length: 1)
        let replacement = currentlyChecked ? " " : "x"

        guard shouldChangeText(in: target, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: target, with: replacement)
        didChangeText()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let markdown = onAttachment?(sender.draggingPasteboard) {
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - Layout manager

/// Draws rendered LaTeX over the (hidden) source of a `$$…$$` block.
///
/// The space is reserved by forcing the line height of the block's paragraph,
/// so the image sits in real layout without an `NSTextAttachment` — attachments
/// would require inserting a placeholder character into the document.
final class LiveLayoutManager: NSLayoutManager {
    struct MathBlock {
        /// The whole `$…$` or `$$…$$` construct, used for reveal checks.
        let range: NSRange
        /// The character whose laid-out rect positions the image. For inline
        /// math this is the closing `$`, widened with kerning to reserve space.
        let anchor: NSRange
        let image: NSImage
        let isInline: Bool
    }

    /// A list bullet, checkbox or numeral drawn in place of hidden source.
    struct ListMarker {
        let range: NSRange
        /// First *visible* character of the item, used to find its line
        /// fragment. The marker's own glyphs are suppressed, and a null glyph
        /// resolves to the preceding line's fragment, which drew every marker
        /// one line too high.
        let lineStart: Int
        let kind: ListMarkerKind
        /// Label to draw for an ordered item, e.g. "3.".
        let label: String
        let indent: CGFloat
    }

    var mathBlocks: [MathBlock] = [] { didSet { invalidateDisplay(forCharacterRange: fullRange) } }
    var listMarkers: [ListMarker] = [] { didSet { invalidateDisplay(forCharacterRange: fullRange) } }
    var revealedLine = NSRange(location: NSNotFound, length: 0)

    private var fullRange: NSRange {
        NSRange(location: 0, length: textStorage?.length ?? 0)
    }

    func hasImage(for range: NSRange) -> Bool {
        mathBlocks.contains { NSEqualRanges($0.range, range) }
    }

    /// Where a marker's glyph is painted. Also used to hit-test checkbox clicks.
    func markerRect(_ marker: ListMarker, origin: NSPoint, size: NSSize) -> NSRect? {
        guard marker.lineStart < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: marker.lineStart)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard line.height > 0 else { return nil }
        return NSRect(
            x: origin.x + line.minX + marker.indent - size.width - 7,
            y: origin.y + line.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// The task marker whose checkbox contains `point`, if any.
    func taskMarker(at point: NSPoint, origin: NSPoint) -> ListMarker? {
        listMarkers.first { marker in
            guard case .task = marker.kind else { return false }
            guard let rect = markerRect(marker, origin: origin, size: Self.checkboxSize) else { return false }
            // Generous target: a 14pt box is small for a pointer.
            return rect.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    static let checkboxSize = NSSize(width: 14, height: 14)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawListMarkers(forGlyphRange: glyphsToShow, at: origin)
        guard !mathBlocks.isEmpty else { return }

        for block in mathBlocks {
            // While the cursor is inside, the source is shown instead.
            if revealedLine.location != NSNotFound,
               NSIntersectionRange(block.range, revealedLine).length > 0 { continue }

            let anchorGlyphs = self.glyphRange(forCharacterRange: block.anchor, actualCharacterRange: nil)
            guard NSIntersectionRange(anchorGlyphs, glyphsToShow).length > 0 else { continue }

            let target: NSRect
            if block.isInline {
                // The anchor glyph carries the reserved width as kerning, so its
                // bounding rect is exactly the box the image should fill.
                let box = boundingRect(forGlyphRange: anchorGlyphs, in: textContainers[0])
                let line = lineFragmentRect(forGlyphAt: anchorGlyphs.location, effectiveRange: nil)
                let size = block.image.size
                target = NSRect(
                    x: origin.x + box.minX,
                    y: origin.y + line.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            } else {
                // With every glyph hidden the bounding rect collapses, but the
                // line fragments still hold the height reserved by the
                // paragraph style, so union those instead.
                var union = NSRect.null
                enumerateLineFragments(forGlyphRange: anchorGlyphs) { rect, _, _, _, _ in
                    union = union.isNull ? rect : union.union(rect)
                }
                guard !union.isNull, union.height > 1 else { continue }

                let size = block.image.size
                let scale = min(1, (union.width - 16) / max(size.width, 1))
                let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
                target = NSRect(
                    x: origin.x + union.midX - drawSize.width / 2,
                    y: origin.y + union.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
            }
            // `respectFlipped` matters: a text view draws in a flipped
            // coordinate system, and without it the glyphs come out mirrored.
            block.image.draw(
                in: target, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }
    }

    private func drawListMarkers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !listMarkers.isEmpty else { return }

        for marker in listMarkers {
            // With the cursor on the line, the raw `- [x]` source is shown.
            if revealedLine.location != NSNotFound,
               NSIntersectionRange(marker.range, revealedLine).length > 0 { continue }

            let glyphs = glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }

            switch marker.kind {
            case .task(let checked):
                guard let rect = markerRect(marker, origin: origin, size: Self.checkboxSize) else { continue }
                let name = checked ? "checkmark.square.fill" : "square"
                let tint: NSColor = checked ? .controlAccentColor : .tertiaryLabelColor
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { continue }
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    .applying(.init(paletteColors: [tint]))
                symbol.withSymbolConfiguration(config)?.draw(
                    in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil
                )

            case .bullet:
                let size = NSSize(width: 12, height: 14)
                guard let rect = markerRect(marker, origin: origin, size: size) else { continue }
                draw(text: "•", in: rect, color: .secondaryLabelColor, bold: true)

            case .ordered:
                let width = max(18, CGFloat(marker.label.count) * 8)
                let size = NSSize(width: width, height: 14)
                guard let rect = markerRect(marker, origin: origin, size: size) else { continue }
                draw(text: marker.label, in: rect, color: .tertiaryLabelColor, bold: false)
            }
        }
    }

    private func draw(text: String, in rect: NSRect, color: NSColor, bold: Bool) {
        let font = bold
            ? NSFont.systemFont(ofSize: Theme.liveFont.pointSize, weight: .bold)
            : NSFont.monospacedDigitSystemFont(ofSize: Theme.liveFont.pointSize - 1, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ])
        let size = attributed.size()
        attributed.draw(at: NSPoint(
            x: rect.maxX - size.width,
            y: rect.midY - size.height / 2
        ))
    }
}

// MARK: - Styling

/// Turns decorations into text attributes.
enum MarkdownStyler {

    static func applySource(to storage: NSTextStorage, font: NSFont = Theme.editorFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        storage.endEditing()
        // Source mode keeps the lightweight highlighting of the raw markup.
        LegacyHighlighter.apply(to: storage)
    }

    static func applyLive(_ decorations: [MarkdownDecoration], to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let base = Theme.liveFont

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        paragraph.paragraphSpacing = 6

        storage.beginEditing()
        storage.setAttributes([
            .font: base,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ], range: full)

        for decoration in decorations {
            apply(decoration, to: storage, base: base)
        }
        storage.endEditing()
    }

    private static func apply(_ decoration: MarkdownDecoration, to storage: NSTextStorage, base: NSFont) {
        let range = decoration.range
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }

        switch decoration.style {
        // Raw source mode styles pipes and image syntax as plain text; only the
        // live surface draws them as grids and pictures.
        case .table, .image:
            break

        case .frontmatter:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 2, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: range)

        case .codeBlock:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.quaternarySystemFill,
            ], range: range)

        case .heading(let level):
            let sizes: [CGFloat] = [26, 22, 19, 17, 15.5, 14.5]
            let size = sizes[min(max(level, 1), 6) - 1]
            storage.addAttribute(
                .font, value: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold),
                range: range
            )

        case .blockQuote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)

        case .listMarker(let kind, let depth):
            // The marker itself is hidden and redrawn, so the text needs a
            // hanging indent to sit right of the bullet — including wrapped
            // lines, which is what `headIndent` handles.
            let line = (storage.string as NSString).lineRange(for: range)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3.5
            style.paragraphSpacing = 2
            style.firstLineHeadIndent = listIndent(depth: depth)
            style.headIndent = listIndent(depth: depth)
            storage.addAttribute(.paragraphStyle, value: style, range: line)

            guard case .task(true) = kind else { break }
            // Strike through a completed task's text.
            let rest = NSRange(
                location: NSMaxRange(range),
                length: max(0, NSMaxRange(line) - NSMaxRange(range))
            )
            if rest.length > 0 {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: rest)
            }

        case .bold:
            addTrait(.boldFontMask, to: storage, range: range, base: base)
        case .italic:
            addTrait(.italicFontMask, to: storage, range: range, base: base)

        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .highlight:
            storage.addAttribute(
                .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.30), range: range
            )

        case .inlineCode:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.quaternarySystemFill,
            ], range: range)

        case .wikiLink(let target, _):
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            if let url = InlineText.heftURL(target: target) {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .link(let destination):
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            if let url = URL(string: destination), url.scheme != nil {
                storage.addAttributes([.link: url, .cursor: NSCursor.pointingHand], range: range)
            }

        case .tag:
            storage.addAttributes([
                .foregroundColor: NSColor.systemPurple,
                .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.12),
            ], range: range)

        case .inlineMath:
            // Not image-rendered in the editor: reserving inline horizontal
            // space needs an attachment character, which would change the file.
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.systemTeal,
            ], range: range)

        case .blockMath(let latex):
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.systemTeal,
            ], range: range)
            guard let image = renderedMath(latex, display: true) else { break }
            // Reserve the image's height by forcing the line height across the
            // block's lines; the layout manager draws into that space.
            let lineCount = max(1, (storage.string as NSString)
                .substring(with: range).components(separatedBy: "\n").count)
            let perLine = ceil((image.size.height + 16) / CGFloat(lineCount))
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = perLine
            style.maximumLineHeight = perLine
            style.alignment = .center
            storage.addAttribute(.paragraphStyle, value: style, range: range)

        case .thematicBreak:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    /// Math that actually rendered, paired with its image. Expressions that
    /// fail to parse (usually mid-typing) are absent and stay as source.
    /// Display math that rendered, paired with its image.
    ///
    /// Only `$$…$$` blocks are drawn in the editor. Inline `$…$` is left as
    /// styled source deliberately: reserving inline horizontal space needs the
    /// width to sit on a single character, and a character cannot break across
    /// lines, so a formula near the right margin clips instead of wrapping.
    /// Both `.kern` (trailing space, which the typesetter lets overflow) and
    /// `.expansion` were tried and neither wraps. Doing it properly requires an
    /// attachment character, i.e. a display string that differs from the
    /// document — which is not worth risking file integrity for. Inline math
    /// renders fully in Preview.
    static func mathBlocks(
        _ decorations: [MarkdownDecoration],
        in storage: NSTextStorage
    ) -> [LiveLayoutManager.MathBlock] {
        decorations.compactMap { decoration in
            guard case .blockMath(let latex) = decoration.style,
                  NSMaxRange(decoration.range) <= storage.length,
                  let image = renderedMath(latex, display: true)
            else { return nil }
            return LiveLayoutManager.MathBlock(
                range: decoration.range, anchor: decoration.range, image: image, isInline: false
            )
        }
    }

    static func listIndent(depth: Int) -> CGFloat { 22 + CGFloat(depth) * 20 }

    /// List markers to draw, in place of the source the editor hides.
    static func listMarkers(
        _ decorations: [MarkdownDecoration], in storage: NSTextStorage
    ) -> [LiveLayoutManager.ListMarker] {
        let text = storage.string as NSString
        return decorations.compactMap { decoration in
            guard case .listMarker(let kind, let depth) = decoration.style,
                  NSMaxRange(decoration.range) <= storage.length
            else { return nil }

            // For an ordered item the numeral is redrawn verbatim, so pull it
            // straight out of the source rather than recomputing it.
            let label = text.substring(with: decoration.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return LiveLayoutManager.ListMarker(
                range: decoration.range,
                lineStart: min(NSMaxRange(decoration.range), max(0, storage.length - 1)),
                kind: kind,
                label: label,
                indent: listIndent(depth: depth)
            )
        }
    }

    private static func renderedMath(_ latex: String, display: Bool) -> NSImage? {
        MathRenderer.image(
            latex: latex,
            fontSize: Theme.liveFont.pointSize + (display ? 3 : 0),
            color: .textColor,
            display: display
        )
    }

    private static func addTrait(
        _ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange, base: NSFont
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? base
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }
}

/// Regex highlighting for raw source mode, where nothing is hidden.
enum LegacyHighlighter {
    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        for (pattern, attributes) in rules {
            pattern.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attributes, range: match.range)
            }
        }
        storage.endEditing()
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
        (regex(#"^```[\s\S]*?^```"#), [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: Theme.editorFont.pointSize - 0.5, weight: .regular),
        ]),
        (regex(#"^#{1,6}\s+.*$"#), [.font: NSFont.boldSystemFont(ofSize: Theme.editorFont.pointSize + 2)]),
        (regex(#"^>\s?.*$"#), [.foregroundColor: NSColor.secondaryLabelColor]),
        (regex(#"\*\*[^*\n]+\*\*"#), [.font: NSFont.boldSystemFont(ofSize: Theme.editorFont.pointSize)]),
        (regex(#"`[^`\n]+`"#), [.foregroundColor: NSColor.systemPink]),
        (regex(#"==[^=\n]+=="#), [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.28)]),
        (regex(#"!?\[\[[^\]\n]+\]\]"#), [.foregroundColor: NSColor.controlAccentColor]),
        (regex(#"\[[^\]\n]*\]\([^)\n]*\)"#), [.foregroundColor: NSColor.controlAccentColor]),
        (regex(#"(?<![\w/])#[A-Za-z][\w/-]*"#), [.foregroundColor: NSColor.systemPurple]),
        (regex(#"\$\$?[^$\n]+\$\$?"#), [.foregroundColor: NSColor.systemTeal]),
        (regex(#"\A---\n[\s\S]*?\n---"#), [.foregroundColor: NSColor.tertiaryLabelColor]),
    ]
}
