import AppKit
import HeftCore

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
        printInfo: NSPrintInfo = NSPrintInfo.shared
    ) -> Bool {
        let info = printInfo.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = defaultMargin
        info.bottomMargin = defaultMargin
        info.leftMargin = defaultMargin
        info.rightMargin = defaultMargin
        // Not `.fit`: the view is already built at exactly the printable
        // width, and `.fit` would scale it to the page on top of that —
        // enlarging every glyph and pushing the text out past the margin it
        // was laid out to respect.
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // The view is as wide as the page's printable area; the gutter it adds
        // for itself supplies the rest of the margin.
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = renderView(text: text, context: context, width: width)

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
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
        return view
    }
}
