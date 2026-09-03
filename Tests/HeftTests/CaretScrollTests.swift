import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Where the page goes when the caret moves.
///
/// Every styling pass used to scroll to the caret. Two things then moved the
/// page for no reason a reader could see: a restyle the caret had nothing to do
/// with, and a click landing somewhere already perfectly visible. The first
/// click after opening a note hit both at once, which is why it jumped and
/// nothing after it did.
@Suite("Keeping the caret in view")
@MainActor
struct CaretScrollTests {

    /// A note long enough to scroll, with the kind of widgets whose height
    /// TextKit cannot guess.
    private var note: String {
        var body = "# Title\n\nIntro paragraph.\n\n"
        for section in 0..<12 {
            body += "## Section \(section)\n\n| a | b |\n| --- | --- |\n| one | two |\n\n"
            body += "Some prose in section \(section) that runs on for a little while.\n\n"
            body += "- a bullet\n- another\n\n> a quote line\n\n"
        }
        return body
    }

    private func editor(_ body: String) -> (HeftTextKit2View, LiveTextEditor.Coordinator, NSScrollView) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(body), documentIdentity: "s.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = body

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        view.autoresizingMask = [.width]
        return (view, coordinator, scroll)
    }

    /// The offset of the first line whose fragment starts below `y`.
    private func offset(below y: CGFloat, in view: HeftTextKit2View) -> Int {
        guard let manager = view.textLayoutManager else { return 0 }
        var found = 0
        manager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY > y {
                found = manager.offset(
                    from: manager.documentRange.location, to: fragment.rangeInElement.location
                )
                return false
            }
            return true
        }
        return found
    }

    @Test("Clicking somewhere already on screen does not move the page")
    func clickOnAVisibleLineDoesNotScroll() {
        let (view, coordinator, scroll) = editor(note)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle(view)

        // The reader scrolls down. Nothing else happens; the caret stays at the
        // top of the note, which is where it is when a note has just opened.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrolled = scroll.contentView.bounds.origin.y
        #expect(scrolled > 0, "the note has to be long enough to scroll")

        // A pass the caret had nothing to do with, and one that really does
        // work: restyling an unchanged document takes an early exit and never
        // reaches the scroll, so it proves nothing.
        coordinator.resetStyling()
        coordinator.restyle(view)
        #expect(
            scroll.contentView.bounds.origin.y == scrolled,
            "a styling pass scrolled to where the caret happens to be"
        )

        // And the first click, on a line that is already in view.
        view.setSelectedRange(NSRange(location: offset(below: scrolled + 100, in: view), length: 0))
        coordinator.restyle(view)
        #expect(
            scroll.contentView.bounds.origin.y == scrolled,
            "clicking a visible line scrolled to \(scroll.contentView.bounds.origin.y)"
        )
    }

    /// The reason the scroll is there at all: a caret that has left the screen
    /// — an edit from elsewhere, a find match, Vim motion — comes back.
    @Test("A caret off screen is still brought back")
    func caretOffScreenIsBroughtBack() {
        let (view, coordinator, scroll) = editor(note)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle(view)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800))
        scroll.reflectScrolledClipView(scroll.contentView)

        let far = (note as NSString).range(of: "Section 11").location
        view.setSelectedRange(NSRange(location: far, length: 0))
        coordinator.restyle(view)
        #expect(
            scroll.contentView.bounds.origin.y != 1800,
            "a caret below the fold should have brought the page with it"
        )
    }
}
