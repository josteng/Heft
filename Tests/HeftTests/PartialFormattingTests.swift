import Foundation
import HeftCore
import Testing

/// Toggling a format on a selection that is already partly formatted: one
/// span comes out, never markers nested inside markers.
@Suite("Formatting text that is partly formatted")
struct PartialFormattingTests {

    /// Applies `format` to the first occurrence of `selected` in `source`, and
    /// returns the result with the new selection in brackets.
    private func toggle(_ format: InlineFormat, _ source: String, selecting selected: String) -> String {
        let range = (source as NSString).range(of: selected)
        let edit = MarkdownEditing.toggle(format, in: source, range: range)
        let result = edit.applied(to: source) as NSString
        return result.replacingCharacters(
            in: edit.selection, with: "[" + result.substring(with: edit.selection) + "]"
        )
    }

    @Test("A selection around a bold span becomes one bold span")
    func mergesAroundASpan() {
        #expect(toggle(.bold, "x **bold** y", selecting: "x **bold** y") == "**[x bold y]**")
        #expect(toggle(.bold, "a **b** c **d** e", selecting: "a **b** c **d** e") == "**[a b c d e]**")
    }

    @Test("A selection reaching into a span extends it")
    func extendsAnOverlappedSpan() {
        #expect(toggle(.bold, "**bo**ld", selecting: "**bo**ld") == "**[bold]**")
        #expect(toggle(.bold, "**bold** y", selecting: "ld** y") == "**[bold y]**")
        #expect(toggle(.italic, "_it_ more", selecting: "it_ more") == "*[it more]*")
    }

    @Test("Part of a span loses the format and the rest keeps it")
    func splitsASpan() {
        #expect(toggle(.bold, "**bold**", selecting: "ol") == "**b**[ol]**d**")
        #expect(toggle(.bold, "**bold**", selecting: "bo") == "[bo]**ld**")
        #expect(toggle(.bold, "**one two**", selecting: "two") == "**one** [two]")
    }

    @Test("A coloured highlight keeps its colour on both sides of a cut")
    func highlightColourSurvives() {
        #expect(toggle(.highlight, "==🔴abc==", selecting: "b") == "==🔴a==[b]==🔴c==")
        #expect(toggle(.highlight, "==🔴ab== cd", selecting: "b== cd") == "==🔴[ab cd]==")
        #expect(toggle(.highlight, "==🔴word==", selecting: "word") == "[word]")
    }

    @Test("Plain and fully formatted selections behave as before")
    func unchangedCases() {
        #expect(toggle(.bold, "plain", selecting: "plain") == "**[plain]**")
        #expect(toggle(.bold, "**bold**", selecting: "bold") == "[bold]")
        #expect(toggle(.bold, "**bold**", selecting: "**bold**") == "[bold]")
        #expect(toggle(.bold, "x **b** y\nz", selecting: "x **b** y\nz") == "[**x b y**\n**z**]")
    }
}
