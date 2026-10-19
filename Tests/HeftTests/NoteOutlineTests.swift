import Foundation
import Testing
@testable import HeftCore

/// The outline beside a note: its headings, how far in each sits, and which
/// one a position is under.
@Suite("Note outline")
struct NoteOutlineTests {

    private func titles(_ source: String) -> [String] {
        NoteOutline(source: source).entries.map(\.title)
    }

    @Test("Headings in order, with 1-based lines and their offsets")
    func headingsInOrder() {
        let source = "intro\n# One\ntext\n## Two\n"
        let entries = NoteOutline(source: source).entries
        #expect(entries.map(\.title) == ["One", "Two"])
        #expect(entries.map(\.level) == [1, 2])
        #expect(entries.map(\.line) == [2, 4])
        let text = source as NSString
        #expect(entries.map(\.offset) == [text.range(of: "# One").location, text.range(of: "## Two").location])
    }

    /// The outline shows what the surface draws, and a `#` in a code sample
    /// or the YAML is drawn as neither.
    @Test("Fences, frontmatter and tags are not headings")
    func notHeadings() {
        let source = """
        ---
        # a YAML comment
        tags: [a]
        ---
        #tag on its own
        ```sh
        # a shell comment
        ```
        # Real
        """
        #expect(titles(source) == ["Real"])
    }

    @Test("Frontmatter that never closes is text, as the surface draws it")
    func unclosedFrontmatter() {
        #expect(titles("---\n# Heading\nmore") == ["Heading"])
        #expect(titles("---\n---\n# After") == ["After"])
    }

    @Test("Setext headings count, under the decorator's rules")
    func setext() {
        #expect(titles("Title\n===\n\nPart\n---\n") == ["Title", "Part"])
        #expect(NoteOutline(source: "Part\n--").entries.first?.level == 2)
        // A blank line above makes it a rule, a single dash starts a list,
        // and a list item cannot carry one.
        #expect(titles("\n---\n").isEmpty)
        #expect(titles("Text\n-").isEmpty)
        #expect(titles("- item\n---").isEmpty)
    }

    /// The decorator is what the reader sees, so the two have to agree on
    /// which lines are headings.
    @Test("Agrees with the live surface")
    func agreesWithDecorator() {
        let source = """
        ---
        title: x
        ---
        # One
        Two
        ===
        - list
        ---
        Three
        --
        ```
        # code
        ```
        ###### Six
        > ## quoted
        """
        let text = source as NSString
        let drawn = LiveDecorator.decorations(in: source).compactMap { decoration -> Int? in
            guard case .heading = decoration.style else { return nil }
            return text.lineRange(for: NSRange(location: decoration.range.location, length: 0)).location
        }
        // The decorator finds `#` headings before underlined ones.
        #expect(NoteOutline(source: source).entries.map(\.offset) == drawn.sorted())
        #expect(drawn.count == 4)
    }

    @Test("Titles lose their markup")
    func plainTitles() {
        #expect(titles("## **Bold** and [[Note|alias]] `code` ##") == ["Bold and alias code"])
    }

    /// A note that starts at `##` would otherwise open with an empty column,
    /// and a jump from `#` to `###` would leave a gap.
    @Test("Depth counts the headings above, not the hashes")
    func depth() {
        let entries = NoteOutline(source: "## A\n#### B\n### C\n## D\n# E\n### F").entries
        #expect(entries.map(\.depth) == [0, 1, 1, 0, 0, 1])
    }

    @Test("A position falls under the last heading at or before it")
    func containing() {
        let source = "intro\n# One\ntext\n## Two\nmore"
        let outline = NoteOutline(source: source)
        let text = source as NSString
        #expect(outline.index(containing: 0) == nil)
        #expect(outline.index(containing: text.range(of: "# One").location) == 0)
        #expect(outline.index(containing: text.range(of: "text").location) == 0)
        #expect(outline.index(containing: text.range(of: "## Two").location) == 1)
        #expect(outline.index(containing: text.length) == 1)
        #expect(NoteOutline.empty.index(containing: 5) == nil)
    }

    @Test("Offsets count UTF-16, as the editor does, and survive Windows returns")
    func offsets() {
        let source = "😀 é\r\n# Heading\r\nText\r\n---\r\n"
        let entries = NoteOutline(source: source).entries
        #expect(entries.map(\.title) == ["Heading", "Text"])
        #expect(entries.first?.offset == (source as NSString).range(of: "# Heading").location)
    }
}
