import Foundation
import HeftCore
import Testing

/// Pasting a copied bullet onto a bullet that is already there.
@Suite("Pasted list markers")
struct PastedListMarkerTests {

    private func paste(_ text: String, after prefix: String) -> String {
        MarkdownEditing.pasted(text, afterLinePrefix: prefix)
    }

    @Test("A pasted marker is dropped when the line already has one")
    func dropsTheSecondMarker() {
        // The whole point: `- ` plus `- milk` was `- - milk`.
        #expect(paste("- milk", after: "- ") == "milk")
    }

    @Test("Only the first line loses its marker")
    func laterLinesKeepTheirs() {
        #expect(paste("- milk\n- bread", after: "- ") == "milk\n- bread")
    }

    @Test("A numbered marker is dropped the same way")
    func numberedMarkers() {
        #expect(paste("1. first", after: "1. ") == "first")
    }

    @Test("A pasted task keeps its box")
    func tasksKeepTheirBox() {
        // Pasting a task onto a bare bullet plainly means the task.
        #expect(paste("- [ ] milk", after: "- ") == "[ ] milk")
    }

    @Test("Text pasted mid-sentence is untouched")
    func midSentencePasteIsUntouched() {
        // `see - milk` is something somebody wrote. Tidying a dash away here
        // would silently eat a character.
        #expect(paste("- milk", after: "- see ") == "- milk")
    }

    @Test("Pasting onto an empty line keeps the marker")
    func emptyLineKeepsTheMarker() {
        #expect(paste("- milk", after: "") == "- milk")
    }

    @Test("Pasting text with no marker is untouched")
    func plainTextIsUntouched() {
        #expect(paste("milk", after: "- ") == "milk")
    }

    @Test("An indented paste is left alone")
    func indentedPasteIsUntouched() {
        // It is describing its own nesting, which is not this rule's business.
        #expect(paste("  - milk", after: "- ") == "  - milk")
    }

    @Test("A quoted bullet counts as a marker")
    func quotedBullets() {
        #expect(paste("- milk", after: "> - ") == "milk")
    }

    @Test("Nothing pasted is nothing changed")
    func emptyPaste() {
        #expect(paste("", after: "- ") == "")
    }
}
