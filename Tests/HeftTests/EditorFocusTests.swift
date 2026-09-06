import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// A note just named in the sidebar has the caret in the sidebar's field. The
/// model stamps a focus request, and the editor answers it by taking the
/// keyboard from whatever holds it.
@Suite("The editor taking the keyboard")
@MainActor
struct EditorFocusTests {
    @Test("A focus request moves first responder from another field to the text view")
    func takesTheKeyboard() throws {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(""), documentIdentity: "n.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // Any view that can hold first responder. Not a text field: one of
        // those in a headless test window spins up the system's completion
        // service, which has aborted the whole test process once.
        let field = FocusableView(frame: NSRect(x: 0, y: 260, width: 200, height: 24))
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 250)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(field)
        try #require(window.firstResponder !== view)

        coordinator.takeKeyboard(view)
        #expect(window.firstResponder === view)
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
