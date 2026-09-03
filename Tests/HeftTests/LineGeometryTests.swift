import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// How tall a line of the live surface ends up, which is not always obvious:
/// most of what the editor draws replaces characters that are still in the
/// buffer, so a line can hold text and have no height at all.
@Suite("Empty quote lines")
@MainActor
struct EmptyQuoteLineTests {

    /// The height the styler reserves for the line beginning at `offset`.
    private func reservedHeight(_ source: String, lineStartingAt offset: Int) -> CGFloat {
        let storage = NSTextStorage(string: source)
        _ = LiveStyler.apply(
            to: storage, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 600
        )
        let style = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
            as? NSParagraphStyle
        return style?.minimumLineHeight ?? 0
    }

    /// Every character of `> ` is collapsed markup, so a quote line with no
    /// text of its own is entirely hairline font. TextKit then gives it a
    /// fragment barely over zero high, and pressing Return inside a quote made
    /// exactly that line: a slot a fraction of a line tall, with nowhere to put
    /// the caret. Return does insert the marker, and always did; what was
    /// missing was anywhere to stand.
    @Test("A quote line with no text still stands a line high")
    func emptyQuoteLineKeepsItsHeight() {
        let source = "> quote line\n> \n\nafter\n"
        let emptyLine = (source as NSString).range(of: "> \n").location
        let bodyHeight = reservedHeight(source, lineStartingAt: 0)
        #expect(bodyHeight > 0, "a quote line with text reserves a line")
        #expect(reservedHeight(source, lineStartingAt: emptyLine) == bodyHeight)
    }

    /// The same reservation is what leaves room for a callout's drawn icon and
    /// label when its header carries no text either, so it has to survive.
    @Test("A callout header with no title of its own keeps its room")
    func untitledCalloutKeepsItsRoom() {
        #expect(reservedHeight("> [!tip]\n> Body.\n", lineStartingAt: 0) > 0)
    }
}

/// TextKit puts an empty line fragment after a document's final newline, inside
/// the last paragraph's own layout fragment. Anything painted to that
/// fragment's full height — a quote bar, a callout card, a code block's
/// background — therefore stood a whole line proud of its contents on the last
/// line of a note, and only there.
@Suite("The last line of a note")
@MainActor
struct TrailingLineFragmentTests {

    /// Lays `source` out in a real TextKit 2 view and hands back its fragments.
    private func fragments(_ source: String) -> [HeftLayoutFragment] {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(source), documentIdentity: "t.md", generation: 0,
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
        view.string = source
        coordinator.restyle(view)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        var found: [HeftLayoutFragment] = []
        view.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) {
            if let fragment = $0 as? HeftLayoutFragment { found.append(fragment) }
            return true
        }
        return found
    }

    /// Exactly what the card is painted to, rather than a restatement of it.
    private func cardHeight(_ fragment: HeftLayoutFragment) -> CGFloat {
        fragment.paintedBackgroundHeight
    }

    @Test("A callout's card is the same height last in a note as anywhere else")
    func cardIsNotTallerOnTheLastLine() {
        let callout = "> [!info] A title\n"
        guard let last = fragments(callout).last,
              let notLast = fragments(callout + "\nafter\n").first
        else {
            Issue.record("no fragments were laid out")
            return
        }
        #expect(
            last.emptyTrailingHeight > 0,
            "the last line really does carry an empty trailing fragment"
        )
        // A whole line of difference is the bug; what is left is the line
        // spacing that belonged to the empty fragment, about a fifth of a line
        // and not worth guessing a paragraph style to remove.
        let oneLine = notLast.textLineFragments[0].typographicBounds.height
        #expect(
            cardHeight(last) - cardHeight(notLast) < oneLine / 2,
            "the card is within half a line of the same card elsewhere"
        )
        // Measuring a real difference: the raw frame is a full line taller,
        // which is exactly what used to be painted.
        #expect(
            last.layoutFragmentFrame.height - notLast.layoutFragmentFrame.height >= oneLine
        )
    }

    @Test("A line with something after it has no empty trailing fragment")
    func onlyTheLastLineCarriesOne() {
        let fragments = fragments("first\nsecond\n")
        #expect(fragments.first?.emptyTrailingHeight == 0)
        #expect(fragments.last?.emptyTrailingHeight ?? 0 > 0)
    }
}
