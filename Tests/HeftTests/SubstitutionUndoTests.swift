import AppKit
import Testing
@testable import Heft

/// ⌘Z right after `->` became `→` puts back `->`, the way backspace does,
/// instead of undoing the keystroke that triggered it as well.
@MainActor
@Suite("Undoing a substitution")
struct SubstitutionUndoTests {

    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    @Test("⌘Z takes back the arrow and keeps what was typed")
    func undoRestoresTypedText() {
        let typing = TypingSettings.shared
        let previous = typing.substitutionsEnabled
        typing.substitutionsEnabled = true
        defer { typing.substitutionsEnabled = previous }

        let host = UndoHost()
        // One group per keystroke, as the app gets one per key event.
        host.manager.groupsByEvent = false
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.isRichText = false
        view.allowsUndo = true
        view.delegate = host
        for character in "x ->" {
            host.manager.beginUndoGrouping()
            view.insertText(String(character), replacementRange: view.selectedRange())
            host.manager.endUndoGrouping()
        }
        #expect(view.string == "x \u{2192}")

        host.manager.undo()
        #expect(view.string == "x ->")
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
        host.manager.undo()
        #expect(view.string == "x -")

        host.manager.redo()
        #expect(view.string == "x ->")
        host.manager.redo()
        #expect(view.string == "x \u{2192}")
    }
}
