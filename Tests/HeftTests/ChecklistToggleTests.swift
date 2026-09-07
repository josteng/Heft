import Foundation
import HeftCore
import Testing

/// Advancing each selected line's checkbox one step, the way Obsidian's
/// "Toggle checkbox status" does.
@Suite("Checkbox toggle")
struct ChecklistToggleTests {

    private func toggled(_ source: String, _ range: NSRange? = nil) -> String {
        let whole = range ?? NSRange(location: 0, length: (source as NSString).length)
        return MarkdownEditing.toggleChecklist(in: source, range: whole).applied(to: source)
    }

    @Test("Bullets become tasks")
    func bulletsBecomeTasks() {
        #expect(toggled("- milk\n- bread\n") == "- [ ] milk\n- [ ] bread\n")
    }

    @Test("An unchecked box becomes checked")
    func uncheckedBecomesChecked() {
        #expect(toggled("- [ ] milk\n") == "- [x] milk\n")
    }

    @Test("A checked box goes back to unchecked")
    func checkedBecomesUnchecked() {
        #expect(toggled("- [x] milk\n") == "- [ ] milk\n")
    }

    @Test("Nothing ever loses its box")
    func boxesAreNeverRemoved() {
        // Obsidian's rule, and the reason the command is safe to repeat: the
        // state is a cycle of two after the first press, so holding the key
        // cannot destroy the list you just made.
        var text = "- milk\n"
        for _ in 0..<6 {
            text = toggled(text)
            #expect(text.contains("["), "a box was removed: \(text)")
        }
    }

    @Test("Each line advances on its own")
    func linesAdvanceIndependently() {
        // A mixed selection needs no rule about what "all of them" means.
        #expect(
            toggled("- milk\n- [ ] bread\n- [x] eggs\n")
                == "- [ ] milk\n- [x] bread\n- [ ] eggs\n"
        )
    }

    @Test("Indentation and the marker are left exactly as they were")
    func nestingSurvives() {
        // Rebuilt from the original characters, not from a count: a tab put
        // back as spaces moves a nested item under a parser counting columns.
        #expect(
            toggled("- top\n\t- nested\n  * starred\n")
                == "- [ ] top\n\t- [ ] nested\n  * [ ] starred\n"
        )
    }

    @Test("A numbered list keeps its numbers")
    func numbersSurvive() {
        #expect(toggled("1. first\n2) second\n") == "1. [ ] first\n2) [ ] second\n")
    }

    @Test("A plain paragraph gains a bullet as well as a box")
    func paragraphGainsAMarker() {
        // A checkbox with no bullet in front of it is not a task to any
        // Markdown parser, so asking for one has to make the whole item.
        #expect(toggled("buy milk\n") == "- [ ] buy milk\n")
    }

    @Test("A blank line inside the selection stays blank")
    func blankLinesAreSkipped() {
        #expect(toggled("- milk\n\n- bread\n") == "- [ ] milk\n\n- [ ] bread\n")
    }

    @Test("A quoted list keeps its quote marker")
    func quotesSurvive() {
        #expect(toggled("> - milk\n") == "> - [ ] milk\n")
    }

    @Test("A capital X counts as checked")
    func capitalXIsChecked() {
        #expect(toggled("- [X] shouted\n") == "- [ ] shouted\n")
    }

    @Test("Only the selected lines change")
    func onlyTheSelectionChanges() {
        let source = "- milk\n- bread\n- eggs\n"
        // The first line alone.
        #expect(toggled(source, NSRange(location: 0, length: 3)) == "- [ ] milk\n- bread\n- eggs\n")
    }

    @Test("A line with nothing on it is left alone entirely")
    func emptySelectionDoesNothing() {
        #expect(toggled("\n") == "\n")
    }

    @Test("The last line without a trailing newline still converts")
    func lastLineWithoutANewline() {
        #expect(toggled("- milk") == "- [ ] milk")
    }

    @Test("The palette command reaches the editor through the model")
    func paletteCommandGoesThroughTheModel() throws {
        // Not down the responder chain: the palette holds the keyboard while
        // it is open, so a sent action reaches its own search field and stops
        // there, and the command silently did nothing.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/AppCommands.swift"),
            encoding: .utf8
        )
        #expect(source.contains("action: { $0.toggleChecklist() }"))
        #expect(!source.contains("formatChecklist"), "sendAction cannot reach the text view")
    }

    // MARK: - Where the caret ends up

    private func caret(_ source: String, at location: Int) -> Int {
        MarkdownEditing.toggleChecklist(
            in: source, range: NSRange(location: location, length: 0)
        ).selection.location
    }

    @Test("The caret keeps its place in the words, not the top of the block")
    func caretStaysInTheText() {
        // Ticking something off must not cost you your place in the sentence
        // beside it, which is the whole point of having a keystroke for it.
        let source = "- milk\n"
        // Caret after "mi", which is offset 4 in "- milk".
        #expect(caret(source, at: 4) == 8, "the box adds four characters before it")
    }

    @Test("A caret already past a box does not move when the box only changes")
    func caretStillWhenNothingGrows() {
        // `[ ]` to `[x]` is the same length, so nothing should move at all.
        #expect(caret("- [ ] milk\n", at: 8) == 8)
    }

    @Test("A caret in a paragraph moves past the marker it just gained")
    func caretAfterAMadeMarker() {
        // A plain line grows "- [ ] ", six characters, all of them before
        // the caret, because there was no marker for it to sit inside.
        #expect(caret("buy milk\n", at: 1) == 7)
    }

    @Test("A caret inside the bullet stays inside the bullet")
    func caretBeforeTheBoxDoesNotMove() {
        #expect(caret("- milk\n", at: 1) == 1)
    }

    @Test("With no selection only the caret's own line changes")
    func caretLineOnly() {
        // Obsidian ticks the line you are on, not the paragraph around it.
        let source = "- milk\n- bread\n"
        let edit = MarkdownEditing.toggleChecklist(
            in: source, range: NSRange(location: 9, length: 0)
        )
        #expect(edit.applied(to: source) == "- milk\n- [ ] bread\n")
        // Offset 9 is on "bread"; its own line grew by four and the line
        // above was never touched.
        #expect(edit.selection.location == 13)
    }

    @Test("Selecting several lines counts every line above the caret")
    func caretCountsTheLinesAbove() {
        let source = "- milk\n- bread\n"
        let edit = MarkdownEditing.toggleChecklist(
            in: source, range: NSRange(location: 0, length: 15)
        )
        let after = edit.applied(to: source) as NSString
        #expect(after as String == "- [ ] milk\n- [ ] bread\n")
        // The selection still covers everything it covered before.
        #expect(after.substring(with: edit.selection) == after as String)
    }

    @Test("A selection still covers the same words afterwards")
    func selectionSurvives() {
        let source = "- milk\n"
        let edit = MarkdownEditing.toggleChecklist(
            in: source, range: NSRange(location: 2, length: 4)
        )
        let after = edit.applied(to: source) as NSString
        #expect(after.substring(with: edit.selection) == "milk")
    }

    @Test("After the first press it cycles between the two states")
    func cyclesAfterTheFirstPress() {
        let source = "- top\n\t- nested\n1. numbered\n"
        let once = toggled(source)
        #expect(once == "- [ ] top\n\t- [ ] nested\n1. [ ] numbered\n")
        #expect(toggled(once) == "- [x] top\n\t- [x] nested\n1. [x] numbered\n")
        #expect(toggled(toggled(once)) == once)
    }
}
