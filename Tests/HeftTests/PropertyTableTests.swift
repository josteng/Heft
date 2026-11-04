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
        // The colon is the styler's to hide, with the column's gap on it.
        #expect(hidden[1].isEmpty)
        #expect(hidden[3] == ["  - "])
        #expect(hidden[4] == ["[", "]"])
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
        #expect(decorations[2...4].allSatisfy { onItem.reveals($0) })
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
        // Every pill carries its ×, edited or not, as Obsidian's do.
        #expect(row.chips?.removable == true)
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
        // The gap is on the colon itself: a caret after the key stays at the
        // key, and the value's first letter follows an unkerned space.
        #expect((away.attribute(.kern, at: 10, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        #expect((away.attribute(.kern, at: 9, effectiveRange: nil) as? CGFloat ?? 0) == 0)
        #expect((away.attribute(.kern, at: 11, effectiveRange: nil) as? CGFloat ?? 0) == 0)

        let (on, onLayout) = styled(source, caret: 14)
        let hidden = try #require(on.attribute(.font, at: colon, effectiveRange: nil) as? NSFont)
        #expect(hidden.pointSize < 1)
        #expect((on.attribute(.kern, at: 10, effectiveRange: nil) as? CGFloat ?? 0) > 0)
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

    @Test("A key written twice is marked on both rows, red with a warning, as Obsidian then reads nothing")
    func duplicateKeys() throws {
        let source = "---\nMamba:\nMamba: asf\nOther: 1\n---\n"
        let rows = lines(source)
        #expect(rows.map(\.isDuplicate) == [false, true, true, false, false])
        let (storage, layout) = styled(source)
        guard case .propertyRow(let first)? = layout.blocks[4], case .propertyRow(let other)? = layout.blocks[22] else {
            Issue.record("no rows")
            return
        }
        #expect(first.warns && !other.warns)
        #expect(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == .systemRed)
    }

    @Test("A selection over several rows outlines none of them")
    func selectionOutlinesNone() {
        let source = "---\nA: 1\nB: 2\n---\n"
        let storage = NSTextStorage(string: source)
        let layout = LiveStyler.apply(
            to: storage, reveal: Reveal(selection: NSRange(location: 5, length: 6), in: source as NSString),
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil), contentWidth: 600
        )
        for start in [4, 9] {
            guard case .propertyRow(let row)? = layout.blocks[start] else {
                Issue.record("no row at \(start)")
                continue
            }
            #expect(row.focus == nil)
        }
    }

    @Test("Tag pills are in the tag colour, other lists' in the text's")
    func tagColour() {
        let (_, layout) = styled("---\ntags: [a]\nlist: [b]\n---\n")
        guard case .propertyRow(let tags)? = layout.blocks[4], case .propertyRow(let list)? = layout.blocks[14] else {
            Issue.record("no rows")
            return
        }
        let tagInk = tags.chips?.labels.first?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let listInk = list.chips?.labels.first?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(tagInk == RenderContext(index: .empty, current: nil, vaultRoot: nil).tagColor)
        #expect(listInk == NSColor.labelColor)
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

    @Test("A blank row the caret leaves is removed; the last one takes the fences")
    func blankRowLeft() async throws {
        let rows = view("---\nA: 1\n\n---\nBody", caret: 9)
        rows.noteListEditing()
        rows.setSelectedRange(NSRange(location: 16, length: 0))
        rows.noteListEditing()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rows.string == "---\nA: 1\n---\nBody")
        #expect(rows.selectedRange().location == 15)
        let only = view("---\n\n---\nBody", caret: 4)
        only.noteListEditing()
        only.setSelectedRange(NSRange(location: 11, length: 0))
        only.noteListEditing()
        try await Task.sleep(for: .milliseconds(50))
        #expect(only.string == "Body")
    }

    @Test("A caret on a folded item's hidden line goes to the list's key line")
    func lift() {
        let stray = view("---\ntags:\n  - x\n---\n", caret: 13)
        #expect(stray.liftCaretOffFoldedItem())
        #expect(stray.selectedRange().location == 9)
        #expect(!stray.liftCaretOffFoldedItem())
    }
}

/// The caret never stands in the hidden `: ` between a key and its value.
@MainActor
@Suite("Property caret")
struct PropertyCaretTests {
    private func view(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.lastCaretLocation = caret
        return view
    }

    private let note = "---\nRating: 4\n---\n"

    @Test("The gap is the colon and its spaces")
    func gap() {
        let gap = PropertyEditing.colonGap(in: note, at: 8)
        #expect(gap?.keyEnd == 10 && gap?.valueStart == 12)
        #expect(PropertyEditing.colonGap(in: "Body: x", at: 2) == nil)
    }

    @Test("Coming from the key it goes on to the value; from the value, back to the key's end")
    func insertMode() {
        let right = view(note, caret: 10)
        right.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(right.keepCaretOutOfColonGap())
        #expect(right.selectedRange().location == 12)
        let left = view(note, caret: 12)
        left.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(left.keepCaretOutOfColonGap())
        #expect(left.selectedRange().location == 10)
        // After the key and at the value are both fine.
        #expect(!view(note, caret: 10).keepCaretOutOfColonGap())
        #expect(!view(note, caret: 12).keepCaretOutOfColonGap())
    }

    @Test("In Normal mode the colon itself is the gap, and an empty value has no place to stand")
    func normalMode() {
        let normal = view(note, caret: 9)
        normal.vimEnabled = true
        normal.resetVim()
        normal.setSelectedRange(NSRange(location: 9, length: 0))
        normal.lastCaretLocation = 9
        normal.setSelectedRange(NSRange(location: 10, length: 0))
        #expect(normal.keepCaretOutOfColonGap())
        #expect(normal.selectedRange().location == 12)
        // An empty value's place is the last hidden character before it.
        let empty = view("---\nRating:\n---\n", caret: 9)
        empty.vimEnabled = true
        empty.resetVim()
        empty.setSelectedRange(NSRange(location: 10, length: 0))
        empty.lastCaretLocation = 9
        #expect(!empty.keepCaretOutOfColonGap())
        #expect(empty.selectedRange().location == 10)
    }

    @Test("Typing in the gap goes into the value, with the space YAML needs")
    func typingInTheGap() {
        let bare = view("---\nRating:\n---\n", caret: 11)
        bare.insertText("5", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bare.string == "---\nRating: 5\n---\n")
        #expect(bare.selectedRange().location == 13)
        let between = view(note, caret: 11)
        between.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(between.string == "---\nRating: x4\n---\n")
        // At the value's start, typing is ordinary.
        let atValue = view(note, caret: 12)
        atValue.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(atValue.string == "---\nRating: x4\n---\n")
    }

    @Test("Deleting never eats the gap, so a value cannot run into its key")
    func deletingTheGap() {
        let back = view(note, caret: 12)
        back.deleteBackward(nil)
        #expect(back.string == note)
        let forward = view(note, caret: 10)
        forward.deleteForward(nil)
        #expect(forward.string == note)
        let inValue = view(note, caret: 13)
        inValue.deleteBackward(nil)
        #expect(inValue.string == "---\nRating: \n---\n")
    }

    @Test("Add property opens the vault's keys at once, as Obsidian's does")
    func addPropertyOpensKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nPublisher: North Press\nRating: 4\n---\n".write(
            to: root.appendingPathComponent("Book.md"), atomically: true, encoding: .utf8
        )
        let editor = view("---\nRating: 1\n---\nBody", caret: 20)
        editor.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        editor.editProperties()
        #expect(editor.visibleCompletions == ["Publisher"])
    }
}

/// Where a click on a property row leaves the caret once the click is over.
@MainActor
@Suite("Property clicks")
struct PropertyClickTests {
    private let note = "---\nAuthor: Jane\nEmpty:\ntags:\n  - x\naliases: [A, B]\n---\n"

    private func view(caret: Int, vim: Bool = false) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = note
        if vim {
            view.vimEnabled = true
            view.resetVim()
        }
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("In the key column a click stops at the key's end; in a value it stays where it landed")
    func keyAndValue() {
        let key = view(caret: 11)
        key.settlePropertyClick(onLineAt: 4, inValue: false)
        #expect(key.selectedRange().location == 10)
        let value = view(caret: 14)
        value.settlePropertyClick(onLineAt: 4, inValue: true)
        #expect(value.selectedRange().location == 14)
        let gap = view(caret: 11)
        gap.settlePropertyClick(onLineAt: 4, inValue: true)
        #expect(gap.selectedRange().location == 12)
    }

    @Test("An empty value is given its space and the caret after it, in Vim on it")
    func emptyValue() {
        let insert = view(caret: 21)
        insert.settlePropertyClick(onLineAt: 17, inValue: true)
        #expect(insert.string.contains("Empty: \n"))
        #expect(insert.selectedRange().location == 24)
        let normal = view(caret: 21, vim: true)
        normal.settlePropertyClick(onLineAt: 17, inValue: true)
        #expect(normal.selectedRange().location == 23)
    }

    @Test("A list takes the caret after its pills; an inline list becomes a block list first")
    func lists() {
        let tags = view(caret: 30)
        tags.settlePropertyClick(onLineAt: 24, inValue: true)
        #expect(tags.string.contains("tags: \n  - x\n"))
        #expect(tags.selectedRange().location == 30)
        let aliases = view(caret: 46)
        aliases.settlePropertyClick(onLineAt: 36, inValue: true)
        #expect(aliases.string == "---\nAuthor: Jane\nEmpty:\ntags:\n  - x\naliases: \n  - A\n  - B\n---\n")
        #expect(aliases.selectedRange().location == 45)
    }
}
