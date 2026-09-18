import Testing
@testable import Heft

/// Which row the file tree lights once the reader arrives somewhere without
/// clicking the tree.
///
/// Opening a note by the calendar, Quick Open or a wikilink goes nowhere near
/// the sidebar, and `holdsFile` gives a picked-out file the light outright. So
/// a single click on a row kept the light long after that note stopped being
/// the open one, and the note actually on screen could not light at all.
@Suite("Sidebar follows the open note")
struct SidebarFollowsOpenNoteTests {

    private func picked(_ paths: Set<String>, folders: Set<String> = []) -> SidebarSelection {
        SidebarSelection(paths: paths, anchor: paths.first, folders: folders)
    }

    @Test("One picked file follows the note that opens")
    func oneFileFollows() {
        let after = picked(["A.md"]).following(openNote: "B.md")
        #expect(after.contains("B.md"))
        #expect(!after.contains("A.md"))
        #expect(after.count == 1)
    }

    /// The light is what the reader reads, so the point of the move above is
    /// that the open note lights and the stale row stops.
    @Test("And the light moves with it")
    func theLightMoves() {
        let after = picked(["A.md"]).following(openNote: "B.md")
        #expect(SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md", selected: after
        ))
        #expect(!SidebarHighlight.litsFile(
            "A.md", highlighted: nil, current: "B.md", selected: after
        ))
    }

    /// Several rows picked out is an operation being set up, not navigation.
    /// Moving it would quietly change what the next ⌘⌫ deletes.
    @Test("Several picked files are left alone")
    func severalAreLeftAlone() {
        let before = picked(["A.md", "B.md"])
        #expect(before.following(openNote: "C.md") == before)
    }

    /// Nothing picked already lights the open note, through `current`, and
    /// picking one here would hand ⌘⌫ something to delete that the reader
    /// never chose.
    @Test("An empty selection stays empty")
    func emptyStaysEmpty() {
        let before = SidebarSelection()
        #expect(before.following(openNote: "B.md") == before)
        #expect(SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md", selected: before
        ))
    }

    /// A plain click on a folder selects nothing, and a folder picked out by
    /// command is navigation too: neither should be replaced by a note.
    @Test("A picked folder is not replaced by the open note")
    func aPickedFolderStays() {
        let before = picked(["Notes"], folders: ["Notes"])
        #expect(before.following(openNote: "B.md") == before)
    }

    @Test("Opening the note already picked changes nothing")
    func openingThePickedOneIsStable() {
        let before = picked(["A.md"])
        #expect(before.following(openNote: "A.md") == before)
    }

    /// Closing the last note leaves the selection where it is: there is no
    /// open note to follow, and clearing it would lose the reader's place.
    @Test("No open note leaves the selection alone")
    func noOpenNoteLeavesItAlone() {
        let before = picked(["A.md"])
        #expect(before.following(openNote: nil) == before)
    }

    /// Clicking a row still selects it, which is the path this must not fight:
    /// the click sets the selection, the note opens, and following it is then
    /// a no-op rather than a second assignment.
    @Test("A click on a row is not undone by the note it opens")
    func aClickIsNotFought() {
        var selection = SidebarSelection()
        selection.click("A.md", .plain, visible: ["A.md", "B.md"])
        #expect(selection.following(openNote: "A.md") == selection)
    }
}
