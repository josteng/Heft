import AppKit
import HeftCore
import Testing
@testable import Heft

/// Where following a link puts the destination, and what it does not do to it.
///
/// The jump reused the find machinery, which selects the whole line and shows
/// AppKit's find indicator. For a search hit that is right: the reader is
/// hunting and wants the match pointed at. For a link it is wrong twice over.
/// The yellow flash looks like an error and appeared only when the scroll was
/// short enough that the range was already laid out, and `scrollRangeToVisible`
/// moves the least it can, so the same link landed at the bottom edge or the
/// top depending on where the reader happened to be standing.
@MainActor
@Suite("Link destination landing")
struct LinkDestinationLandingTests {

    private static let chromeHeight: CGFloat = 52

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

    private func range(ofLine line: Int, in view: NSTextView) -> NSRange {
        NoteText.range(ofLine: line, in: view.string) ?? NSRange(location: 0, length: 0)
    }

    /// The destination's distance from the top of the window, which is what
    /// the reader actually sees, and which must not depend on the direction
    /// the page came from.
    private func distanceBelowChrome(
        _ range: NSRange, _ view: HeftTextKit2View, _ scroll: NSScrollView
    ) -> CGFloat? {
        guard let rect = view.rect(forSelection: range) else { return nil }
        return rect.minY - scroll.contentView.bounds.origin.y - Self.chromeHeight
    }

    @Test("A destination lands below the chrome, not under it")
    func landsBelowTheChrome() throws {
        let (view, scroll) = editor(lines: 400)
        let target = range(ofLine: 200, in: view)

        view.scrollToTop(of: target)
        let distance = try #require(distanceBelowChrome(target, view, scroll))
        #expect(distance == HeftTextKit2View.destinationMargin)
        #expect(distance > 0, "the destination is visible, not behind the toolbar")
    }

    /// The point of scrolling it to the top rather than merely into view: the
    /// section under the heading is what the reader came to read.
    @Test("The same destination lands in the same place from either direction")
    func landsTheSameFromEitherDirection() throws {
        let (view, scroll) = editor(lines: 400)
        let target = range(ofLine: 200, in: view)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        view.scrollToTop(of: target)
        let fromAbove = try #require(distanceBelowChrome(target, view, scroll))

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        view.scrollToTop(of: target)
        let fromBelow = try #require(distanceBelowChrome(target, view, scroll))

        #expect(fromAbove == fromBelow)
    }

    /// Near the end of a document there is not enough left to scroll, and the
    /// clamp has to win rather than leaving the page past its own bottom.
    @Test("A destination near the end is clamped, not overscrolled")
    func aDestinationNearTheEndIsClamped() {
        let (view, scroll) = editor(lines: 400)
        let clip = scroll.contentView

        view.scrollToTop(of: range(ofLine: 400, in: view))
        let maximum = clip.documentRect.height - clip.bounds.height
        #expect(clip.bounds.origin.y <= maximum)
    }

    // MARK: - What the two kinds of jump do

    @Test("A link's destination takes the caret and selects nothing")
    func aDestinationSelectsNothing() {
        let (view, _) = editor(lines: 400)
        let coordinator = coordinatorFor(view)
        let target = range(ofLine: 200, in: view)

        coordinator.landOn(target, in: view)
        #expect(view.selectedRange().length == 0)
        #expect(view.selectedRange().location == target.location)
    }

    /// The contrast, and the reason this is a `LineReveal` and not a flag on
    /// the link path: a search hit still highlights the text it matched.
    @Test("A search match still selects the line it found")
    func aMatchStillSelectsItsLine() {
        let (view, _) = editor(lines: 400)
        let coordinator = coordinatorFor(view)
        let target = range(ofLine: 200, in: view)

        coordinator.selectFindResult(target, in: view)
        #expect(view.selectedRange() == target)
    }

    @Test("A find selection is a match unless it says otherwise")
    func matchIsTheDefault() {
        #expect(FindSelection(range: NSRange(location: 0, length: 1), generation: 1)
            .reveal == .match)
    }

    private func coordinatorFor(_ view: HeftTextKit2View) -> LiveTextEditor.Coordinator {
        let editor = LiveTextEditor(
            text: .constant(view.string), documentIdentity: "s.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        return coordinator
    }
}
