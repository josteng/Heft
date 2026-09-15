import Foundation
import HeftCore
import Testing

/// Bold, italic and the other wrapping formats applied to a selection that
/// starts before a line's own markup: a list marker, a checkbox, a quote or a
/// heading. The markers go around the words, never around the `- `.
@Suite("Formatting keeps line markers outside")
struct FormattingLinePrefixTests {

    private func bold(_ source: String, _ range: NSRange? = nil) -> String {
        let whole = range ?? NSRange(location: 0, length: (source as NSString).length)
        return MarkdownEditing.toggle(.bold, in: source, range: whole).applied(to: source)
    }

    @Test("Bullets across lines are bolded after their markers")
    func bulletsAcrossLines() {
        #expect(bold("- fd\n- asf\n- asdf") == "- **fd**\n- **asf**\n- **asdf**")
    }

    @Test("A selection starting mid-line keeps its start on the first line")
    func midLineStart() {
        #expect(bold("dfas\n- fd", NSRange(location: 2, length: 7)) == "df**as**\n- **fd**")
    }

    @Test("Numbered items and tasks keep their markers and boxes outside")
    func numberedAndTasks() {
        #expect(bold("1. one\n- [ ] two\n- [x] three") == "1. **one**\n- [ ] **two**\n- [x] **three**")
    }

    @Test("Quotes and headings keep their markers outside")
    func quotesAndHeadings() {
        #expect(bold("> quoted\n# Title\n  - nested") == "> **quoted**\n# **Title**\n  - **nested**")
    }

    @Test("A line that is only a marker gets no empty pair")
    func markerOnlyLine() {
        #expect(bold("- one\n- \n- two") == "- **one**\n- \n- **two**")
    }

    @Test("A whole bullet selected on its own is bolded after its marker")
    func singleLineWithMarker() {
        #expect(bold("- asdf") == "- **asdf**")
    }

    @Test("A selection inside the words is left exactly where it is")
    func selectionInsideWords() {
        #expect(bold("- asdf", NSRange(location: 3, length: 2)) == "- a**sd**f")
    }

    @Test("Toggling again takes the formatting back off")
    func roundTrip() {
        let source = "- fd\n1. asf\n> - [ ] asdf"
        let whole = NSRange(location: 0, length: (source as NSString).length)
        let on = MarkdownEditing.toggle(.bold, in: source, range: whole)
        let bolded = on.applied(to: source)
        #expect(bolded == "- **fd**\n1. **asf**\n> - [ ] **asdf**")
        #expect(MarkdownEditing.toggle(.bold, in: bolded, range: on.selection).applied(to: bolded) == source)
    }
}
