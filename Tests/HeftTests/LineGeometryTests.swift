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

/// A list item wrapped by a hard line break is still one item, and every line
/// of it has to start where the first one does.
@Suite("Wrapped list items")
@MainActor
struct ListContinuationTests {

    /// The head indent the styler gives the line beginning at `offset`.
    private func indent(_ source: String, lineStartingAt offset: Int) -> CGFloat {
        let storage = NSTextStorage(string: source)
        _ = LiveStyler.apply(
            to: storage, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 600
        )
        let style = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
            as? NSParagraphStyle
        return style?.headIndent ?? 0
    }

    private func offset(of line: String, in source: String) -> Int {
        (source as NSString).range(of: line).location
    }

    @Test("The second half of a hard-wrapped bullet keeps the bullet's indent")
    func continuationKeepsTheIndent() {
        // A paragraph style applies to a paragraph, and the hard break starts
        // a new one, so the continuation used to fall back to the left margin:
        // a long bullet in a narrow window rendered ragged.
        let source = "- an item with a hard break  \n  and the rest of it\n\nplain\n"
        let item = indent(source, lineStartingAt: 0)
        #expect(item > 0)
        #expect(indent(source, lineStartingAt: offset(of: "  and the rest", in: source)) == item)
        // A paragraph after the blank line is not part of the item.
        #expect(indent(source, lineStartingAt: offset(of: "plain", in: source)) == 0)
    }

    @Test("A nested item's continuation carries the nested indent, not its parent's")
    func nestedContinuation() {
        let source = "- outer\n  - inner item  \n    carried on\n"
        let outer = indent(source, lineStartingAt: 0)
        let inner = indent(source, lineStartingAt: offset(of: "  - inner", in: source))
        #expect(inner > outer)
        #expect(indent(source, lineStartingAt: offset(of: "    carried on", in: source)) == inner)
    }

    @Test("A block that follows a list item is that block, not the rest of the bullet")
    func blocksAreNotSwallowed() {
        // Each of these used to be the case for reading the run as "anything
        // non-blank after a list line". A heading, a quote, a fence, a
        // thematic break and display maths all own their line outright.
        for follower in ["# A heading", "> a quote", "```\nfenced\n```", "---", "$$x = 1$$"] {
            let source = "- item\n\(follower)\nlast\n"
            let item = indent(source, lineStartingAt: 0)
            let after = indent(source, lineStartingAt: offset(of: follower, in: source))
            #expect(after != item, "\(follower) should not take the list's indent")
        }
    }

    @Test("A lazy continuation with no indentation of its own still lines up")
    func lazyContinuation() {
        // CommonMark and Obsidian both read this as part of the item, and the
        // ragged rendering is at its worst here: nothing in the source hints
        // that the line belongs to the bullet.
        let source = "- an item\ncarried on with no indent\n"
        #expect(
            indent(source, lineStartingAt: offset(of: "carried on", in: source))
                == indent(source, lineStartingAt: 0)
        )
    }
}

/// Where the pointer says "this is a button" rather than "this is text".
///
/// The first attempt at this shipped and did nothing, and the reason is worth
/// keeping: `addCursorRect` looks like the answer and loses to `NSTextView`'s
/// own `documentCursor`, and the `cursorUpdate` override that does win was
/// never called, because a plain `NSTextView` installs no tracking areas at
/// all. Both halves were dead code and no test noticed, because the geometry
/// was right the whole time.
@Suite("Pointer over a checkbox")
@MainActor
struct PointerCursorTests {

    private func editor(_ source: String) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.string = source
        _ = LiveStyler.apply(
            to: view.textStorage!, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 644
        )
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    @Test("A task line has a clickable region, and it is only the gutter")
    func checkboxHasItsOwnRegion() {
        let view = editor("- [ ] a task with words after it\n")
        let rects = view.pointerRects()
        #expect(!rects.isEmpty, "the drawn checkbox had no region at all")

        // The box sits in the gutter, left of where the text begins. Well into
        // the words is ordinary text and must keep the I-beam, or the whole
        // line would read as a button.
        let box = rects[0]
        #expect(box.midX < view.textContainerInset.width + LiveStyler.listIndent(depth: 0))
        #expect(!rects.contains { $0.contains(CGPoint(x: 300, y: box.midY)) })
    }

    /// The check that was never made, and the one that found the bug: the
    /// hover region is built from `rect(forSelection:)` while the click is
    /// hit-tested with `characterIndexForInsertion`, and nothing tied the two
    /// together. A region on the wrong line is invisible to every other test —
    /// the geometry looks perfectly reasonable in isolation.
    @Test("Every task gets a region, and each is over its own line")
    func regionsLineUpWithTheirLines() {
        let source = "# Title\n\nsome prose\n\n- [ ] first task\n- [ ] second task\n"
        let view = editor(source)
        let text = source as NSString
        let rects = view.pointerRects()

        #expect(rects.count == 2, "two tasks, two regions; got \(rects.count)")
        for rect in rects {
            let index = view.characterIndexForInsertion(
                at: CGPoint(x: rect.midX, y: rect.midY)
            )
            let line = text.lineRange(for: NSRange(location: min(index, text.length - 1), length: 0))
            #expect(
                text.substring(with: line).hasPrefix("- [ ]"),
                "a region sits over \(text.substring(with: line).debugDescription)"
            )
        }
    }

    /// The target is the drawn box with a little slack, and no more.
    ///
    /// It was the whole layout fragment, which is a line spacing taller than
    /// the text and reads as a region reaching well below the box. Worse, a
    /// target taller than it is wide catches clicks meant for the line below,
    /// and the click and the cursor share these rects.
    @Test("A target is the size of the box, not the size of the line")
    func targetIsTheBoxNotTheLine() {
        let view = editor("- [ ] one\n- [ ] two\n- [ ] three\n")
        let rects = view.checkboxTargets().map(\.rect)
        #expect(rects.count == 3)

        let side = ListGlyph.checkboxSide
        for rect in rects {
            #expect(rect.height == rect.width, "the drawn box is square, so this is too")
            #expect(rect.height > side)
            #expect(rect.height < side + 8, "reaching past the box catches the line below")
        }

        let sorted = rects.sorted { $0.minY < $1.minY }
        for (above, below) in zip(sorted, sorted.dropFirst()) {
            #expect(above.maxY < below.minY, "targets run into one another")
        }
    }

    /// The target has to be centred on the box, and the box is centred on the
    /// *text*, not on the layout fragment. Those differ by 1pt on an ordinary
    /// line and by 8pt on the last line of a note, where the fragment also
    /// covers TextKit's empty trailing one — so centring on the fragment puts
    /// the last target almost entirely below its box.
    ///
    /// Evenly spaced lines must give evenly spaced targets; anything measured
    /// from the fragment breaks that on the last line alone.
    @Test("Targets are spaced like the lines they sit on")
    func targetsFollowTheLinePitch() {
        let view = editor("- [ ] one\n- [ ] two\n- [ ] three\n- [ ] four\n")
        let centres = view.checkboxTargets().map(\.rect.midY).sorted()
        #expect(centres.count == 4)
        let pitches = zip(centres, centres.dropFirst()).map { $1 - $0 }
        for pitch in pitches {
            #expect(abs(pitch - pitches[0]) < 0.5,
                    "uneven spacing \(pitches): a target is not on its box")
        }
    }

    /// TextKit lays an empty line fragment after a document's final newline
    /// and puts it inside the last paragraph's layout fragment, so measuring
    /// that frame made the last checkbox in a note claim a region an extra
    /// line deep. `LiveWidgets` already corrects for this when painting.
    @Test("The last checkbox in a note is no taller than the others")
    func lastLineIsNotTaller() {
        let view = editor("- [ ] one\n- [ ] two\n")
        let heights = Set(view.checkboxTargets().map(\.rect.height))
        #expect(heights.count == 1, "got \(heights)")
    }

    /// A boundary is a place a pointer is often parked, and a hand holding a
    /// mouse still moves by a pixel or two: without hysteresis that alternated
    /// between the two cursor shapes.
    @Test("Leaving a target takes more than entering it")
    func targetHasHysteresis() {
        let view = editor("- [ ] a task with words after it\n")
        let rects = view.pointerRects()
        let box = try! #require(rects.first)

        // Arriving: only the real target counts, so the hand does not appear
        // early over the words beside the box.
        let justOutside = CGPoint(x: box.maxX + 2, y: box.midY)
        #expect(view.pointerTarget(at: justOutside, among: rects) == nil)

        // Inside, then jittering back to that same point: it holds.
        #expect(view.pointerTarget(at: CGPoint(x: box.midX, y: box.midY), among: rects) != nil)
        #expect(view.pointerTarget(at: justOutside, among: rects) != nil)

        // Far enough out and it lets go, and stays gone.
        let wellOutside = CGPoint(x: box.maxX + 20, y: box.midY)
        #expect(view.pointerTarget(at: wellOutside, among: rects) == nil)
        #expect(view.pointerTarget(at: justOutside, among: rects) == nil)
    }

    /// Asked on every pointer move, so it must not be doing layout queries.
    /// Measured before caching: 2.6ms a call on a 21KB note, which at the rate
    /// a pointer moves is about a third of the main thread.
    @Test("Asking where the pointer is costs nothing once the layout has settled")
    func pointerRectsAreCached() {
        var lines: [String] = []
        for i in 0..<300 {
            lines.append(i % 3 == 0 ? "- [ ] task \(i) with a reasonable amount of text"
                                    : "Ordinary prose on line \(i) to fill the note out.")
        }
        let view = editor(lines.joined(separator: "\n") + "\n")
        #expect(!view.pointerRects().isEmpty)

        let start = Date()
        for _ in 0..<500 { _ = view.pointerRects() }
        let each = Date().timeIntervalSince(start) / 500 * 1000
        #expect(each < 0.05, "\(each) ms per call is a layout query on every mouse move")
    }

    /// And the cache has to let go when the layout moves under it, or the
    /// regions are left where the text used to be.
    @Test("Editing the note rebuilds the regions")
    func invalidationRebuildsTheRegions() {
        let view = editor("- [ ] one\n- [ ] two\n")
        let before = view.pointerRects()
        #expect(before.count == 2)

        view.string = "- [ ] one\n"
        _ = LiveStyler.apply(
            to: view.textStorage!, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 644
        )
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        #expect(view.pointerRects() == before, "stale until something says otherwise")

        view.invalidatePointerRects()
        #expect(view.pointerRects().count == 1)
    }

    /// The bug this closes: the click found its line with
    /// `characterIndexForInsertion`, which clamps, so every point in the empty
    /// space below a note landed on the last line and toggled its box.
    @Test("Clicking below the note toggles nothing")
    func clicksBelowTheNoteMissEverything() {
        let view = editor("- [ ] one\n- [ ] two\n")
        let targets = view.checkboxTargets()
        #expect(targets.count == 2)
        let lowest = targets.map(\.rect.maxY).max()!

        // Well below the last line, in the gutter where the boxes are.
        let x = targets[0].rect.midX
        for y in [lowest + 20, lowest + 200, lowest + 2000] {
            #expect(!targets.contains { $0.rect.contains(CGPoint(x: x, y: y)) },
                    "a click at y=\(y) reached a checkbox")
        }
    }

    /// The invariant the shared value buys: the hand appears exactly where a
    /// click works. They used to be two separate pieces of arithmetic.
    @Test("Where the hand shows is where a click toggles")
    func cursorAndClickAgree() {
        let view = editor("# Title\n\n- [ ] one\nprose\n- [ ] two\n")
        let targets = view.checkboxTargets()
        let rects = view.pointerRects()
        #expect(targets.count == 2)
        for target in targets {
            #expect(rects.contains(target.rect))
        }
    }

    /// And the characters it rewrites are the box, not whatever happens to be
    /// three characters from the end of some other marker.
    @Test("A target names its own checkbox")
    func targetNamesItsBox() {
        let source = "- [ ] one\n  - [x] nested\n1. [ ] numbered\n"
        let view = editor(source)
        let text = source as NSString
        let boxes = view.checkboxTargets().map { text.substring(with: $0.box) }
        #expect(boxes == ["[ ]", "[x]", "[ ]"])
    }

    /// With nothing on screen there is nothing to scope to, so the whole
    /// document is the answer. Scoping by rectangle instead was wrong twice:
    /// `visibleRect` is *infinite* for a view with no window rather than
    /// empty, and `characterIndexForInsertion` answers with the end of the
    /// document for its top-left corner.
    @Test("A view nobody has put in a window still finds its checkboxes")
    func noViewportMeansTheWholeDocument() {
        let view = editor("- [ ] one\n- [ ] two\n- [ ] three\n")
        #expect(view.window == nil)
        #expect(view.pointerRects().count == 3)
    }

    @Test("A plain bullet is not a checkbox, and neither is prose")
    func onlyTasksGetARegion() {
        #expect(editor("- an ordinary bullet\n").pointerRects().isEmpty)
        #expect(editor("just a paragraph\n").pointerRects().isEmpty)
        // Every checkbox state Obsidian carries through, not only `[ ]`.
        #expect(!editor("- [x] done\n").pointerRects().isEmpty)
    }
}
