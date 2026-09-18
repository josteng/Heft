import AppKit
import Testing
@testable import Heft

/// Where a note sits the moment it opens.
///
/// The editor's scroll view runs under the toolbar, so AppKit insets it by the
/// chrome's height and the top of the document is `-contentInsets.top`, not
/// zero. Opening a note asked for zero, which a short note survives and a long
/// one does not: the clip view clamps a document shorter than the viewport back
/// to the inset, and accepts zero for a document taller than it. The reader saw
/// the first line of every long note tucked behind the top bar.
@MainActor
@Suite("Initial scroll position")
struct InitialScrollPositionTests {

    private static let chromeHeight: CGFloat = 52

    /// The editor's geometry, with the inset AppKit applies under a toolbar.
    /// The automatic adjustment has to be off before the inset will stick,
    /// because with it on AppKit computes the value itself and there is no
    /// window here to compute it from.
    private func editor(lines: Int) -> (HeftTextKit2View, NSScrollView) {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.string = (0..<lines).map { "line \($0)" }.joined(separator: "\n")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        view.autoresizingMask = [.width]
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(
            top: Self.chromeHeight, left: 0, bottom: 0, right: 0
        )
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        scroll.layoutSubtreeIfNeeded()
        return (view, scroll)
    }

    @Test("A note longer than the window opens below the chrome")
    func longNoteOpensBelowTheChrome() {
        let (view, scroll) = editor(lines: 400)
        #expect(scroll.contentView.documentRect.height > scroll.contentView.bounds.height)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        view.scrollToDocumentTop()
        #expect(scroll.contentView.bounds.origin.y == -Self.chromeHeight)
    }

    /// The case that always worked, kept because it is the reason the bug was
    /// invisible for so long: the clamp did the right thing for free.
    @Test("A note shorter than the window was never affected")
    func shortNoteWasAlwaysRight() {
        let (view, scroll) = editor(lines: 3)
        #expect(scroll.contentView.documentRect.height <= scroll.contentView.bounds.height)

        view.scrollToDocumentTop()
        #expect(scroll.contentView.bounds.origin.y == -Self.chromeHeight)
    }

    /// The defect itself, pinned. `scroll(.zero)` is not a synonym for the top
    /// of an inset scroll view, and on a long note it is out by exactly the
    /// chrome's height.
    @Test("Asking for zero is what put the first line behind the toolbar")
    func scrollingToZeroIsTheDefect() {
        let (view, scroll) = editor(lines: 400)

        view.scroll(.zero)
        let asked = scroll.contentView.bounds.origin.y
        view.scrollToDocumentTop()
        let correct = scroll.contentView.bounds.origin.y

        #expect(asked == 0)
        #expect(correct == -Self.chromeHeight)
        #expect(asked - correct == Self.chromeHeight)
    }

    /// The editor builds views outside a scroll view in tests and in the PDF
    /// export path, where there is no inset to honour and nothing to crash on.
    @Test("A view with no scroll view still goes to the top")
    func noScrollViewIsHarmless() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "line\nline\nline\n"
        view.scrollToDocumentTop()
        #expect(view.enclosingScrollView == nil)
    }
}
