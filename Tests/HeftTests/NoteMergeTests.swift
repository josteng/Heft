import Foundation
import Testing
@testable import HeftCore

@Suite("Three-way merge of a note")
struct NoteMergeTests {

    private func merge(_ base: String, _ mine: String, _ theirs: String) -> String? {
        NoteMerge.merge(base: base, mine: mine, theirs: theirs)
    }

    @Test("An append below a line being edited keeps both")
    func appendBelowAnEdit() {
        let base = "# Today\n\nwrite the plan\n"
        #expect(merge(base, "# Today\n\nwrite the plan, then send it\n", base + "- 10:00 call\n")
            == "# Today\n\nwrite the plan, then send it\n- 10:00 call\n")
    }

    @Test("Edits at the top and an append at the end are disjoint")
    func disjointEnds() {
        #expect(merge("A\nB\nC\n", "A typed\nB\nC\n", "A\nB\nC\nD\n") == "A typed\nB\nC\nD\n")
    }

    @Test("An insertion in the middle lands between untouched lines")
    func insertionInTheMiddle() {
        let base = "# Day\n\n## Log\n<!-- heft:daily-log -->\n\n## Notes\nfirst\n"
        let theirs = "# Day\n\n## Log\n- 09:00 stand-up\n<!-- heft:daily-log -->\n\n## Notes\nfirst\n"
        let mine = "# Day\n\n## Log\n<!-- heft:daily-log -->\n\n## Notes\nfirst\nsecond\n"
        #expect(merge(base, mine, theirs)
            == "# Day\n\n## Log\n- 09:00 stand-up\n<!-- heft:daily-log -->\n\n## Notes\nfirst\nsecond\n")
    }

    @Test("Both sides changing one line is a conflict")
    func sameLineConflicts() {
        #expect(merge("A\nB\nC\n", "A\nmine\nC\n", "A\ntheirs\nC\n") == nil)
    }

    @Test("A line deleted on one side and edited on the other is a conflict")
    func deleteAgainstEdit() {
        #expect(merge("A\nB\nC\n", "A\nC\n", "A\nB edited\nC\n") == nil)
    }

    @Test("An insertion inside a rewritten region is a conflict")
    func insertionInsideARewrite() {
        #expect(merge("A\nB\nC\nD\n", "A\nX\nY\nD\n", "A\nB\nnew\nC\nD\n") == nil)
        #expect(merge("A\nB\nC\nD\n", "A\nB\nnew\nC\nD\n", "A\nX\nY\nD\n") == nil)
    }

    @Test("An insertion just above a changed line goes above it")
    func insertionAboveAChange() {
        #expect(merge("A\nB\n", "A\nnew\nB\n", "A\nB edited\n") == "A\nnew\nB edited\n")
        #expect(merge("A\nB\n", "A\nB edited\n", "A\nnew\nB\n") == "A\nnew\nB edited\n")
    }

    @Test("Two insertions at one point keep both, theirs first")
    func insertionsAtOnePoint() {
        // The reader is typing a new last line while a capture is appended.
        #expect(merge("prev\n", "prev\nhalf a sent", "prev\n- 10:00 call\n")
            == "prev\n- 10:00 call\nhalf a sent")
    }

    @Test("The same change on both sides is made once")
    func identicalChanges() {
        #expect(merge("A\nB\n", "A\nB\nC\n", "A\nB\nC\n") == "A\nB\nC\n")
        #expect(merge("A\nB\nC\n", "A\nX\nC\nmine\n", "A\nX\nC\n") == "A\nX\nC\nmine\n")
    }

    @Test("An unchanged side gives the other side's text exactly")
    func oneSideUnchanged() {
        #expect(merge("A\n", "A\n", "A\r\nB") == "A\r\nB")
        #expect(merge("A\n", "B", "A\n") == "B")
    }

    @Test("CRLF lines keep their endings")
    func crlf() {
        #expect(merge("A\r\nB\r\n", "A typed\r\nB\r\n", "A\r\nB\r\n- 10:00 call\r\n")
            == "A typed\r\nB\r\n- 10:00 call\r\n")
    }

    @Test("A mixed-ending note is merged without normalising it")
    func mixedEndings() {
        #expect(merge("A\r\nB\nC\n", "A\r\nB\nC typed\n", "A\r\nB\nC\nD\n")
            == "A\r\nB\nC typed\nD\n")
        #expect(merge("A\r\nB\nC\n", "A typed\r\nB\nC\n", "A\r\nB\nC\nD\r\n")
            == "A typed\r\nB\nC\nD\r\n")
    }

    @Test("An append after an unfinished last line does not conflict with typing on it")
    func noTrailingNewline() {
        // A capture adds the missing newline before its line.
        #expect(merge("A\nlast", "A\nlast typed", "A\nlast\n- 10:00 call\n")
            == "A\nlast typed\n- 10:00 call\n")
        #expect(merge("A\r\nlast", "A\r\nlast typed", "A\r\nlast\r\n- 10:00 call\r\n")
            == "A\r\nlast typed\r\n- 10:00 call\r\n")
    }

    @Test("A missing final newline stays missing")
    func finalNewlineIsKept() {
        // Untouched last line: neither side changed whether it ends.
        #expect(merge("A\nB", "A typed\nB", "A\nB") == "A typed\nB")
        #expect(merge("A\nB\nC", "A typed\nB\nC", "A\nB edited\nC") == "A typed\nB edited\nC")
        // Mine dropped the newline at the end; theirs edited the top.
        #expect(merge("A\nB\nC\n", "A\nB\nC", "X\nB\nC\n") == "X\nB\nC")
        // Mine deleted the last line and left the one before unfinished.
        #expect(merge("x\na\nb\n", "x\na", "X\na\nb\n") == "X\na")
    }

    @Test("An empty base takes both sides' lines")
    func emptyBase() {
        #expect(merge("", "mine", "- 10:00 call\n") == "- 10:00 call\nmine")
        #expect(merge("", "", "theirs\n") == "theirs\n")
    }

    @Test("Emptying the note keeps a line appended after it")
    func emptiedAgainstAppend() {
        // Deleting every line and adding one after them touch, not overlap;
        // rewriting a line that was deleted does.
        #expect(merge("A\n", "", "A\nB\n") == "B\n")
        #expect(merge("A\nB\n", "", "A\nX\n") == nil)
    }

    @Test("Unicode lines compare and survive whole")
    func unicode() {
        let base = "Grüße 👋🏽\n日本語\n"
        #expect(merge(base, "Grüße 👋🏽 an alle\n日本語\n", base + "- 10:00 Café ☕️\n")
            == "Grüße 👋🏽 an alle\n日本語\n- 10:00 Café ☕️\n")
        #expect(merge(base, "Grüße 👋🏽\n日本語です\n", "Grüße 👋🏽\n中文\n") == nil)
    }
}
