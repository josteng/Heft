import AppKit
import HeftCore
import Testing
@testable import Heft

/// The formatting bar over a Vim visual selection: shown for Visual and
/// Visual Line unless the setting hides it, never for Visual Block, and
/// formatting from it leaves Vim acting on the words it just formatted.
@MainActor
@Suite("The formatting bar in Vim visual modes", .serialized)
struct VimFormatBarTests {

    private func key(
        _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    /// A focused editor in a window, since the bar only shows for the first
    /// responder.
    private func editor(_ text: String) -> (NSWindow, HeftTextKit2View) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.documentView = view
        window.contentView = scroll
        view.string = text
        view.vimEnabled = true
        view.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(view)
        return (window, view)
    }

    @Test("Visual and Visual Line show the bar unless the setting hides it")
    func visualShowsBar() throws {
        let (window, view) = editor("one two\nthree")
        defer { window.close() }
        view.keyDown(with: try key("v", keyCode: 9))
        view.keyDown(with: try key("e", keyCode: 14))
        try #require(view.selectedRange().length > 0)
        view.updateFormatBar()
        #expect(view.formatBar?.isHidden == false)

        view.vimShowsFormatBarInVisual = false
        #expect(view.formatBar?.isHidden == true)
        view.vimShowsFormatBarInVisual = true

        view.keyDown(with: try key("V", keyCode: 9, modifiers: .shift))
        try #require(view.selectedRange().length > 0)
        view.updateFormatBar()
        #expect(view.formatBar?.isHidden == false)
    }

    @Test("Visual Block keeps the bar hidden")
    func blockHidesBar() throws {
        let (window, view) = editor("one\ntwo")
        defer { window.close() }
        view.keyDown(with: try key("v", keyCode: 9, modifiers: .control))
        view.keyDown(with: try key("j", keyCode: 38))
        view.keyDown(with: try key("l", keyCode: 37))
        try #require(view.selectedRange().length > 0)
        view.updateFormatBar()
        #expect(view.formatBar?.isHidden != false)
    }

    @Test("Formatting in Visual mode leaves Vim acting on the formatted words")
    func formattingKeepsVimInStep() throws {
        let (window, view) = editor("one two")
        defer { window.close() }
        view.keyDown(with: try key("v", keyCode: 9))
        view.keyDown(with: try key("e", keyCode: 14))
        try #require(view.selectedRange() == NSRange(location: 0, length: 3))

        view.applyFormat(.bold)
        #expect(view.string == "**one** two")
        // `d` deletes what is selected now, the word inside the new markers,
        // not the three characters Vim had selected before the edit.
        view.keyDown(with: try key("d", keyCode: 2))
        #expect(view.string == "**** two")
    }
}
