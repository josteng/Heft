import Foundation
import Testing
@testable import HeftCore

/// The phone's quote and indent buttons. A Windows note's blank line is `\r`
/// once split on `\n`, and has to read as blank all the same.
@Suite("Quote and indent over a block of lines")
struct LineBlockEditingTests {

    private func applied(_ edit: MarkdownEditing.Edit, to source: String) -> String {
        (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func all(_ source: String) -> NSRange {
        NSRange(location: 0, length: (source as NSString).length)
    }

    @Test("Quoting leaves a blank line blank, in either line ending")
    func quoteSkipsBlankLines() {
        let unix = "a\n\nb\n"
        let quoted = MarkdownEditing.toggleQuote(in: unix, range: all(unix))
        #expect(applied(quoted, to: unix) == "> a\n\n> b\n")
        #expect(quoted.selection == NSRange(location: 2, length: 5))

        let windows = "a\r\n\r\nb\r\n"
        #expect(applied(MarkdownEditing.toggleQuote(in: windows, range: all(windows)), to: windows)
            == "> a\r\n\r\n> b\r\n")
    }

    @Test("A quoted Windows block with a blank line unquotes")
    func unquoteAcrossABlankWindowsLine() {
        let windows = "> a\r\n\r\n> b\r\n"
        let edit = MarkdownEditing.toggleQuote(in: windows, range: all(windows))
        #expect(applied(edit, to: windows) == "a\r\n\r\nb\r\n")
        #expect(edit.selection.location == 0)
    }

    @Test("Indenting skips a blank Windows line and outdenting keeps the breaks")
    func indentAndOutdent() {
        let windows = "- a\r\n\r\n- b\r\n"
        let indented = applied(
            MarkdownEditing.shiftLines(in: windows, range: all(windows), outdent: false), to: windows
        )
        #expect(indented == "\t- a\r\n\r\n\t- b\r\n")
        let outdented = applied(
            MarkdownEditing.shiftLines(in: indented, range: all(indented), outdent: true), to: indented
        )
        #expect(outdented == windows)
    }

    @Test("A tab on the blank line Return just made lands at the caret")
    func tabOnTheNewLine() {
        // Spaces the line already has stay in front of the tab.
        let windows = "- a\r\n  \r\n"
        let edit = MarkdownEditing.shiftLines(
            in: windows, range: NSRange(location: 7, length: 0), outdent: false
        )
        #expect(applied(edit, to: windows) == "- a\r\n  \t\r\n")
        #expect(edit.selection == NSRange(location: 8, length: 0))
    }
}
