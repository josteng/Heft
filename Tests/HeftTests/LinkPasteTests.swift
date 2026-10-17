import AppKit
import HeftCore
import Testing
@testable import Heft

/// A web address pasted over selected words links them to it.
@Suite("Pasting a link over a selection")
struct LinkPasteTests {

    @Test("An address over words becomes a link")
    func wrapsSelection() {
        #expect(MarkdownEditing.linkPasting("https://example.com", over: "the site")
            == "[the site](https://example.com)")
        #expect(MarkdownEditing.linkPasting("  https://example.com/a?b=c\n", over: "**bold**")
            == "[**bold**](https://example.com/a?b=c)")
        #expect(MarkdownEditing.linkPasting("mailto:user@example.com", over: "write")
            == "[write](mailto:user@example.com)")
    }

    @Test("Brackets in the address are kept whole")
    func anglesAroundParentheses() {
        #expect(MarkdownEditing.linkPasting("https://example.org/wiki/A_(b)", over: "A")
            == "[A](<https://example.org/wiki/A_(b)>)")
    }

    @Test("Anything else is an ordinary paste")
    func ordinaryPastes() {
        #expect(MarkdownEditing.linkPasting("https://example.com", over: "") == nil)
        #expect(MarkdownEditing.linkPasting("plain words", over: "text") == nil)
        #expect(MarkdownEditing.linkPasting("example.com", over: "text") == nil)
        #expect(MarkdownEditing.linkPasting("todo:fix", over: "text") == nil)
        #expect(MarkdownEditing.linkPasting("mailto:", over: "text") == nil)
        #expect(MarkdownEditing.linkPasting("https://example.com and more", over: "text") == nil)
        #expect(MarkdownEditing.linkPasting("https://example.com", over: "two\nlines") == nil)
        #expect(MarkdownEditing.linkPasting("https://example.com", over: "https://example.net") == nil)
    }

    @MainActor
    @Test("The editor links the selection and leaves the caret after it")
    func editorLinksSelection() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.string = "See the site now"
        view.setSelectedRange(NSRange(location: 4, length: 8))
        #expect(view.insertLinkPaste("https://example.com"))
        #expect(view.string == "See [the site](https://example.com) now")
        #expect(view.selectedRange() == NSRange(location: 35, length: 0))

        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!view.insertLinkPaste("https://example.com"))
    }
}
