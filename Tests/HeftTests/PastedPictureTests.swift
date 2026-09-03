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
            guard case .image(let image, _, let lead)? =
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
            guard case .image(_, _, let ordered)? = firstBlock("1. ![[shot.png]]\n", context),
                  case .ordered(let label)? = ordered.bullet?.glyph
            else {
                Issue.record("an ordered item lost its numeral")
                return
            }
            #expect(label == "1.")

            guard case .image(_, _, let task)? = firstBlock("- [x] ![[shot.png]]\n", context),
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
            guard case .image(_, _, let top)? = firstBlock("- ![[shot.png]]\n", context),
                  case .image(_, _, let deeper)? = firstBlock("\t- ![[shot.png]]\n", context)
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
            guard case .image(_, _, let lead)? = firstBlock("- ![](shot.png)\n", context) else {
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
            guard case .image(_, _, let lead)? = firstBlock(">  ![[shot.png]]\n", context) else {
                Issue.record("a quoted embed produced no picture")
                return
            }
            #expect(lead.quote?.line.depth == 1)
            #expect(lead.indent > 0)

            guard case .image(_, _, let nested)? = firstBlock("> - ![[shot.png]]\n", context) else {
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
            guard case .image(_, _, let lead)? =
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

/// A cell is drawn as attributed text rather than as a layout fragment, so the
/// widget pass that draws pictures everywhere else is switched off for it. An
/// embed in a table therefore came out as its filename in blue — which is what
/// a meeting note full of screenshots in a table looks like.
@Suite("Pictures in table cells")
@MainActor
struct TableCellPictureTests {

    private func withPictureVault(_ body: (RenderContext) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-cell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, _ size: NSSize) throws {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            try NSBitmapImageRep(data: image.tiffRepresentation!)!
                .representation(using: .png, properties: [:])!
                .write(to: root.appendingPathComponent(name))
        }
        try write("shot.png", NSSize(width: 400, height: 300))
        // Smaller than any column it is measured against, which is the only
        // case where growing into the column differs from shrinking to fit it.
        try write("icon.png", NSSize(width: 40, height: 30))

        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        try body(RenderContext(index: index, current: nil, vaultRoot: root))
    }

    /// The attachments in a rendered cell, with the size each is drawn at.
    private func attachments(
        _ source: String, _ context: RenderContext,
        revealed: Bool = false, width: CGFloat? = nil
    ) -> [CGSize] {
        let rendered = CellText.render(
            source, bold: false, fontSize: 13, context: context,
            revealed: revealed, pictureWidth: width
        )
        var sizes: [CGSize] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, attachment.image != nil else { return }
            sizes.append(attachment.bounds.size)
        }
        return sizes
    }

    @Test("Both spellings of an embed draw in a cell")
    func cellsDrawPictures() throws {
        try withPictureVault { context in
            #expect(attachments("![[shot.png]]", context).count == 1)
            #expect(attachments("![](shot.png)", context).count == 1)
            #expect(attachments("no picture here", context).isEmpty)
            // A note is not a picture, and a missing file is not one either.
            #expect(attachments("![[nowhere.png]]", context).isEmpty)
        }
    }

    /// Obsidian fits a picture to its column, and one left at thumbnail size in
    /// a column three times as wide reads as broken beside the same table there.
    @Test("A picture fills the column it is measured against")
    func picturesFillTheirColumn() throws {
        try withPictureVault { context in
            let narrow = try #require(attachments("![[shot.png]]", context, width: 100).first)
            let wide = try #require(attachments("![[shot.png]]", context, width: 300).first)
            #expect(narrow.width == 100)
            #expect(wide.width == 300)
            // Fitted, not squashed: 400x300 keeps its shape at either width.
            #expect(abs(wide.width / wide.height - 4.0 / 3.0) < 0.05, "got \(wide)")

            // A picture smaller than its column grows into it. Shrinking alone
            // cannot tell the two apart, which is why this one is here.
            let small = try #require(attachments("![[icon.png]]", context, width: 300).first)
            #expect(small.width == 300, "a small picture should fill its column, got \(small)")
        }
    }

    /// `![[shot.png|500]]` is the reader saying how big, and it outranks the
    /// column: it was ignored everywhere until now.
    @Test("A size written into the link wins")
    func linkSizeWins() throws {
        try withPictureVault { context in
            let asked = try #require(
                attachments("![[shot.png|80]]", context, width: 300).first
            )
            #expect(asked.width == 80)
            let both = try #require(
                attachments("![[shot.png|60x20]]", context, width: 300).first
            )
            #expect(both == CGSize(width: 60, height: 20))
            // Still never wider than the room it has.
            let clamped = try #require(
                attachments("![[shot.png|900]]", context, width: 200).first
            )
            #expect(clamped.width == 200)
        }
    }

    /// The cell the caret is in shows the file's own characters, so an offset
    /// into it means the same thing as an offset into the document — which is
    /// what the caret inside a table is placed from. A picture there would
    /// stand where several characters do.
    @Test("The cell being edited shows its source, not a picture")
    func revealedCellKeepsItsSource() throws {
        try withPictureVault { context in
            #expect(attachments("![[shot.png]]", context, revealed: true).isEmpty)
        }
    }

    /// A size written into a cell is that cell asking its column for room.
    /// Measured at a nominal width instead, two cells asking for 500 were sized
    /// by the words above them and the pictures then filled those narrow
    /// columns — which is what made a table of charts here a third the size of
    /// the same table in Obsidian.
    @Test("A size written in a cell widens its column")
    func requestedSizeWidensTheColumn() throws {
        try withPictureVault { context in
            func columns(_ cells: String) -> [CGFloat] {
                let source = [
                    "| Recurrence | Survival |", "| --- | --- |", cells, "",
                ].joined(separator: "\n")
                let storage = NSTextStorage(string: source)
                let layout = LiveStyler.apply(
                    to: storage, reveal: .none, context: context, contentWidth: 700
                )
                guard case .table(let grid)? = layout.blocks[0] else { return [] }
                return grid.columnWidths
            }

            let asked = columns("| ![[shot.png\\|500]] | ![[shot.png\\|500]] |")
            let plain = columns("| words | words |")
            #expect(asked.count == 2 && plain.count == 2)
            #expect(
                asked[0] > plain[0],
                "a cell asking for 500 should want more room than a word: \(asked) vs \(plain)"
            )

            // Two cells asking for the same thing get the same room. Obsidian
            // gets this wrong — the column further right comes out smaller
            // until the numbers are made to differ — and it is worth not
            // copying.
            #expect(asked[0] == asked[1], "columns asking for the same size differ: \(asked)")

            // And asking for more gets more. Both numbers are above the width
            // a picture is measured at before its column is known, or clamping
            // to that would order them correctly for the wrong reason.
            let uneven = columns("| ![[shot.png\\|500]] | ![[shot.png\\|300]] |")
            #expect(uneven[0] > uneven[1], "got \(uneven)")
        }
    }

    /// The table a caret is in must be exactly the size it was before, or the
    /// row clicked on moves out from under the pointer and takes the rest of
    /// the note with it. Measured at 148pt against 96pt for a table holding one
    /// picture: half the table's height, on a click.
    @Test("Clicking into a table does not change its size")
    func caretDoesNotResizeTheTable() throws {
        try withPictureVault { context in
            let source = [
                "| what | picture | notes |",
                "| --- | --- | --- |",
                "| one | ![[shot.png]] | a longer piece of text in this cell |",
                "| two | plain | more |",
                "",
            ].joined(separator: "\n")
            let text = source as NSString

            /// The grid the surface would draw with the caret at `caret`.
            func grid(caret: Int?) -> TableGrid? {
                let storage = NSTextStorage(string: source)
                let layout = LiveStyler.apply(
                    to: storage,
                    reveal: caret.map {
                        Reveal(selection: NSRange(location: $0, length: 0), in: text)
                    } ?? .none,
                    context: context,
                    contentWidth: 600
                )
                guard case .table(let grid)? = layout.blocks[0] else { return nil }
                return grid
            }

            let resting = try #require(grid(caret: nil), "no table was drawn")
            #expect(resting.size.height > 0)

            for cell in ["![[shot.png]]", "| one |", "plain", "a longer piece"] {
                let caret = text.range(of: cell).location + 1
                let clicked = try #require(grid(caret: caret), "no table with the caret in \(cell)")
                #expect(
                    clicked.size == resting.size,
                    "clicking \(cell) resized the table: \(resting.size) -> \(clicked.size)"
                )
            }
        }
    }
}


/// A literal pipe inside a table has to be written `\\|`, or it reads as the end
/// of the cell. Typing one into `![[shot.png|500]]` split the row and left `]]`
/// in the cell after it, taking the table's shape with it.
@Suite("Typing a pipe inside a table")
@MainActor
struct TablePipeEscapeTests {

    /// A real view, laid out, with the caret at `caret`.
    private func view(_ document: String, caret: Int) -> HeftTextKit2View {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "p.md", generation: 0,
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
        view.string = document
        view.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.restyle(view)
        return view
    }

    @Test("A pipe typed in a cell is escaped, so the row keeps its shape")
    func pipeIsEscapedInATable() {
        let document = "| a | b |\n| --- | --- |\n| ![[shot.png]] | x |\n"
        let caret = (document as NSString).range(of: "shot.png").upperBound
        let editor = view(document, caret: caret)
        #expect(editor.activeTable != nil, "the caret has to be in the table for this to apply")

        editor.insertText("|", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string.contains("![[shot.png\\|]]"))
        // Still one row of two cells, not two rows of rubble.
        #expect(editor.string.components(separatedBy: "\n")[2].contains("| x |"))
    }

    /// Outside a table a pipe is an ordinary character, and escaping it there
    /// would put a backslash into prose that nobody asked for.
    @Test("A pipe typed in prose is left alone")
    func pipeIsLiteralOutsideATable() {
        let editor = view("just prose here\n", caret: 4)
        #expect(editor.activeTable == nil)
        editor.insertText("|", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string.hasPrefix("just| prose"))
    }
}
