import Foundation
import Testing
@testable import HeftCore

/// `Text` with `===` under it is an H1 and with `---` under it an H2. It is
/// CommonMark, so it is what Obsidian shows, and without it a note written
/// that way loses its headings and gains a rule across the page instead.
@Suite("Setext headings")
struct SetextHeadingTests {

    private func headings(_ document: String) -> [(level: Int, text: String, syntax: [NSRange])] {
        let source = document as NSString
        return LiveDecorator.decorations(in: document).compactMap { decoration in
            guard case .heading(let level) = decoration.style else { return nil }
            return (level, source.substring(with: decoration.range), decoration.syntax)
        }
    }

    private func rules(_ document: String) -> Int {
        LiveDecorator.decorations(in: document).filter { decoration in
            if case .thematicBreak = decoration.style { return true }
            return false
        }.count
    }

    @Test("Dashes under a line make it an H2")
    func dashesAreLevelTwo() {
        let found = headings("Heading text\n---\n")
        #expect(found.count == 1)
        #expect(found.first?.level == 2)
        #expect(found.first?.text == "Heading text\n---")
    }

    @Test("Equals under a line make it an H1")
    func equalsAreLevelOne() {
        #expect(headings("Title\n===\n").first?.level == 1)
    }

    /// The underline collapses like any other block marker, so the reader sees
    /// the heading rather than the scaffolding that made it one.
    @Test("The underline is hidden, and the text is not")
    func hidesOnlyTheUnderline() {
        let syntax = headings("Heading text\n---\n").first?.syntax
        #expect(syntax?.count == 1)
        // "Heading text\n" is 13 characters, then the three dashes.
        #expect(syntax?.first == NSRange(location: 13, length: 3))
    }

    /// A rule stands alone. Only text *directly* above turns it into a heading.
    @Test("Dashes after a blank line are still a rule")
    func blankLineKeepsTheRule() {
        #expect(headings("body\n\n---\n\nafter\n").isEmpty)
        #expect(rules("body\n\n---\n\nafter\n") == 1)
    }

    /// Setext wins over the thematic break for the same characters, which is
    /// what CommonMark says and why it has to be matched first.
    @Test("A line that became a heading is not also a rule")
    func headingIsNotAlsoARule() {
        #expect(rules("Heading text\n---\n") == 0)
    }

    @Test("Frontmatter is not a heading")
    func frontmatterIsLeftAlone() {
        #expect(headings("---\ntitle: x\n---\n\nbody\n").isEmpty)
    }

    /// A line that opens a block of its own is that block, not heading text
    /// waiting for an underline.
    @Test("A line that is already a block is not underlined into a heading")
    func blocksAreNotContent() {
        #expect(headings("- item\n---\n").count == 0)
        #expect(headings("> quote\n---\n").count == 0)
        #expect(headings("1. one\n---\n").count == 0)
        // An ATX heading is still its own heading, just not a setext one.
        let atx = headings("# ATX\n---\n")
        #expect(atx.count == 1)
        #expect(atx.first?.text == "# ATX")
    }

    /// A deliberate divergence from CommonMark, which accepts a single `-`.
    /// Honouring that would turn the line above into a heading the instant the
    /// `-` of a list item was typed, on every list started under a paragraph.
    @Test("A single dash is a list being typed, not an underline")
    func singleDashIsNotAnUnderline() {
        #expect(headings("Some text\n-\n").isEmpty)
        #expect(headings("Some text\n--\n").count == 1)
    }
}
