import Foundation
import Testing
@testable import Heft

/// Who ⌘Z belongs to. One menu item owns the key and asks this, because two
/// items cannot share it: a disabled one swallows its own key equivalent, and
/// the other never sees the press.
@Suite("Undo routing")
struct UndoRoutingTests {

    @Test("The tree gets it only when it is pointed at and has something to put back")
    func sidebarWinsWhenItOwnsTheKeys() {
        #expect(UndoRouting.target(sidebarOwnsKeys: true, sidebarHasStep: true) == .sidebar)
    }

    @Test("With the caret in the text, the text gets it even with a step waiting")
    func textWinsWhenTheEditorHasTheKeys() {
        // The regression this exists to prevent: undoing a sentence must not
        // depend on whether a file was moved ten minutes ago.
        #expect(UndoRouting.target(sidebarOwnsKeys: false, sidebarHasStep: true) == .text)
    }

    @Test("A row with nothing to put back leaves the key to the text")
    func textWinsWithNoStep() {
        #expect(UndoRouting.target(sidebarOwnsKeys: true, sidebarHasStep: false) == .text)
    }

    @Test("With neither, it is still the text's")
    func textIsTheDefault() {
        // Never nobody's: an owner that answers "no one" is a key that beeps.
        #expect(UndoRouting.target(sidebarOwnsKeys: false, sidebarHasStep: false) == .text)
    }

    @Test("One menu item owns the key, and it is never disabled")
    func oneOwnerAlwaysEnabled() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/HeftApp.swift"),
            encoding: .utf8
        )
        // Replacing the system pair, not sitting beside it: two Undo items
        // both claiming ⌘Z is what broke the editor's.
        #expect(source.contains("CommandGroup(replacing: .undoRedo)"))
        #expect(!source.contains("CommandGroup(after: .undoRedo)"))
        // And the text's half is forwarded rather than reimplemented.
        #expect(source.contains("Selector((\"undo:\"))"))
        #expect(source.contains("Selector((\"redo:\"))"))
    }
}
