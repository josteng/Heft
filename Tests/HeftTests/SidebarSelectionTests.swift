import Foundation
import Testing
@testable import Heft

/// The three clicks, and the edges each of them has.
@Suite("Sidebar selection")
struct SidebarSelectionTests {

    /// A tree as it is drawn: a folder, two of its notes, then a note beside it.
    private let visible = ["Folder", "Folder/A.md", "Folder/B.md", "C.md", "D.md"]

    private func selection(_ clicks: [(String, SidebarSelection.Click)]) -> SidebarSelection {
        var selection = SidebarSelection()
        for (path, click) in clicks {
            selection.click(path, click, visible: visible)
        }
        return selection
    }

    @Test("A plain click replaces whatever was selected")
    func plainReplaces() {
        let result = selection([("C.md", .plain), ("D.md", .toggle), ("Folder/A.md", .plain)])
        #expect(result.paths == ["Folder/A.md"])
        #expect(result.anchor == "Folder/A.md")
    }

    @Test("Command adds a row without losing the others")
    func toggleAdds() {
        let result = selection([("C.md", .plain), ("D.md", .toggle)])
        #expect(result.paths == ["C.md", "D.md"])
    }

    @Test("Command on a selected row takes it back out")
    func toggleRemoves() {
        let result = selection([("C.md", .plain), ("D.md", .toggle), ("C.md", .toggle)])
        #expect(result.paths == ["D.md"])
    }

    @Test("Command can empty the selection entirely")
    func toggleCanEmpty() {
        let result = selection([("C.md", .plain), ("C.md", .toggle)])
        #expect(result.isEmpty)
    }

    @Test("Shift takes everything between the two rows, as drawn")
    func extendTakesTheRange() {
        let result = selection([("Folder/A.md", .plain), ("D.md", .extend)])
        #expect(result.paths == ["Folder/A.md", "Folder/B.md", "C.md", "D.md"])
    }

    @Test("A range reaching backwards is the same range")
    func extendBackwards() {
        let forwards = selection([("Folder/A.md", .plain), ("C.md", .extend)])
        let backwards = selection([("C.md", .plain), ("Folder/A.md", .extend)])
        #expect(forwards.paths == backwards.paths)
        #expect(forwards.paths == ["Folder/A.md", "Folder/B.md", "C.md"])
    }

    @Test("Extending twice measures from where the reader started")
    func anchorDoesNotDrift() {
        // The bug this prevents: taking the second range from the end of the
        // first, so shrinking a selection by shift-clicking higher up grows
        // it downwards instead.
        var result = selection([("C.md", .plain), ("D.md", .extend)])
        result.click("Folder/B.md", .extend, visible: visible)
        #expect(result.paths == ["Folder/B.md", "C.md"])
        #expect(result.anchor == "C.md")
    }

    @Test("Shift with nothing to measure from selects the one row")
    func extendWithoutAnchor() {
        var selection = SidebarSelection()
        selection.click("C.md", .extend, visible: visible)
        #expect(selection.paths == ["C.md"])
        #expect(selection.anchor == "C.md")
    }

    @Test("A range stops at what is on screen, so a closed folder is not swept up")
    func rangeIsWhatIsDrawn() {
        // The same click with the folder collapsed: its notes are not drawn,
        // so they are not in the range.
        var collapsed = SidebarSelection()
        collapsed.click("Folder", .plain, visible: ["Folder", "C.md", "D.md"])
        collapsed.click("C.md", .extend, visible: ["Folder", "C.md", "D.md"])
        #expect(collapsed.paths == ["Folder", "C.md"])
    }

    @Test("A row that is gone is forgotten")
    func pruneDropsMissingRows() {
        var result = selection([("C.md", .plain), ("D.md", .toggle)])
        result.prune(to: ["C.md"])
        #expect(result.paths == ["C.md"])
    }

    @Test("An anchor that is gone stops anchoring")
    func pruneClearsTheAnchor() {
        // C is clicked first, then D, so D is the anchor; pruning D away is
        // what leaves the selection with nothing to measure from.
        var result = selection([("C.md", .plain), ("D.md", .toggle)])
        result.prune(to: ["C.md"])
        #expect(result.anchor == nil)
        // And a shift-click afterwards is a plain one rather than a range
        // measured from a row in the Trash.
        result.click("Folder/A.md", .extend, visible: visible)
        #expect(result.paths == ["Folder/A.md"])
    }

    @Test("Clicking inside the selection acts on all of it")
    func targetInsideTheSelection() {
        let result = selection([("C.md", .plain), ("D.md", .toggle)])
        #expect(Set(result.target(clicking: "C.md")) == ["C.md", "D.md"])
    }

    @Test("Clicking outside the selection acts on that row alone")
    func targetOutsideTheSelection() {
        // Pointing at something else must not quietly act on the old
        // selection, which is how the wrong files get deleted.
        let result = selection([("C.md", .plain), ("D.md", .toggle)])
        #expect(result.target(clicking: "Folder/A.md") == ["Folder/A.md"])
    }
}
