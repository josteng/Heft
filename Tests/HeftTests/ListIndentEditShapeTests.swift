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
