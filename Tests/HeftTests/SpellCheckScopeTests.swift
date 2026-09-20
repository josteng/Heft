import Foundation
import Testing
@testable import HeftCore

/// Which spans the spell checker may mark. The interesting half is what stays
/// checked: the buffer is the file, so prose and source sit in one string and
/// excluding too much is as wrong as excluding nothing.
@Suite("Spell check scope")
struct SpellCheckScopeTests {

    private func exclusions(_ document: String) -> [NSRange] {
        SpellCheckScope.exclusions(for: LiveDecorator.decorations(in: document), in: document as NSString)
    }

    /// Every excluded span, as the text it covers.
    private func excluded(_ document: String) -> [String] {
        let source = document as NSString
        return exclusions(document).map { source.substring(with: $0) }
    }

    /// Whether the first occurrence of `word` would be underlined.
    private func checks(_ word: String, in document: String) -> Bool {
        let range = (document as NSString).range(of: word)
        #expect(range.location != NSNotFound, "\(word) is not in the document")
        return !SpellCheckScope.excludes(range, in: exclusions(document))
    }

    // MARK: - What a dictionary has no business reading

    @Test("An inline code span is not checked")
    func inlineCode() {
        let document = "Call `someIdentifier` when ready."
        #expect(excluded(document) == ["`someIdentifier`"])
        #expect(!checks("someIdentifier", in: document))
    }

    @Test("A fenced block is not checked, language line included")
    func fencedCode() {
        let document = """
        Before.

        ```swift
        let recieve = thatIsNotAWord()
        ```
        """
        #expect(!checks("recieve", in: document))
        #expect(!checks("thatIsNotAWord", in: document))
    }

    @Test("A tag is not checked")
    func tag() {
        let document = "Filed under #projekt today."
        #expect(excluded(document) == ["#projekt"])
        #expect(!checks("projekt", in: document))
    }

    @Test("Frontmatter is not checked")
    func frontmatter() {
        let document = """
        ---
        aliases: zettel
        ---

        Body text.
        """
        #expect(!checks("zettel", in: document))
        #expect(checks("Body", in: document))
    }

    @Test("Math is not checked, inline or block")
    func math() {
        #expect(!checks("alpha", in: "An $\\alpha$ here."))
        #expect(!checks("alpha", in: "Block:\n\n$$\n\\alpha + \\beta\n$$\n"))
    }

    // MARK: - What stays checked

    /// The regression that would make the feature pointless. Emphasis hides its
    /// markers but the word between them is prose, and a typo in it is a typo.
    @Test("A word inside emphasis is still checked")
    func emphasisStaysChecked() {
        #expect(checks("recieve", in: "A **recieve** here."))
        #expect(checks("occured", in: "An *occured* here."))
        #expect(checks("occured", in: "A ~~occured~~ here."))
        #expect(checks("recieve", in: "A ==recieve== here."))
    }

    @Test("Headings, quotes and list items are checked")
    func structureStaysChecked() {
        #expect(checks("recieve", in: "# A recieve heading"))
        #expect(checks("recieve", in: "> A recieve quote"))
        #expect(checks("recieve", in: "- A recieve item"))
    }

    /// A link's label is prose whatever its destination is, and an aliased
    /// wikilink shows its alias.
    @Test("Link labels are checked and destinations are not")
    func linkLabelsStayChecked() {
        #expect(checks("recieve", in: "A [recieve label](https://example.com/path) here."))
        #expect(!checks("speling", in: "A [label](notes/speling-guide.md) here."))
        #expect(checks("recieve", in: "A [[recieve target]] here."))
        #expect(checks("Recieve", in: "A [[some-target|Recieve Label]] here."))
        #expect(!checks("targt", in: "A [[some-targt|Nice Label]] here."))
    }

    /// Not by style but by being hidden whole: both are drawn as something
    /// other than their text, so there is nowhere for an underline to go.
    @Test("A comment and an image's alt text are not checked")
    func hiddenWholeIsNotChecked() {
        #expect(!checks("recieve", in: "Text %%a recieve note%% more."))
        #expect(!checks("textt", in: "An ![alt textt](img/pic.png) image."))
    }

    /// The label constructs: a name the document refers to itself by, not a
    /// word. The prose after a definition's colon is still prose.
    @Test("Footnote and reference labels are not checked")
    func labelsAreNotChecked() {
        let footnote = "A footnote[^fnlabl] here.\n\n[^fnlabl]: The deliberate prose.\n"
        #expect(!checks("fnlabl", in: footnote))
        #expect(checks("prose", in: footnote))
        #expect(!checks("reflabl", in: "[reflabl]: https://example.com/x \"Title\"\n"))
    }

    /// A table is one decoration, so nothing inside it is seen unless the cell
    /// is decorated in its own right.
    @Test("Code and tags inside a table cell are not checked")
    func tableCells() {
        let document = "| a | b |\n|---|---|\n| `codeInCell` | #tagInCell |\n"
        #expect(!checks("codeInCell", in: document))
        #expect(!checks("tagInCell", in: document))
        #expect(checks("a", in: document))
    }

    /// Prose in a cell is still prose, which is what stops the table rule from
    /// being "skip the table".
    @Test("Prose inside a table cell is checked")
    func tableProse() {
        let document = "| Head |\n|---|\n| A recieve cell |\n"
        #expect(checks("recieve", in: document))
    }

    /// A bare URL needs no rule: macOS leaves URL-shaped text alone itself,
    /// which is worth recording so the rule is not added back speculatively.
    @Test("A bare URL is left to macOS")
    func bareURL() {
        #expect(exclusions("See https://example.com/bad-speling/path here.").isEmpty)
    }

    // MARK: - The range arithmetic

    /// Sorting is not defensive: the decorator reports a tag after the code
    /// span that follows it, so the list arrives out of document order and a
    /// binary search over it would miss.
    @Test("Exclusions come back in document order")
    func sorted() {
        // A tag before a code span comes back after it, so the list really is
        // out of order, and the two are far enough apart that merging them
        // would swallow the sentence in between.
        let document = "#alpha then some plain prose words then `beta` end."
        let raw = LiveDecorator.decorations(in: document)
            .filter { SpellCheckScope.isExcluded($0.style) }
            .map(\.range.location)
        #expect(raw != raw.sorted(), "this document no longer proves anything")

        let ranges = exclusions(document)
        #expect(ranges.map(\.location) == ranges.map(\.location).sorted())
        #expect(ranges.count == 2)
        #expect(!checks("alpha", in: document))
        #expect(!checks("beta", in: document))
        for word in ["then", "some", "plain", "prose", "words", "end"] {
            #expect(checks(word, in: document), "\(word) is prose and must stay checked")
        }
    }

    /// Merging is the invariant the binary search rests on, and today's
    /// decorator happens not to nest these styles: a fence swallows the tags
    /// inside it whole. Built by hand rather than parsed, so that a decorator
    /// that one day does report the inner span cannot quietly break the
    /// search: an unmerged overlap hides the outer range behind the inner one.
    @Test("Overlapping spans are merged into one")
    func merging() {
        let overlapping = [
            MarkdownDecoration(range: NSRange(location: 0, length: 30), style: .codeBlock(language: nil)),
            MarkdownDecoration(range: NSRange(location: 5, length: 4), style: .tag),
            MarkdownDecoration(range: NSRange(location: 25, length: 20), style: .inlineCode),
            MarkdownDecoration(range: NSRange(location: 60, length: 5), style: .tag),
        ]
        let merged = SpellCheckScope.exclusions(for: overlapping, in: String(repeating: "x", count: 80) as NSString)
        #expect(merged == [NSRange(location: 0, length: 45), NSRange(location: 60, length: 5)])
        // The outer span, which an unmerged list leaves unreachable.
        #expect(SpellCheckScope.excludes(NSRange(location: 1, length: 2), in: merged))
        #expect(SpellCheckScope.excludes(NSRange(location: 40, length: 2), in: merged))
        #expect(!SpellCheckScope.excludes(NSRange(location: 50, length: 2), in: merged))
    }

    /// A zero-length decoration would otherwise merge into a span it only
    /// touches, and marks nothing on its own.
    @Test("An empty span is dropped")
    func emptySpansDropped() {
        let ranges = SpellCheckScope.exclusions(
            for: [
                MarkdownDecoration(range: NSRange(location: 10, length: 0), style: .tag),
                MarkdownDecoration(range: NSRange(location: 20, length: 3), style: .tag),
            ],
            in: String(repeating: "x", count: 40) as NSString
        )
        #expect(ranges == [NSRange(location: 20, length: 3)])
    }

    /// A marker that cannot hold a word is not listed. Otherwise every `**`,
    /// `# ` and `> ` in the note would put a range in the list the checker
    /// binary searches on every misspelling, to suppress nothing.
    @Test("Markers with no letters in them are not listed")
    func letterlessMarkersAreNotListed() {
        let document = (0..<40)
            .map { "# Headng \($0)\n\n> A **bold** and *italic* ~~struck~~ line.\n" }
            .joined()
        #expect(exclusions(document).isEmpty)
    }

    /// Marking half a word is worse than marking none of it, so any overlap
    /// with an excluded span suppresses the whole mark.
    @Test("A word that only half overlaps an excluded span is suppressed")
    func partialOverlap() {
        let code = NSRange(location: 10, length: 10)
        #expect(SpellCheckScope.excludes(NSRange(location: 5, length: 8), in: [code]))
        #expect(SpellCheckScope.excludes(NSRange(location: 18, length: 8), in: [code]))
        #expect(!SpellCheckScope.excludes(NSRange(location: 0, length: 10), in: [code]))
        #expect(!SpellCheckScope.excludes(NSRange(location: 20, length: 5), in: [code]))
    }

    /// The binary search has to find a span wherever it sits in the list, and
    /// a linear-looking test with one span cannot show that.
    @Test("Every span in a long list is found")
    func findsAcrossTheList() {
        let document = (0..<64).map { "word\($0) `code\($0)`" }.joined(separator: " ")
        let ranges = exclusions(document)
        #expect(ranges.count == 64)
        for index in 0..<64 {
            #expect(!checks("code\(index)", in: document))
            #expect(checks("word\(index)", in: document))
        }
    }

    @Test("Nothing is excluded in a document with no source in it")
    func plainProse() {
        #expect(exclusions("Just a sentence, nothing more.").isEmpty)
        #expect(!SpellCheckScope.excludes(NSRange(location: 3, length: 4), in: []))
    }
}
