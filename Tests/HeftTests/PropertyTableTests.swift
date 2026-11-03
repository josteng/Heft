import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// The frontmatter drawn in place as a properties table: one row a line, the
/// markup hidden off the caret's line, keys and values completed from the
/// vault.
@Suite("Property table")
struct PropertyTableTests {

    private let note = """
    ---
    Author: Jane Doe
    tags:
      - reading
    Rating: [3, 4]
    # a comment
    Categ
    ---
    Body
    """

    private func lines(_ source: String) -> [PropertyLine] {
        LiveDecorator.decorations(in: source).compactMap {
            if case .propertyLine(let line) = $0.style { return line }
            return nil
        }
    }

    @Test("Each line is a row: fences, entries, items, a key still being typed, anything else")
    func rows() {
        let rows = lines(note)
        #expect(rows.count == 8)
        #expect(rows.first?.kind == .fence && rows.last?.kind == .fence)
        #expect(rows[1].kind == .entry(
            key: NSRange(location: 0, length: 6), colon: NSRange(location: 6, length: 2),
            value: NSRange(location: 8, length: 8)
        ))
        #expect(rows[3].kind == .item(marker: NSRange(location: 0, length: 4), value: NSRange(location: 4, length: 7)))
        #expect(rows[3].key == "tags" && rows[3].isTags)
        #expect(rows[5].kind == .other)
        #expect(rows[6].kind == .entry(
            key: NSRange(location: 0, length: 5), colon: NSRange(location: 5, length: 0),
            value: NSRange(location: 5, length: 0)
        ))
        #expect(rows.map(\.edge) == [nil, .first, .middle, .middle, .middle, .middle, .last, nil])
        #expect(Set(rows.map(\.widestKey)) == ["Author"])
    }

    @Test("What a row hides: the fences whole, a colon, a dash, an inline list's brackets")
    func hidden() {
        let decorations = LiveDecorator.decorations(in: note).filter {
            if case .propertyLine = $0.style { return true }
            return false
        }
        let text = note as NSString
        let hidden = decorations.map { $0.syntax.map(text.substring(with:)) }
        #expect(hidden[0] == ["---"])
        #expect(hidden[1] == [": "])
        #expect(hidden[3] == ["  - "])
        #expect(hidden[4] == [": ", "[", "]"])
        #expect(hidden[5].isEmpty)
    }

    @Test("A blank row still covers its line, or no restyle would ever reach it")
    func blankRow() {
        let source = "---\na: 1\n\n---\n"
        let blank = LiveDecorator.decorations(in: source).first {
            if case .propertyLine(let line) = $0.style { return line.kind == .other }
            return false
        }
        #expect(blank?.range == NSRange(location: 9, length: 1))
    }

    @Test("A list belongs to its key: its items folded onto the key's row, opened together")
    func lists() {
        let source = "---\nA: 1\ntags:\n  - x\n  - y\nB: [p, \"q\"]\n---\n"
        let decorations = LiveDecorator.decorations(in: source).filter {
            if case .propertyLine = $0.style { return true }
            return false
        }
        let rows = decorations.compactMap { decoration -> PropertyLine? in
            if case .propertyLine(let line) = decoration.style { return line }
            return nil
        }
        #expect(rows[2].items == ["x", "y"])
        #expect(rows[3].folds && rows[4].folds && !rows[2].folds)
        #expect(rows[5].items == ["p", "q"])
        #expect(rows[2].foldedEdge == .middle)
        // The caret on any of the list's lines opens all of them.
        let onItem = Reveal(selection: NSRange(location: 22, length: 0), in: source as NSString)
        #expect(decorations[2...4].allSatisfy { onItem.state(of: $0) == .revealed })
        #expect(onItem.state(of: decorations[1]) == .hidden)
        #expect(decorations[1].revealRange == nil)
    }

    private func styled(_ source: String, caret: Int? = nil, asText: Bool = false) -> (NSTextStorage, LiveLayout) {
        let storage = NSTextStorage(string: source)
        let reveal = caret.map { Reveal(selection: NSRange(location: $0, length: 0), in: source as NSString) } ?? .none
        var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        context.propertiesAsText = asText
        let layout = LiveStyler.apply(to: storage, reveal: reveal, context: context, contentWidth: 600)
        return (storage, layout)
    }

    @Test("Folded, a list's items are chips on its key's row and its lines take no room")
    func folded() throws {
        let source = "---\ntags:\n  - x\n  - y\n---\nBody"
        let (storage, layout) = styled(source)
        guard case .propertyRow(let row)? = layout.blocks[4] else {
            Issue.record("no row for the key")
            return
        }
        #expect(row.edge == .only)
        #expect(row.chips?.labels.map(\.string) == ["x", "y"])
        #expect(layout.blocks[10] == nil)
        let item = try #require(storage.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle)
        #expect(item.maximumLineHeight < 1)

        // Edited, it stays pills, each with its ×, the lines still folded.
        let (open, openLayout) = styled(source, caret: 9)
        guard case .propertyRow(let openRow)? = openLayout.blocks[4] else {
            Issue.record("no row for the key")
            return
        }
        #expect(openRow.chips?.removable == true && openRow.focus == .only)
        #expect(row.chips?.removable == false)
        let folded = try #require(open.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle)
        #expect(folded.maximumLineHeight < 1)
    }

    @Test("As text, the frontmatter is the YAML: nothing hidden, no table drawn")
    func asText() throws {
        let source = "---\nAuthor: Jane\n---\nBody"
        let (storage, layout) = styled(source, asText: true)
        let colon = try #require(storage.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        #expect(colon.pointSize > 1)
        let fence = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(fence.pointSize > 1)
        #expect(layout.blocks[4] == nil)
    }

    @Test("The card's last row keeps room under it for Add property")
    func footRoom() throws {
        let (storage, _) = styled("---\na: 1\nb: 2\n---\nBody")
        let last = try #require(storage.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)
        let first = try #require(storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)
        #expect(last.paragraphSpacing > first.paragraphSpacing + PropertyChips.addRowHeight - 1)
    }

    @Test("A row hides its colon, on the caret's line too, and keeps its value in the column")
    func styledRow() throws {
        let source = "---\nAuthor: Jane\n---\nBody"
        let colon = 10
        let (away, layout) = styled(source)
        let font = try #require(away.attribute(.font, at: colon, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize < 1)
        guard case .propertyRow(let row)? = layout.blocks[4] else {
            Issue.record("no row drawn for the property")
            return
        }
        #expect(row.edge == .only && row.focus == nil && row.symbol == "text.alignleft")
        #expect((away.attribute(.kern, at: 9, effectiveRange: nil) as? CGFloat ?? 0) > 0)

        let (on, onLayout) = styled(source, caret: 14)
        let hidden = try #require(on.attribute(.font, at: colon, effectiveRange: nil) as? NSFont)
        #expect(hidden.pointSize < 1)
        #expect((on.attribute(.kern, at: 9, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        guard case .propertyRow(let edited)? = onLayout.blocks[4] else {
            Issue.record("no row drawn for the edited property")
            return
        }
        #expect(edited.focus == .only && !edited.showsEmpty)

        // The opening fence is the heading, the closing one takes no room.
        guard case .propertyHeading? = layout.blocks[0] else {
            Issue.record("no heading")
            return
        }
        let closing = try #require(away.attribute(.paragraphStyle, at: 17, effectiveRange: nil) as? NSParagraphStyle)
        #expect(closing.maximumLineHeight < 1)
    }

    @Test("The icon is the type the vault's types file gives the key, before any guess")
    func iconFromTypes() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("heft-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        try PropertyTypes.set(.date, for: "Read", in: vault)
        let storage = NSTextStorage(string: "---\nRead: soon\nOther: soon\n---\n")
        let layout = LiveStyler.apply(
            to: storage, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: vault), contentWidth: 600
        )
        guard case .propertyRow(let typed)? = layout.blocks[4], case .propertyRow(let guessed)? = layout.blocks[15] else {
            Issue.record("no rows")
            return
        }
        #expect(typed.symbol == "calendar")
        #expect(guessed.symbol == "text.alignleft")
    }

    @Test("An edited row with no value says Empty; a blank row is where a key goes")
    func empty() {
        let source = "---\nA: 1\nB:\n\n---\n"
        func row(_ layout: LiveLayout, _ start: Int) -> PropertyRow? {
            if case .propertyRow(let row)? = layout.blocks[start] { return row }
            return nil
        }
        #expect(row(styled(source, caret: 11).1, 9)?.showsEmpty == true)
        #expect(row(styled(source, caret: 9).1, 9)?.showsEmpty == true)
        #expect(row(styled(source, caret: 5).1, 4)?.showsEmpty == false)
        let blank = row(styled(source, caret: 12).1, 12)
        #expect(blank?.showsEmpty == true && blank?.symbol == "text.alignleft" && blank?.focus == .only)
        #expect(row(styled(source).1, 9)?.showsEmpty == false)
    }

    @Test("A note opens past its frontmatter, so the table shows rather than the fence")
    func openingCaret() {
        #expect(PropertyEditing.openingCaret(in: "---\na: 1\n---\nBody") == 13)
        #expect(PropertyEditing.openingCaret(in: "Body") == 0)
    }

    // MARK: Completion

    private func detect(_ source: String, caret: Int? = nil) -> PropertyCompletionContext? {
        PropertyCompletionContext.detect(
            in: source, selection: NSRange(location: caret ?? (source as NSString).length, length: 0)
        )
    }

    @Test("A key at the start of a frontmatter line, a value after its colon or on a list item")
    func detects() {
        #expect(detect("---\nAu\n---\n", caret: 6)?.part == .key)
        #expect(detect("---\nAu\n---\n", caret: 6)?.query == "Au")
        let value = detect("---\nCategory: Fi\n---\n", caret: 16)
        #expect(value?.part == .value(key: "Category", siblings: []))
        #expect(value?.query == "Fi")
        #expect(value?.queryRange == NSRange(location: 14, length: 2))
        let item = detect("---\ntags:\n  - one\n  - t\n---\n", caret: 23)
        #expect(item?.part == .value(key: "tags", siblings: ["one"]))
        #expect(item?.query == "t")
        let inline = detect("---\ntags: [one, tw\n---\n", caret: 18)
        #expect(inline?.part == .value(key: "tags", siblings: ["one"]))
        #expect(inline?.query == "tw")
    }

    @Test("Nothing outside the fences, with text after the caret, on a fence, or in a comment")
    func refuses() {
        #expect(detect("Au") == nil)
        #expect(detect("---\na: 1\n---\nAu") == nil)
        #expect(detect("---\nAuthor\n---\n", caret: 6) == nil)
        #expect(detect("---\na: 1\n---\n", caret: 3) == nil)
        #expect(detect("---\n# no\n---\n", caret: 8) == nil)
        #expect(detect("---\nfirst second\n---\n", caret: 16) == nil)
    }

    @Test("Offers keys the note lacks and values the list lacks; accepting writes YAML")
    func accepts() {
        let catalog = PropertyCatalog(properties: [
            [NoteProperty(key: "Author", value: .text("Jane")), NoteProperty(key: "Publisher", value: .text("North Press"))],
            [NoteProperty(key: "Publisher", value: .text("[[Some Press]]"))],
        ])
        let source = "---\nAuthor: x\nPu\n---\n"
        let key = detect(source, caret: 16)
        #expect(key?.suggestions(from: catalog, in: source) == ["Publisher"])
        // The note's own key is not offered again.
        #expect(detect("---\nAuthor: x\nAu\n---\n", caret: 16)?.suggestions(from: catalog, in: "---\nAuthor: x\nAu\n---\n") == [])
        let written = key.map { (source as NSString).replacingCharacters(in: $0.accepting("Publisher").range, with: $0.accepting("Publisher").replacement) }
        #expect(written == "---\nAuthor: x\nPublisher: \n---\n")
        let value = detect("---\nPublisher: \n---\n", caret: 15)
        #expect(value?.suggestions(from: catalog, in: "") == ["[[Some Press]]", "North Press"])
        #expect(value?.accepting("[[Some Press]]").replacement == "\"[[Some Press]]\"")
    }
}

/// Tab and Add property move through the table as Obsidian's do.
@MainActor
@Suite("Property table keys")
struct PropertyTableKeyTests {
    private func view(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("Tab after a key being typed writes its colon and goes to the value")
    func tabToValue() {
        let typing = view("---\nA: 1\nPub\n---\n", caret: 12)
        typing.insertTab(nil)
        #expect(typing.string == "---\nA: 1\nPub: \n---\n")
        #expect(typing.selectedRange() == NSRange(location: 14, length: 0))
        // Anywhere else Tab is Tab.
        let value = view("---\nA: 1\n---\n", caret: 8)
        #expect(!value.moveToPropertyValue())
    }

    @Test("In Vim, Add property starts in Insert mode, as o does, so the key typed goes in")
    func addPropertyInVim() {
        let vim = view("---\nA: 1\n---\nBody", caret: 16)
        vim.vimEnabled = true
        vim.resetVim()
        #expect(vim.vimMode != .insert)
        vim.editProperties()
        #expect(vim.vimMode == .insert)
    }

    @Test("Add property makes a row at the end, or the block when there is none")
    func addProperty() {
        let existing = view("---\nA: 1\n---\nBody", caret: 16)
        existing.editProperties()
        #expect(existing.string == "---\nA: 1\n\n---\nBody")
        #expect(existing.selectedRange() == NSRange(location: 9, length: 0))
        let none = view("Body", caret: 2)
        none.editProperties()
        #expect(none.string == "---\n\n---\nBody")
        #expect(none.selectedRange() == NSRange(location: 4, length: 0))
    }
}

/// ↑, ↓ and ⌘⌫ treat a property as one thing, its list included.
@MainActor
@Suite("Property rows")
struct PropertyRowTests {
    private let note = "---\nA: 1\ntags:\n  - x\n  - y\nB: 2\n---\nBody"

    private func view(caret: Int, text: String? = nil) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text ?? note
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("A row is a key line and the list under it")
    func rows() {
        let rows = PropertyEditing.rows(in: note)
        let text = note as NSString
        #expect(rows.map { text.substring(with: $0.range) } == ["A: 1\n", "tags:\n  - x\n  - y\n", "B: 2\n"])
        #expect(rows.map(\.valueEnd) == [8, 14, 31])
        #expect(PropertyEditing.rows(in: "Body").isEmpty)
    }

    @Test("Down goes a property at a time, past a list, and out at the foot; up comes back in")
    func arrows() {
        let moving = view(caret: 6)
        moving.moveDown(nil)
        #expect(moving.selectedRange().location == 14)
        moving.moveDown(nil)
        #expect(moving.selectedRange().location == 31)
        moving.moveDown(nil)
        #expect(moving.selectedRange().location == 36)
        moving.moveUp(nil)
        #expect(moving.selectedRange().location == 31)
        moving.moveUp(nil)
        #expect(moving.selectedRange().location == 14)
        // In the body, arrows are the text's own.
        let body = view(caret: 37)
        #expect(!body.movePropertyRow(down: true))
    }

    @Test("⌘⌫ deletes the property under the caret, list and all; the last one takes the fences")
    func delete() {
        let list = view(caret: 20)
        list.deleteToBeginningOfLine(nil)
        #expect(list.string == "---\nA: 1\nB: 2\n---\nBody")
        #expect(list.selectedRange().location == 13)
        let last = view(caret: 6, text: "---\nA: 1\n---\nBody")
        last.deleteToBeginningOfLine(nil)
        #expect(last.string == "Body")
        // In the body it is AppKit's own, and the properties are left alone.
        let body = view(caret: 40)
        body.deleteToBeginningOfLine(nil)
        #expect(body.string.hasPrefix("---\nA: 1\ntags:\n  - x\n  - y\nB: 2\n---\n"))
    }
}

/// A list is edited on its key line, as its pills.
@MainActor
@Suite("Property list keys")
struct PropertyListKeyTests {
    private func view(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("Return makes what was typed an item; with nothing typed, a new property under the list")
    func returnKey() {
        let typed = view("---\ntags:fan\n  - x\n---\n", caret: 12)
        typed.insertNewline(nil)
        #expect(typed.string == "---\ntags:\n  - x\n  - fan\n---\n")
        #expect(typed.selectedRange().location == 9)
        typed.insertNewline(nil)
        #expect(typed.string == "---\ntags:\n  - x\n  - fan\n\n---\n")
        #expect(typed.selectedRange().location == 24)
    }

    @Test("Backspace with nothing typed takes the last item; with text typed it deletes a letter")
    func backspace() {
        let empty = view("---\ntags:\n  - x\n  - y\n---\n", caret: 9)
        empty.deleteBackward(nil)
        #expect(empty.string == "---\ntags:\n  - x\n---\n")
        let typed = view("---\ntags:ab\n  - x\n---\n", caret: 11)
        typed.deleteBackward(nil)
        #expect(typed.string == "---\ntags:a\n  - x\n---\n")
    }

    @Test("Leaving the key line with something typed makes it the last item")
    func leaving() async throws {
        let typed = view("---\ntags:fan\n  - x\nA: 1\n---\n", caret: 12)
        typed.noteListEditing()
        typed.setSelectedRange(NSRange(location: 21, length: 0))
        typed.noteListEditing()
        try await Task.sleep(for: .milliseconds(50))
        #expect(typed.string == "---\ntags:\n  - x\n  - fan\nA: 1\n---\n")
        #expect(typed.selectedRange().location == 26)
    }

    @Test("A caret on a folded item's hidden line goes to the list's key line")
    func lift() {
        let stray = view("---\ntags:\n  - x\n---\n", caret: 13)
        #expect(stray.liftCaretOffFoldedItem())
        #expect(stray.selectedRange().location == 9)
        #expect(!stray.liftCaretOffFoldedItem())
    }
}
