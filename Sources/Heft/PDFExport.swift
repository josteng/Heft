import AppKit
import HeftCore
import PDFKit

/// Renders a note to PDF through the live surface itself.
///
/// Deliberately not a second renderer. The editor already decides what a
/// heading, a table, a callout and a formula look like, and a note is worth
/// exporting precisely because of how it reads on screen; a parallel PDF
/// renderer would drift from it the first time either side changed. So this
/// builds the same `HeftTextKit2View` the window builds, off screen and at
/// paper width, and prints it.
///
/// Always in the light appearance. A PDF is paper: dark-mode ink is white,
/// and white ink on white paper is the bug this had every chance of shipping
/// with.
@MainActor
enum PDFExport {

    /// The white space between the paper's edge and the text.
    ///
    /// Split in two, because the text view insists on part of it. Its
    /// `setFrameSize` re-imposes a horizontal `textContainerInset` of at least
    /// 28pt on every frame change — that inset is what gives the editor its
    /// gutter — so the print margin only has to supply the rest. Setting the
    /// full margin here and a zero inset on the view does not work: the inset
    /// comes straight back, the text is laid out 28pt further in than the
    /// container was sized for, and the last word of every line is clipped off
    /// the right edge of the page.
    static let visualMargin: CGFloat = 56
    static let viewInset: CGFloat = 28
    static var defaultMargin: CGFloat { visualMargin - viewInset }

    /// Writes `text` to `url` as a PDF, and returns false if the print system
    /// declined the job.
    @discardableResult
    static func write(
        text: String,
        context: RenderContext,
        to url: URL,
        title: String? = nil,
        options: PDFExportOptions = PDFExportOptions(),
        printInfo: NSPrintInfo = NSPrintInfo.shared
    ) -> Bool {
        let body = options.includesTitle && !(title ?? "").isEmpty
            ? "# \(title!)\n\n" + text
            : text

        let info = printInfo.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let paper = options.paperSize
        info.paperSize = NSSize(width: paper.width, height: paper.height)
        info.orientation = options.isLandscape ? .landscape : .portrait

        // The view keeps a 28pt gutter of its own on each side whatever the
        // frame, so the print margin only supplies the rest.
        let printMargin = max(0, options.margin.points - Double(viewInset))
        info.topMargin = options.margin.points
        info.bottomMargin = options.margin.points
        info.leftMargin = printMargin
        info.rightMargin = printMargin
        // `.clip`, and neither `.fit` nor `.automatic`.
        //
        // `.fit` would scale the view to the page on top of the scaling below,
        // enlarging every glyph and pushing the text past the margin it was
        // laid out to respect. `.automatic` is worse and subtler: the view is
        // built to be *exactly* page-width once scaled, so a rounding error of
        // a fraction of a point makes it a hair too wide and AppKit splits it
        // into two page-columns — the note then comes out as content, blank
        // page, content, blank page. It showed up only at the narrowest
        // margin, where the arithmetic lands exactly on the boundary.
        //
        // The width is chosen here, so horizontal pagination has nothing to
        // decide and is told not to.
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // Scaling is what makes the export readable as *paper*.
        //
        // The editor's type is sized to be read on a display at arm's length;
        // printed at that size a note runs long and its headings fill a third
        // of the page. The print system scales the whole view uniformly, so
        // laying the text out in a proportionally *wider* column and then
        // shrinking it to the page keeps every relationship intact — fonts,
        // widgets, tables, images and line spacing all come down together —
        // where restyling at a smaller font would not.
        // The editor's own body size is passed in rather than assumed, so the
        // printed size stays what was asked for even if the editor's changes.
        let scale = options.scale(forEditorBodySize: Double(Theme.bodySize))
        info.scalingFactor = scale
        let printable = info.paperSize.width - info.leftMargin - info.rightMargin
        // A hair under, so the scaled width cannot land a rounding error over
        // the page even with `.clip` to catch it.
        let width = (printable - 1) / scale
        let view = renderView(text: body, context: context, width: width)

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { return false }
        removeTrailingBlankPages(at: url)
        return true
    }

    /// Drops any wholly empty page off the end of a finished PDF.
    ///
    /// The print system decides pagination from the view's height, and with a
    /// scaling factor applied that arithmetic can land one page past the last
    /// line: a note that reads as twelve pages arrives as thirteen, the last
    /// one blank. Trimming the view's trailing gutter helps and does not
    /// always settle it, because the rounding is AppKit's, not ours.
    ///
    /// Emptiness is decided by **rasterising**, not by asking for the page's
    /// text. Half of what this editor draws — tables, formulae, images,
    /// bullets, callout cards — is painted by a layout fragment and is not in
    /// the text layer at all, so a page holding nothing but a table reports no
    /// string and would be thrown away by a text test.
    static func removeTrailingBlankPages(at url: URL) {
        guard let document = PDFDocument(url: url), document.pageCount > 1 else { return }
        var removed = false
        while document.pageCount > 1, let last = document.page(at: document.pageCount - 1) {
            guard isBlank(last) else { break }
            document.removePage(at: document.pageCount - 1)
            removed = true
        }
        if removed { document.write(to: url) }
    }

    /// Whether a page has any mark on it, by drawing it small and looking.
    private static func isBlank(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return true }
        // Small on purpose: this is asking "is there any ink", not reading the
        // page, and a hairline rule still covers a pixel at this size.
        let scale = 120 / max(bounds.width, bounds.height)
        let size = NSSize(
            width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let rgb = colour.usingColorSpace(.sRGB) ?? colour
                // Anything appreciably off white is a mark.
                if rgb.redComponent < 0.97 || rgb.greenComponent < 0.97 || rgb.blueComponent < 0.97 {
                    return false
                }
            }
        }
        return true
    }

    /// The off-screen editor the PDF is printed from.
    ///
    /// Built exactly the way the window builds one — same view class, same
    /// coordinator, same styler — because anything else is a second renderer
    /// by another name.
    static func renderView(
        text: String, context: RenderContext, width: CGFloat
    ) -> NSTextView {
        var context = context
        // Paper is light. Resolved here so every colour the styler bakes into
        // a widget or a formula is the one that belongs on white.
        let paper = NSAppearance(named: .aqua)
        context.appearance = paper

        let editor = LiveTextEditor(
            text: .constant(text),
            documentIdentity: "export.md",
            generation: 0,
            generationKeepsPosition: false,
            findSelection: nil,
            insertion: nil,
            context: context,
            onAttachment: { _ in nil },
            onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)

        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.appearance = paper
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .white
        // The frame is the printable width; the view's own `setFrameSize`
        // then puts a `viewInset` gutter on each side and the container tracks
        // what is left. Sizing the container by hand here would be overwritten
        // by that gutter and lay the text out wider than the page.
        view.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = NSSize(
            width: width - viewInset * 2, height: CGFloat.greatestFiniteMagnitude
        )
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = text

        // No caret, so no line reveals its own block markup. Otherwise
        // whichever line the selection sat on came out with a literal `#` or
        // `- ` in the PDF, which is the one thing an export must not do.
        coordinator.renderWithoutCaret()
        coordinator.restyle(view)

        // TextKit 2 estimates the height of anything it has not reached, and
        // this document's fragments are nothing like ordinary lines, so the
        // estimate is far enough out to lose pages off the end.
        //
        // Never `view.layoutManager` here: reaching for the TextKit 1 manager
        // on a TextKit 2 view silently drops the whole view back to TextKit 1,
        // which has no `NSTextLayoutFragment` — so every widget stops being
        // drawn and the PDF comes out with blank gaps where its tables,
        // bullets, callouts and formulae should be. The text still renders,
        // which is what makes it look like a styling bug rather than what it
        // is.
        if let manager = view.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        view.sizeToFit()

        // Trim the trailing gutter.
        //
        // `sizeToFit` leaves the view as tall as its content plus a
        // `textContainerInset` at *both* ends. That bottom inset is 28pt of
        // nothing, and when the text happens to end near a page boundary it is
        // enough to spill one entirely blank page off the end of the PDF — a
        // note that reads as 12 pages arriving as 13, the last one empty.
        //
        // The page's own bottom margin still supplies the white space; this
        // only stops the view claiming height it does not use.
        if let manager = view.textLayoutManager, let content = manager.textContentManager {
            var used: CGFloat = 0
            manager.enumerateTextLayoutFragments(
                from: content.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                used = max(used, fragment.layoutFragmentFrame.maxY)
                return true
            }
            if used > 0 {
                view.setFrameSize(NSSize(
                    width: view.frame.width,
                    height: ceil(used + view.textContainerInset.height)
                ))
            }
        }
        return view
    }
}
