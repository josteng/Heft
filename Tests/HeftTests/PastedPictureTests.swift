import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// Pasting a picture into a note writes `- ![[shot.png]]` whenever the caret is
/// on a bullet, which in a daily log made of bullets is every time. The editor
/// drew nothing for that: `ownsItsLine` asked for whitespace before the embed,
/// and a list marker is not whitespace, so the picture stayed as the filename
/// in blue.
@Suite("A picture on a bullet")
struct PastedPictureTests {

    // MARK: The rule, on its own

    private func marker(_ source: String, around fragment: String) -> Int? {
        let text = source as NSString
        return BlockLine.leadingMarkers(before: text.range(of: fragment), in: text)
    }

    @Test("A list marker may lead a block, and nothing else may")
    func recognisesLeadingMarkers() {
        #expect(marker("![[a.png]]", around: "![[a.png]]") == 0)
        // Indentation alone is still "starts its own line": there is no marker
        // to draw, so nothing has to be carried.
        #expect(marker("   ![[a.png]]", around: "![[a.png]]") == 0)
        #expect(marker("- ![[a.png]]", around: "![[a.png]]") == 2)
        #expect(marker("* ![[a.png]]", around: "![[a.png]]") == 2)
        #expect(marker("+ ![[a.png]]", around: "![[a.png]]") == 2)
        #expect(marker("\t- ![[a.png]]", around: "![[a.png]]") == 3)
        #expect(marker("12. ![[a.png]]", around: "![[a.png]]") == 4)
        #expect(marker("1) ![[a.png]]", around: "![[a.png]]") == 3)
        #expect(marker("- [ ] ![[a.png]]", around: "![[a.png]]") == 6)
        #expect(marker("- [/] ![[a.png]]", around: "![[a.png]]") == 6)

        // A sentence that happens to contain an embed is a sentence. The
        // second of these is the one that matters: the marker is real and the
        // embed does end the line, so only "the marker must reach the embed"
        // separates a picture on a bullet from a bullet ending in a picture.
        #expect(marker("- see ![[a.png]] here", around: "![[a.png]]") == nil)
        #expect(marker("- see ![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("1. see ![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("- [ ] see ![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("- ![[a.png]] and more", around: "![[a.png]]") == nil)
        #expect(marker("prose ![[a.png]]", around: "![[a.png]]") == nil)
        // CommonMark needs the space, so this is not a list at all.
        #expect(marker("-![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("-not a list ![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("- [] ![[a.png]]", around: "![[a.png]]") == nil)
    }

    @Test("A quote's own markers lead a block, and compose with a list's")
    func recognisesQuoteMarkers() {
        #expect(marker("> ![[a.png]]", around: "![[a.png]]") == 2)
        // Two spaces is what Obsidian leaves behind when a line is quoted.
        #expect(marker(">  ![[a.png]]", around: "![[a.png]]") == 3)
        #expect(marker(">![[a.png]]", around: "![[a.png]]") == 1)
        #expect(marker("> > ![[a.png]]", around: "![[a.png]]") == 4)
        #expect(marker("> - ![[a.png]]", around: "![[a.png]]") == 4)
        #expect(marker("> 1. ![[a.png]]", around: "![[a.png]]") == 5)
        #expect(marker("> - [ ] ![[a.png]]", around: "![[a.png]]") == 8)

        #expect(marker("> see ![[a.png]]", around: "![[a.png]]") == nil)

        // A callout's marker leads too, but only when the construct is the
        // whole title. Obsidian draws a picture there; a title with words in
        // it is a title, and replacing the line would take the words with it.
        #expect(marker("> [!note] ![[a.png]]", around: "![[a.png]]") == 10)
        #expect(marker("> [!tip]  ![[a.png]]", around: "![[a.png]]") == 10)
        #expect(marker("> [!note] See ![[a.png]]", around: "![[a.png]]") == nil)
        #expect(marker("> [!note ![[a.png]]", around: "![[a.png]]") == nil)
    }

    @Test("Only the embed's own line is considered")
    func staysOnItsLine() {
        let source = "- above\n![[a.png]]\n- below"
        #expect(marker(source, around: "![[a.png]]") == 0)
        let trailing = "- ![[a.png]]   \nnext line"
        #expect(marker(trailing, around: "![[a.png]]") == 2)
    }

    // MARK: What the surface does with it

    /// A vault holding one real picture, so resolution and decoding are the
    /// live ones rather than a stand-in.
    private func withPictureVault(_ body: (URL, RenderContext) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-picture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        try png.write(to: root.appendingPathComponent("shot.png"))
        try "body".write(
            to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )

        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        try body(root, RenderContext(index: index, current: nil, vaultRoot: root))
    }

    /// The widget the surface would draw on the line `source` begins with.
    private func firstBlock(_ source: String, _ context: RenderContext) -> BlockWidget? {
        let storage = NSTextStorage(string: source)
        let layout = LiveStyler.apply(
            to: storage,
            reveal: .none,
            context: context,
            contentWidth: 600
        )
        return layout.blocks[0]
    }

    @Test("A picture pasted onto a bullet is drawn, and keeps its bullet")
    func drawsPictureOnABullet() throws {
        try withPictureVault { _, context in
            guard case .image(let image, let lead)? =
                firstBlock("- ![[shot.png]]\n", context)
            else {
                Issue.record("a bullet's embed produced no picture")
                return
            }
            #expect(image.size.width > 0)
            // The list's own indent, so the picture lines up with the text of
            // the items above and below it.
            #expect(lead.indent > 0)
            guard case .bullet? = lead.bullet?.glyph else {
                Issue.record("the picture did not carry the bullet it took the line from")
                return
            }
        }
    }

    @Test("Every kind of list marker keeps its own glyph")
    func carriesEveryGlyph() throws {
        try withPictureVault { _, context in
            guard case .image(_, let ordered)? = firstBlock("1. ![[shot.png]]\n", context),
                  case .ordered(let label)? = ordered.bullet?.glyph
            else {
                Issue.record("an ordered item lost its numeral")
                return
            }
            #expect(label == "1.")

            guard case .image(_, let task)? = firstBlock("- [x] ![[shot.png]]\n", context),
                  case .checkbox(let state, _)? = task.bullet?.glyph
            else {
                Issue.record("a task lost its checkbox")
                return
            }
            #expect(state.isDone)
        }
    }

    @Test("A nested item indents the picture further than a top-level one")
    func indentsWithTheList() throws {
        try withPictureVault { _, context in
            guard case .image(_, let top)? = firstBlock("- ![[shot.png]]\n", context),
                  case .image(_, let deeper)? = firstBlock("\t- ![[shot.png]]\n", context)
            else {
                Issue.record("a nested picture produced no widget")
                return
            }
            #expect(deeper.indent > top.indent)
        }
    }

    /// The markdown spelling of the same thing. It already drew the picture,
    /// but by claiming the line's one widget slot it silently deleted the
    /// bullet: the item's text was gone and so was its marker.
    @Test("A markdown image on a bullet keeps its bullet too")
    func markdownImageKeepsItsBullet() throws {
        try withPictureVault { _, context in
            guard case .image(_, let lead)? = firstBlock("- ![](shot.png)\n", context) else {
                Issue.record("a markdown image on a bullet produced no picture")
                return
            }
            #expect(lead.bullet != nil)
        }
    }

    @Test("A transclusion on a bullet keeps its bullet")
    func transclusionKeepsItsBullet() throws {
        try withPictureVault { _, context in
            guard case .embed(_, let lead)? = firstBlock("- ![[note]]\n", context) else {
                Issue.record("a transclusion on a bullet produced no embed")
                return
            }
            #expect(lead.indent > 0)
            #expect(lead.bullet != nil)
        }
    }

    @Test("A picture inside a quote is drawn, and keeps the card behind it")
    func drawsPictureInAQuote() throws {
        try withPictureVault { _, context in
            // The two-space form, which is what the reader actually had.
            guard case .image(_, let lead)? = firstBlock(">  ![[shot.png]]\n", context) else {
                Issue.record("a quoted embed produced no picture")
                return
            }
            #expect(lead.quote?.line.depth == 1)
            #expect(lead.indent > 0)

            guard case .image(_, let nested)? = firstBlock("> - ![[shot.png]]\n", context) else {
                Issue.record("a picture on a quoted bullet produced nothing")
                return
            }
            #expect(nested.quote != nil)
            #expect(nested.bullet != nil, "the quoted list's bullet is still owed")
        }
    }

    /// A picture *is* the title, the way Obsidian draws it: the card and its
    /// icon stay, and the picture takes the place of the words.
    @Test("A picture may be a callout's whole title")
    func drawsPictureAsACalloutTitle() throws {
        try withPictureVault { _, context in
            guard case .image(_, let lead)? =
                firstBlock("> [!note]  ![[shot.png]]\n", context)
            else {
                Issue.record("a picture as a callout title produced no picture")
                return
            }
            #expect(lead.quote?.line.callout != nil, "still a callout, so the card is drawn")
        }
    }

    /// But a title with words in it is a title. Drawing it as a block would
    /// reserve the picture's height on the line those words are on.
    @Test("A callout title that has words keeps them")
    func leavesTitledCalloutsAlone() throws {
        try withPictureVault { _, context in
            guard case .quote? = firstBlock("> [!note] See ![[shot.png]]\n", context) else {
                Issue.record("a titled callout stopped being a callout")
                return
            }
        }
    }

    /// The guard the whole feature turns on: an embed sharing its line with
    /// prose is not a block, and drawing it as one would hide that prose behind
    /// a picture's reserved height.
    @Test("An embed sharing its line with words stays inline")
    func leavesInlineEmbedsAlone() throws {
        try withPictureVault { _, context in
            guard case .list? = firstBlock("- see ![[shot.png]] here\n", context) else {
                Issue.record("a sentence containing an embed lost its bullet")
                return
            }
        }
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
