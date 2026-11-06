import Foundation
import HeftCore
import Testing

/// Property edits that change bytes they should not.
@Suite("Property edits keep the bytes")
struct PropertyByteTests {
    private func applying(_ edit: MarkdownEditing.Edit, to source: String) -> String {
        (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func leaving(_ source: String, rowAt start: Int) -> String {
        let away = (source as NSString).length
        guard let edit = PropertySurface.tidyingRow(at: start, caret: away, in: source) else { return source }
        return applying(edit, to: source)
    }

    @Test("Leaving a block scalar's row keeps its literal text")
    func blockScalarKept() {
        let note = "---\nnotes: |\n  - [[Note]] was read\n  - [[Other]]\n---\nBody\n"
        #expect(leaving(note, rowAt: 4) == note)
    }

    @Test("Leaving a quoted key holding a colon keeps the key")
    func quotedKeyKept() {
        let note = "---\n\"a:b\": c\n---\nBody\n"
        #expect(leaving(note, rowAt: 4) == note)
    }

    @Test("Tapping a flow list keeps a quoted item holding a comma whole")
    func flowListQuotedComma() throws {
        let note = "---\nnames: [\"Doe, Jane\", Bob]\n---\n"
        let settled = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: true, caret: 30, normal: false, in: note))
        var result = note
        for step in settled.edits { result = applying(step.edit, to: result) }
        #expect(result.hasSuffix("\n  - \"Doe, Jane\"\n  - Bob\n---\n"), "\(result.debugDescription)")
    }

    @Test("Tapping a bare link value keeps the link")
    func bareLinkTapped() throws {
        let note = "---\nup: [[Note]]\n---\n"
        let settled = try #require(PropertySurface.settlingTap(onLineAt: 4, inValue: true, caret: 15, normal: false, in: note))
        var result = note
        for step in settled.edits { result = applying(step.edit, to: result) }
        #expect(result.contains("[[Note]]"))
    }

    @Test("A list made text keeps a quoted item's comma inside it")
    func listToTextQuoted() throws {
        let note = "---\nnames:\n  - \"Doe, Jane\"\n  - Bob\n---\n"
        let edit = try #require(PropertyEditing.converting(key: "names", toList: false, in: note))
        let result = applying(edit, to: note)
        // Read back, the property must still be two names, or one string of both.
        let parsed = Frontmatter.parse(try #require(NoteText.splitFrontmatter(result).frontmatter))
        #expect(parsed.first?.value.items == ["Doe, Jane, Bob"] || parsed.first?.value.items == ["Doe, Jane", "Bob"])
    }

    @Test("Body lines after an unclosed frontmatter are not tidied")
    func unclosedFrontmatterBody() {
        let note = "---\ntitle: x\n\nSome prose here\n\n```\ncode\n```\n---\n"
        let edits = PropertySurface.tidyingAll(in: note)
        #expect(edits.isEmpty)
    }

    @Test("Setting a type for a key keeps one entry whatever its case")
    func typesCase() {
        let source = "{\n  \"types\": {\n    \"status\": \"text\"\n  }\n}"
        let result = PropertyTypes.setting(.number, for: "Status", in: source)
        #expect(result == "{\n  \"types\": {\n    \"status\": \"number\"\n  }\n}", "\(result.debugDescription)")
    }
}

import AppKit
@testable import Heft

@MainActor
@Suite("Property edits on the Mac keep the line ending")
struct PropertyLineEndingViewTests {
    private func view(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    private func bareLineFeeds(_ text: String) -> Int {
        let units = Array(text.utf16)
        return units.indices.filter { units[$0] == 10 && ($0 == 0 || units[$0 - 1] != 13) }.count
    }

    @Test("Return on a list's key line in a CRLF note writes CRLF")
    func listReturnCRLF() {
        let note = "---\r\ntags:\r\n  - a\r\n---\r\nBody\r\n"
        let editor = view(note, caret: 10)
        #expect(editor.handlePropertyListReturn())
        #expect(bareLineFeeds(editor.string) == 0)
    }

    @Test("Add property in a CRLF note with no frontmatter writes CRLF")
    func addPropertyCRLF() {
        let editor = view("Body\r\nMore\r\n", caret: 2)
        editor.editProperties()
        #expect(bareLineFeeds(editor.string) == 0)
    }

    @Test("Pasting a copied CRLF property into an LF note writes LF")
    func pasteLineEnding() {
        let editor = view("---\nA: 1\n---\nBody\n", caret: 6)
        let board = NSPasteboard(name: NSPasteboard.Name("heft-property-paste-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("B: 2\r\n", forType: .string)
        editor.propertyPasteboard = board
        let item = NSMenuItem(title: "Paste", action: nil, keyEquivalent: "")
        item.representedObject = 4
        editor.pasteProperties(item)
        #expect(editor.string.contains("B: 2"))
        #expect(!Array(editor.string.utf16).contains(13))
        #expect(editor.string == "---\nA: 1\nB: 2\n---\nBody\n")
    }
}

@Suite("Pasting a property")
struct PropertyPasteTests {
    @Test("A CRLF property copied from a CRLF note pastes without an extra blank line")
    func crlfPaste() {
        #expect(PropertySurface.pastableProperties("B: 2\r\n") == "B: 2\r\n")
    }
}

@Suite("An empty frontmatter block")
struct PropertyEmptyBlockTests {
    @Test("A block the surface does not draw as a table does not move the caret off its fences")
    func emptyBlock() {
        let note = "---\n---\nBody\n"
        let drawn = LiveDecorator.decorations(in: note).contains { $0.style == .frontmatter }
        let moved = PropertySurface.caretOffFences(in: note, caret: 0, previous: nil, normal: false)
        #expect(drawn || moved == nil)
    }
}
