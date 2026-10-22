import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A line break Heft adds is the note's own: a Windows note gets `\r\n`, a
/// Unix one `\n`, and nothing already in the note is rewritten.
@Suite("Line endings")
struct LineEndingTests {

    @Test("A note's ending is the one most of its breaks use")
    func detection() {
        #expect(LineEnding(of: "") == .lf)
        #expect(LineEnding(of: "one line") == .lf)
        #expect(LineEnding(of: "a\r\nb\r\n") == .crlf)
        #expect(LineEnding(of: "a\nb\n") == .lf)
        // Mixed by an editor that typed `\n` into a Windows note.
        #expect(LineEnding(of: "a\r\nb\nc\r\n") == .crlf)
        // One pasted Windows line does not turn a Unix note.
        #expect(LineEnding(of: "a\nb\r\nc\n") == .lf)
        #expect(LineEnding(of: "a\rb\rc\n") == .lf)
    }

    @Test("Inserted text takes the note's ending, whatever it arrived with")
    func applying() {
        #expect(LineEnding.crlf.applied(to: "a\nb\r\nc\rd") == "a\r\nb\r\nc\r\nd")
        #expect(LineEnding.lf.applied(to: "a\nb\r\nc\rd") == "a\nb\nc\nd")
        #expect(!LineEnding.crlf.differs(in: "a\r\nb"))
        #expect(LineEnding.crlf.differs(in: "a\nb"))
        #expect(LineEnding.crlf.differs(in: "a\r"))
        #expect(LineEnding.lf.differs(in: "a\r\nb"))
        #expect(!LineEnding.lf.differs(in: "a\nb"))
    }

    @Test("An edit's selection moves with the breaks its replacement gained")
    func editSelection() {
        // `- a` then Return in a list: the caret after the new marker.
        let edit = MarkdownEditing.Edit(
            range: NSRange(location: 3, length: 0), replacement: "\n- ",
            selection: NSRange(location: 6, length: 0)
        ).adapted(to: .crlf)
        #expect(edit.replacement == "\r\n- ")
        #expect(edit.selection == NSRange(location: 7, length: 0))

        // A table row inserted after the header: the caret is in the row,
        // past the break.
        let row = TableEditing.Action(
            replace: NSRange(location: 10, length: 0), replacement: "\n|  |",
            selection: NSRange(location: 13, length: 0)
        ).adapted(to: .crlf)
        #expect(row.replacement == "\r\n|  |")
        #expect(row.selection == NSRange(location: 14, length: 0))

        // A selection after the edit shifts by everything it gained; one
        // before it does not move.
        let result = LineEnding.crlf.adapting(
            [(NSRange(location: 4, length: 1), "x\ny\nz")],
            selections: [NSRange(location: 2, length: 0), NSRange(location: 10, length: 2),
                         NSRange(location: 4, length: 5)]
        )
        #expect(result.edits[0].replacement == "x\r\ny\r\nz")
        #expect(result.selections == [NSRange(location: 2, length: 0),
                                      NSRange(location: 12, length: 2),
                                      NSRange(location: 4, length: 7)])

        // CRLF pasted into a Unix note shrinks, and a caret between `\r` and
        // `\n` lands after the break.
        let shrunk = LineEnding.lf.adapting(
            [(NSRange(location: 0, length: 0), "a\r\nb")],
            selections: [NSRange(location: 2, length: 0), NSRange(location: 4, length: 0)]
        )
        #expect(shrunk.edits[0].replacement == "a\nb")
        #expect(shrunk.selections == [NSRange(location: 2, length: 0), NSRange(location: 3, length: 0)])
    }

    @Test("Several edits move the selections between and after them")
    func severalEdits() {
        // Given out of order, as Vim hands them back.
        let result = LineEnding.crlf.adapting(
            [(NSRange(location: 10, length: 0), "\n"), (NSRange(location: 2, length: 0), "\n")],
            selections: [NSRange(location: 5, length: 0), NSRange(location: 13, length: 0)]
        )
        #expect(result.edits.map(\.replacement) == ["\r\n", "\r\n"])
        #expect(result.selections == [NSRange(location: 6, length: 0), NSRange(location: 15, length: 0)])
    }
}

/// The Mac editor, headless: every way a break gets typed into a Windows note.
@MainActor
@Suite("Line endings in the Mac editor")
struct LineEndingEditorTests {

    private func editor(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("Return in a Windows note types a Windows break")
    func returnKey() {
        let view = editor("one\r\ntwo\r\n", caret: 3)
        view.insertNewline(nil)
        #expect(view.string == "one\r\n\r\ntwo\r\n")
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))

        let unix = editor("one\ntwo\n", caret: 3)
        unix.insertNewline(nil)
        #expect(unix.string == "one\n\ntwo\n")
    }

    @Test("Ctrl-Return types a plain break in the note's ending, with no list marker")
    func lineBreakKey() {
        let view = editor("- one\r\ntwo\r\n", caret: 5)
        view.insertLineBreak(nil)
        #expect(view.string == "- one\r\n\r\ntwo\r\n")
        #expect(view.selectedRange() == NSRange(location: 7, length: 0))

        let unix = editor("one\n", caret: 3)
        unix.insertParagraphSeparator(nil)
        #expect(unix.string == "one\n\n")
        #expect(!unix.string.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" })
    }

    @Test("Return continues and ends a list in the note's ending")
    func listContinuation() {
        let view = editor("- one\r\n- two\r\n", caret: 12)
        view.insertNewline(nil)
        #expect(view.string == "- one\r\n- two\r\n- \r\n")
        #expect(view.selectedRange() == NSRange(location: 16, length: 0))
        // Return on the empty item ends the list.
        view.insertNewline(nil)
        #expect(view.string == "- one\r\n- two\r\n\r\n\r\n")
        #expect(!view.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("Text pasted or dropped takes the note's ending")
    func pasting() {
        let board = NSPasteboard(name: NSPasteboard.Name("heft-line-endings-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("a\nb", forType: .string)
        let windows = editor("one\r\ntwo\r\n", caret: 3)
        #expect(windows.readSelection(from: board, type: .string))
        #expect(windows.string == "onea\r\nb\r\ntwo\r\n")
        #expect(windows.selectedRange() == NSRange(location: 7, length: 0))

        board.clearContents()
        board.setString("a\r\nb", forType: .string)
        let unix = editor("one\ntwo\n", caret: 3)
        #expect(unix.readSelection(from: board, type: .string))
        #expect(unix.string == "onea\nb\ntwo\n")
    }

    @Test("A block typed from a command takes the note's ending")
    func typedBlock() {
        let view = editor("Prose\r\n", caret: 5)
        let table = TableEditing.blankTable(rows: 1, columns: 2, newlinesBefore: 0)
        view.type(EditorInsertion(
            text: table.text, caretOffset: table.caretOffset, startsBlock: true, generation: 1
        ))
        #expect(!view.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        // The caret is in the first cell, as it is in a Unix note.
        let unix = editor("Prose\n", caret: 5)
        unix.type(EditorInsertion(
            text: table.text, caretOffset: table.caretOffset, startsBlock: true, generation: 1
        ))
        let unixLine = (unix.string as NSString).lineRange(for: unix.selectedRange())
        let line = (view.string as NSString).lineRange(for: view.selectedRange())
        #expect(view.selectedRange().location - line.location
            == unix.selectedRange().location - unixLine.location)
        #expect((view.string as NSString).substring(with: line).hasPrefix("| "))
    }

    @Test("Vim's o and O open a line in the note's ending")
    func vimOpenLine() throws {
        let below = editor("one\r\ntwo\r\n", caret: 0)
        below.vimEnabled = true
        below.keyDown(with: try Self.key("o"))
        #expect(below.string == "one\r\n\r\ntwo\r\n")
        #expect(below.selectedRange() == NSRange(location: 5, length: 0))

        let list = editor("- one\r\n", caret: 0)
        list.vimEnabled = true
        list.vimContinuesMarkdownStructure = true
        list.keyDown(with: try Self.key("o"))
        #expect(list.string == "- one\r\n- \r\n")
        list.keyDown(with: try Self.key("\u{1b}", keyCode: 53))
        list.keyDown(with: try Self.key("O"))
        #expect(!list.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("A table row added with Return in a Windows note keeps the table Windows")
    func tableRow() {
        let document = "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\nAfter\r\n"
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "probe.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = document
        coordinator.restyle(view)
        view.setSelectedRange(NSRange(location: (document as NSString).range(of: "1").location, length: 0))
        coordinator.restyle(view)
        view.insertNewline(nil)
        #expect(view.string.occurrences(of: "\r\n") == 6)
        #expect(!view.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        // The caret went into the new row, not onto its break.
        let line = (view.string as NSString).lineRange(for: view.selectedRange())
        #expect(line.location == (document as NSString).range(of: "\r\n\r\nAfter").location + 2)
    }

    private static func key(_ characters: String, keyCode: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int { components(separatedBy: needle).count - 1 }
}
