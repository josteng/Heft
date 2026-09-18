import AppKit
import Testing
@testable import Heft

/// What shape of edit indenting a list item makes.
///
/// It matters beyond tidiness: undoing a *replacement* makes AppKit select
/// what it put back, and a selection on the line raises the format bar over it
/// and sends the next keystroke to the front of the line. Undoing an insertion
/// leaves a plain caret. So an already-tab-indented item moves one tab in or
/// out, and only genuinely mixed indentation is rewritten.
@MainActor
@Suite("List indent edit shape")
struct ListIndentEditShapeTests {

    /// Records what the view asks to change, which is the shape of the edit.
    final class Recorder: NSObject, NSTextViewDelegate {
        var ranges: [NSRange] = []
        var replacements: [String] = []
        /// A view outside a window finds no undo manager up the responder
        /// chain, so the delegate hands it one.
        let manager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { manager }

        func textView(
            _ view: NSTextView, shouldChangeTextIn range: NSRange,
            replacementString text: String?
        ) -> Bool {
            ranges.append(range)
            replacements.append(text ?? "")
            return true
        }
    }

    private func indenting(
        _ source: String, outdent: Bool = false
    ) -> (range: NSRange, replacement: String, result: String) {
        let recorder = Recorder()
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.string = source
        view.delegate = recorder
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        if outdent { view.insertBacktab(nil) } else { view.insertTab(nil) }
        return (
            recorder.ranges.last ?? NSRange(location: NSNotFound, length: 0),
            recorder.replacements.last ?? "",
            view.string
        )
    }

    @Test("Indenting a tab-indented item inserts one tab")
    func indentingInsertsOneTab() {
        let edit = indenting("\t- x")
        #expect(edit.range.length == 0)
        #expect(edit.replacement == "\t")
        #expect(edit.result == "\t\t- x")
    }

    @Test("Indenting deeper still only inserts")
    func deeperStillInserts() {
        let edit = indenting("\t\t\t- x")
        #expect(edit.range.length == 0)
        #expect(edit.result == "\t\t\t\t- x")
    }

    @Test("Outdenting removes one tab and puts nothing back")
    func outdentingRemovesOneTab() {
        let edit = indenting("\t\t- x", outdent: true)
        #expect(edit.range.length == 1)
        #expect(edit.replacement.isEmpty)
        #expect(edit.result == "\t- x")
    }

    @Test("An item at the margin still inserts its first tab")
    func theFirstTabIsStillAnInsertion() {
        let edit = indenting("- x")
        #expect(edit.range.length == 0)
        #expect(edit.result == "\t- x")
    }

    /// Undoing an insertion leaves AppKit's insertion point at the change,
    /// and an indent changes the front of the line, so without this the caret
    /// came back in front of the marker and the next keystroke landed there.
    ///
    /// The caret is deliberately moved between the indent and the undo, the
    /// way leaving insert mode or a restyle moves it in the editor: without
    /// it, AppKit's own answer and the right one are the same and the test
    /// could not tell them apart.
    @Test("Undoing an indent puts the caret back where it was")
    func undoRestoresTheCaret() {
        let recorder = Recorder()
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.allowsUndo = true
        view.string = "\t- x"
        view.delegate = recorder
        let before = NSRange(location: 4, length: 0)
        view.setSelectedRange(before)
        view.insertTab(nil)
        #expect(view.string == "\t\t- x")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        recorder.manager.undo()
        #expect(view.string == "\t- x")
        #expect(view.selectedRange() == before)
    }

    @Test("Undoing an outdent puts the caret back too")
    func undoOfAnOutdentRestoresTheCaret() {
        let recorder = Recorder()
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.allowsUndo = true
        view.string = "\t\t- x"
        view.delegate = recorder
        let before = NSRange(location: 5, length: 0)
        view.setSelectedRange(before)
        view.insertBacktab(nil)
        #expect(view.string == "\t- x")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        recorder.manager.undo()
        #expect(view.string == "\t\t- x")
        #expect(view.selectedRange() == before)
    }

    /// The one case that still rewrites the run, and deliberately: spaces are
    /// normalised to tabs when the reader changes the depth by hand.
    @Test("Space indentation is still normalised to tabs")
    func spacesAreStillNormalised() {
        let edit = indenting("  - x")
        #expect(edit.range.length == 2)
        #expect(edit.replacement == "\t\t")
        #expect(edit.result == "\t\t- x")
    }
}
