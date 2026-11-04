import Foundation
import HeftCore
import Testing

/// What the properties table decides from the text alone, which the Mac and
/// iOS editors both carry out. The Mac's real-click tests cover the same
/// paths through a view; these pin the decisions themselves.
@Suite("Property surface")
struct PropertySurfaceTests {
    /// `---` at 0, `title: Hello` at 4, `tags:` at 17 with items at 23 and
    /// 31, `---` at 39, body at 43.
    let note = "---\ntitle: Hello\ntags:\n  - one\n  - two\n---\nBody\n"

    private func applying(_ edit: MarkdownEditing.Edit, to source: String) -> String {
        (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("A caret on a fence goes to the first row, the last row or past the block")
    func fences() {
        #expect(PropertySurface.caretOffFences(in: note, caret: 0, previous: nil, normal: false) == 4)
        // The closing fence from below: the last row's value end.
        #expect(PropertySurface.caretOffFences(in: note, caret: 39, previous: 44, normal: false) == 22)
        // From above: past the block.
        #expect(PropertySurface.caretOffFences(in: note, caret: 39, previous: 30, normal: false) == 43)
        #expect(PropertySurface.caretOffFences(in: note, caret: 8, previous: nil, normal: false) == nil)
    }

    @Test("The hidden colon gap sends the caret on the way it came, or to the tapped column")
    func colonGap() {
        // `title: Hello`: the colon at 9, the value at 11.
        #expect(PropertySurface.caretOutOfColonGap(in: note, caret: 10, previous: 9, clicked: nil, leavingInsert: false, normal: false) == 11)
        #expect(PropertySurface.caretOutOfColonGap(in: note, caret: 10, previous: 11, clicked: nil, leavingInsert: false, normal: false) == 9)
        #expect(PropertySurface.caretOutOfColonGap(in: note, caret: 10, previous: 11, clicked: (4, true), leavingInsert: false, normal: false) == 11)
        #expect(PropertySurface.caretOutOfColonGap(in: note, caret: 12, previous: 9, clicked: nil, leavingInsert: false, normal: false) == nil)
    }

    @Test("A caret on a list's hidden item line goes to its key line's end")
    func foldedItem() {
        #expect(PropertySurface.caretOffFoldedItem(in: note, caret: 27) == 22)
        #expect(PropertySurface.caretOffFoldedItem(in: note, caret: 8) == nil)
    }

    @Test("Up and down move a property at a time, out of the table and back in")
    func rowMoves() {
        #expect(PropertySurface.rowMove(in: note, caret: 8, down: true) == 22)
        #expect(PropertySurface.rowMove(in: note, caret: 22, down: true) == 43)
        #expect(PropertySurface.rowMove(in: note, caret: 22, down: false) == 16)
        #expect(PropertySurface.rowMove(in: note, caret: 8, down: false) == 8)
        #expect(PropertySurface.rowMove(in: note, caret: 45, down: false) == 22)
        #expect(PropertySurface.rowMove(in: "Body\n", caret: 0, down: true) == nil)
    }

    @Test("A tap on an empty value gives it its space and stands after it")
    func tapEmptyValue() throws {
        let source = "---\nstatus:\n---\n"
        let settled = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: true, caret: 4, normal: false, in: source))
        #expect(settled.edits.count == 1)
        let after = settled.edits.reduce(source) { applying($1.edit, to: $0) }
        #expect(after == "---\nstatus: \n---\n")
        #expect(settled.caret == 12)
        #expect(settled.spacedLine == 4)
    }

    @Test("A tap on a key without its colon writes one; on the key column it stays in the key")
    func tapKey() throws {
        let bare = "---\nstatus\n---\n"
        let settled = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: true, caret: 6, normal: false, in: bare))
        #expect(settled.edits.reduce(bare) { applying($1.edit, to: $0) } == "---\nstatus: \n---\n")
        #expect(settled.caret == 12)
        let key = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: false, caret: 14, normal: false, in: note))
        #expect(key.caret == 9 && key.edits.isEmpty)
    }

    @Test("A tap on an inline list makes it a block list, the caret after its pills")
    func tapInlineList() throws {
        let source = "---\nkinds: [a, b]\n---\n"
        let settled = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: true, caret: 12, normal: false, in: source))
        let after = settled.edits.reduce(source) { applying($1.edit, to: $0) }
        #expect(after == "---\nkinds: \n  - a\n  - b\n---\n")
        #expect(settled.caret == 11)
    }

    @Test("A pill's × removes its item, an inline list made a block list first")
    func removeItem() {
        let removed = PropertySurface.removingItem(at: 0, fromListAt: 17, in: note).reduce(note) { applying($1.edit, to: $0) }
        #expect(removed == "---\ntitle: Hello\ntags:\n  - two\n---\nBody\n")
        let inline = "---\nkinds: [a, b]\n---\n"
        let steps = PropertySurface.removingItem(at: 1, fromListAt: 4, in: inline)
        #expect(steps.map(\.name) == ["Edit List", "Remove Item"])
        #expect(steps.reduce(inline) { applying($1.edit, to: $0) } == "---\nkinds:\n  - a\n---\n")
    }

    @Test("Typing into the hidden gap goes to the value; deleting across it is refused")
    func typingInGap() throws {
        let source = "---\nstatus:\n---\n"
        let edit = try #require(PropertySurface.valueInsertion(of: "x", selection: NSRange(location: 11, length: 0), in: source))
        #expect(applying(edit, to: source) == "---\nstatus: x\n---\n")
        #expect(PropertySurface.deletionCrossesColonGap(selection: NSRange(location: 11, length: 0), forward: false, in: note) == true)
        #expect(PropertySurface.deletionCrossesColonGap(selection: NSRange(location: 12, length: 0), forward: false, in: note) == false)
    }

    @Test("Return, Tab, space and Backspace on a list's key line edit its pills")
    func listKeys() throws {
        let typed = "---\ntags: three\n  - one\n---\n"
        let caret = NSRange(location: 15, length: 0)
        let returned = try #require(PropertySurface.listReturn(selection: caret, in: typed))
        #expect(returned.name == "Add Item")
        #expect(applying(returned.edit, to: typed) == "---\ntags:\n  - one\n  - three\n---\n")
        #expect(PropertySurface.itemAddedByTab(selection: caret, in: typed).map { applying($0, to: typed) }
            == "---\ntags:\n  - one\n  - three\n---\n")
        #expect(PropertySurface.tagEndedBySpace(selection: caret, in: typed) != nil)
        // Nothing typed: Return starts a property, Backspace takes the last pill.
        let empty = "---\ntags:\n  - one\n---\n"
        let at = NSRange(location: 9, length: 0)
        #expect(PropertySurface.listReturn(selection: at, in: empty)?.name == "Add Property")
        #expect(PropertySurface.backspaceRemovingItem(selection: at, in: empty).map { applying($0, to: empty) } == "---\ntags:\n---\n")
    }

    @Test("Tab after a key writes the colon the table hides")
    func tabToValue() throws {
        let source = "---\nstatus\n---\n"
        let edit = try #require(PropertySurface.movingToValue(selection: NSRange(location: 10, length: 0), in: source))
        #expect(applying(edit, to: source) == "---\nstatus: \n---\n")
        #expect(edit.selection.location == 12)
    }

    @Test("Deleting a property takes its items; the last one takes the fences")
    func deleting() throws {
        let edit = try #require(PropertySurface.deletingProperty(at: 20, in: note))
        #expect(applying(edit, to: note) == "---\ntitle: Hello\n---\nBody\n")
        let only = "---\na: 1\n---\nBody"
        #expect(PropertySurface.deletingProperty(at: 5, in: only).map { applying($0, to: only) } == "Body")
    }

    @Test("Add Property uses a waiting blank row, else adds one, else makes the block")
    func adding() {
        #expect(PropertySurface.addingProperty(in: "---\na: 1\n\n---\n").edit == nil)
        #expect(PropertySurface.addingProperty(in: "---\na: 1\n\n---\n").caret == 9)
        let added = PropertySurface.addingProperty(in: note)
        #expect(added.edit.map { applying($0, to: note) } == "---\ntitle: Hello\ntags:\n  - one\n  - two\n\n---\nBody\n")
        #expect(added.caret == 39)
        #expect(PropertySurface.addingProperty(in: "Body").edit.map { applying($0, to: "Body") } == "---\n\n---\nBody")
    }

    @Test("Only lines that are properties are pasted as properties")
    func pasting() {
        #expect(PropertySurface.pastableProperties("a: 1\ntags:\n  - x") == "a: 1\ntags:\n  - x\n")
        #expect(PropertySurface.pastableProperties("Just a sentence") == nil)
        #expect(PropertySurface.pastableProperties("# heading: no") == nil)
    }

    @Test("Leaving rows asks for what each needs, once")
    func leaving() {
        var leaving = PropertyLeaving()
        // Onto a blank row, then off it: it goes.
        let blank = "---\na: 1\n\n---\n"
        #expect(leaving.caretMoved(to: NSRange(location: 9, length: 0), in: blank, normal: false).isEmpty)
        #expect(leaving.caretMoved(to: NSRange(location: 5, length: 0), in: blank, normal: false) == [.removeBlankRow(9), .tidyRow(9)])
        // Into an empty value: given its space; left: it is taken back.
        var empty = PropertyLeaving()
        let value = "---\nstatus:\nb: 2\n---\n"
        #expect(empty.caretMoved(to: NSRange(location: 11, length: 0), in: value, normal: false) == [.spaceValue(4)])
        empty.spacedValueLine = 4
        #expect(empty.caretMoved(to: NSRange(location: 15, length: 0), in: value, normal: false) == [.unspaceValue(4), .tidyRow(4)])
        // An item typed after the pills, left: committed.
        var list = PropertyLeaving()
        let typed = "---\ntags: three\n  - one\na: 1\n---\n"
        _ = list.caretMoved(to: NSRange(location: 15, length: 0), in: typed, normal: false)
        #expect(list.caretMoved(to: NSRange(location: 27, length: 0), in: typed, normal: false).contains(.commitItem(4)))
    }

    @Test("Why a row is red: a key twice before a value of the wrong type")
    func warnings() {
        let twice = "---\nn: 1\nn: 2\n---\n"
        #expect(PropertySurface.warning(forLineAt: 4, in: twice, types: [:])?.contains("twice") == true)
        let wrong = "---\nn: abc\n---\n"
        #expect(PropertySurface.warning(forLineAt: 4, in: wrong, types: ["n": .number])?.contains("number") == true)
        #expect(PropertySurface.warning(forLineAt: 4, in: wrong, types: [:]) == nil)
    }
}
