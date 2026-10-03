import Foundation
import HeftCore
import Testing

/// Obsidian's "Toggle bullet list" and "Toggle numbered list".
@Suite("List toggles")
struct ListToggleTests {

    private func toggled(_ kind: MarkdownEditing.ListKind, _ source: String, _ range: NSRange? = nil) -> String {
        let whole = range ?? NSRange(location: 0, length: (source as NSString).length)
        return MarkdownEditing.toggleList(kind, in: source, range: whole).applied(to: source)
    }

    @Test("Plain lines become bullets, and bullets become plain lines")
    func bulletsRoundTrip() {
        #expect(toggled(.bullet, "milk\nbread\n") == "- milk\n- bread\n")
        #expect(toggled(.bullet, "- milk\n* bread\n") == "milk\nbread\n")
    }

    @Test("A mixed selection becomes all bullets, keeping the markers it had")
    func mixedBecomesBullets() {
        #expect(toggled(.bullet, "* milk\nbread\n1. eggs\n") == "* milk\n- bread\n- eggs\n")
    }

    @Test("Numbers count per indent and restart under a shallower item")
    func numbersPerIndent() {
        #expect(
            toggled(.numbered, "a\nb\n\tc\n\td\ne\n\tf\n")
                == "1. a\n2. b\n\t1. c\n\t2. d\n3. e\n\t1. f\n"
        )
    }

    @Test("A numbered list loses its numbers, and bullets become numbers")
    func numbersRoundTrip() {
        #expect(toggled(.numbered, "1. a\n2) b\n") == "a\nb\n")
        #expect(toggled(.numbered, "- a\n- b\n") == "1. a\n2. b\n")
    }

    @Test("Tasks keep their boxes as items and drop them as plain lines")
    func tasks() {
        #expect(toggled(.numbered, "- [ ] a\n- [x] b\n") == "1. [ ] a\n2. [x] b\n")
        #expect(toggled(.bullet, "- [ ] a\n- [x] b\n") == "a\nb\n")
    }

    @Test("Indentation, quotes and blank lines stay as they were")
    func surroundingsSurvive() {
        #expect(toggled(.bullet, "\t- a\n  b\n\n> c\n") == "\t- a\n  - b\n\n> - c\n")
    }

    @Test("Only blank lines is nothing to do")
    func blankIsNothing() {
        let edit = MarkdownEditing.toggleList(.bullet, in: "\n\n", range: NSRange(location: 0, length: 2))
        #expect(edit.isEmpty)
    }

    @Test("The caret stays on the same words")
    func caretFollowsWords() {
        let added = MarkdownEditing.toggleList(.bullet, in: "milk", range: NSRange(location: 2, length: 0))
        #expect(added.selection == NSRange(location: 4, length: 0))
        let removed = MarkdownEditing.toggleList(.bullet, in: "- milk", range: NSRange(location: 4, length: 0))
        #expect(removed.selection == NSRange(location: 2, length: 0))
        let inMarker = MarkdownEditing.toggleList(.bullet, in: "- milk", range: NSRange(location: 1, length: 0))
        #expect(inMarker.selection == NSRange(location: 0, length: 0))
        let below = MarkdownEditing.toggleList(
            .numbered, in: "a\nb", range: NSRange(location: 0, length: 3)
        )
        #expect(below.selection == NSRange(location: 3, length: 6))
    }
}
