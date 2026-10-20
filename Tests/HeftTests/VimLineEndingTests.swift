import AppKit
import Testing
@testable import Heft

/// Vim's registers in a Windows note, through the editor that applies them.
@MainActor
@Suite("Vim in a Windows note")
struct VimLineEndingTests {

    private func editor(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("Vim's linewise yank, put and change treat a Windows break as one")
    func vimLinewise() throws {
        func run(_ keys: String, on text: String) throws -> String {
            let view = editor(text, caret: 0)
            view.vimEnabled = true
            for key in keys {
                let escape = key == "\u{1b}"
                view.keyDown(with: try Self.key(String(key), keyCode: escape ? 53 : 0))
            }
            return view.string
        }
        let note = "one\r\ntwo\r\n"
        // `"one\r\n".hasSuffix("\n")` is false: `\r\n` is one Character,
        // and the register gained a second break.
        #expect(try run("yyp", on: note) == "one\r\none\r\ntwo\r\n")
        #expect(try run("ddp", on: note) == "two\r\none\r\n")
        #expect(try run("ccx\u{1b}", on: note) == "x\r\ntwo\r\n")
        // An appended register, and a characterwise delete across lines,
        // which goes to the numbered ring and puts back with the caret on
        // its first character.
        #expect(try run("\"ayyj\"Ayy\"ap", on: note) == "one\r\ntwo\r\none\r\ntwo\r\n")
        let view = editor("one\r\ntwo\r\nend", caret: 0)
        view.vimEnabled = true
        for key in "vjd\"1P" { view.keyDown(with: try Self.key(String(key))) }
        #expect(view.string == "one\r\ntwo\r\nend")
        #expect(view.selectedRange().location == 0)
    }


    private static func key(_ characters: String, keyCode: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }
}
