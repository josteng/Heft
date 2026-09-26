import AppKit
import Testing
@testable import Heft

/// The editor's half of a paste onto a task: the pasted box replaces the one
/// in front of the caret, which is text the paste did not select.
@MainActor
@Suite("Pasting a task in the editor")
struct PastedTaskEditorTests {

    private func editor(_ text: String, caret: Int) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    @Test("A ticked task pasted onto an empty one stays ticked")
    func tickedStaysTicked() {
        let view = editor("- one\n- [ ] \n", caret: 12)
        #expect(view.insertTrimmingListMarker("- [x] milk"))
        #expect(view.string == "- one\n- [x] milk\n")
        #expect(view.selectedRange() == NSRange(location: 16, length: 0))
    }

    @Test("A plain line pasted onto a task is left to the ordinary paste")
    func plainTextIsNotHandled() {
        let view = editor("- [ ] ", caret: 6)
        #expect(!view.insertTrimmingListMarker("milk"))
        #expect(view.string == "- [ ] ")
    }
}
