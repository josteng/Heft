import Foundation
import HeftCore
import Testing

/// CommonMark's four reference forms: the definition, and the full,
/// collapsed and shortcut references that point at it.
@Suite("Reference links")
struct ReferenceLinkTests {

    private func decorations(_ text: String) -> [MarkdownDecoration] {
        LiveDecorator.decorations(in: text)
    }

    private func links(_ text: String) -> [(text: String, destination: String)] {
        let ns = text as NSString
        return decorations(text).compactMap { decoration in
            guard case .link(let destination) = decoration.style else { return nil }
            return (ns.substring(with: decoration.range), destination)
        }
    }

    private func definitions(_ text: String) -> [String] {
        decorations(text).compactMap { decoration in
            guard case .referenceDefinition(let label) = decoration.style else { return nil }
            return label
        }
    }

    // MARK: - The definition

    @Test("A definition is recognised and keeps its label")
    func definitionIsFound() {
        #expect(definitions("[mdn]: https://example.com\n") == ["mdn"])
    }

    @Test("A definition with a title is still one definition")
    func definitionWithATitle() {
        for line in [
            "[mdn]: https://example.com \"The title\"\n",
            "[mdn]: https://example.com 'The title'\n",
            "[mdn]: https://example.com (The title)\n",
        ] {
            #expect(definitions(line) == ["mdn"], Comment(rawValue: line))
        }
    }

    @Test("A definition hides its brackets and colon and nothing else")
    func definitionHidesOnlyItsMarkup() {
        let text = "[mdn]: https://example.com\n"
        let decoration = decorations(text).first { decoration in
            if case .referenceDefinition = decoration.style { return true }
            return false
        }
        let hidden = (decoration?.syntax ?? []).reduce(0) { $0 + $1.length }
        // `[` and `]:`, three characters. The URL stays visible, or it could
        // not be checked without revealing the line.
        #expect(hidden == 3)
    }

    @Test("A URL in a definition is not eaten by the autolink matcher")
    func definitionOwnsItsURL() {
        // Ordering, not luck: the definition is matched and protected before
        // bare URLs are looked for.
        let text = "[mdn]: https://example.com\n"
        #expect(links(text).isEmpty)
        #expect(definitions(text) == ["mdn"])
    }

    // MARK: - The three references

    @Test("A full reference resolves to its definition")
    func fullReference() {
        let found = links("See [the docs][mdn] today.\n\n[mdn]: https://example.com\n")
        #expect(found.count == 1)
        #expect(found.first?.text == "[the docs][mdn]")
        #expect(found.first?.destination == "https://example.com")
    }

    @Test("A collapsed reference resolves to its definition")
    func collapsedReference() {
        let found = links("See [mdn][] today.\n\n[mdn]: https://example.com\n")
        #expect(found.count == 1)
        #expect(found.first?.destination == "https://example.com")
    }

    @Test("A shortcut reference resolves to its definition")
    func shortcutReference() {
        let found = links("See [mdn] today.\n\n[mdn]: https://example.com\n")
        #expect(found.count == 1)
        #expect(found.first?.text == "[mdn]")
        #expect(found.first?.destination == "https://example.com")
    }

    @Test("A definition below or above the reference both work")
    func orderDoesNotMatter() {
        let below = links("See [mdn].\n\n[mdn]: https://example.com\n")
        let above = links("[mdn]: https://example.com\n\nSee [mdn].\n")
        #expect(below.first?.destination == "https://example.com")
        #expect(above.first?.destination == "https://example.com")
    }

    @Test("Labels match case-insensitively, with whitespace normalised")
    func labelsAreNormalised() {
        // CommonMark's rule. Getting it wrong makes a link fail silently over
        // a capital letter, which reads as the feature being broken.
        let found = links("See [Read   More] today.\n\n[read more]: https://example.com\n")
        #expect(found.first?.destination == "https://example.com")
    }

    // MARK: - What must not become a link

    @Test("A bracketed aside with no definition stays prose")
    func undefinedBracketsAreLeftAlone() {
        // The whole reason this construct needs two passes.
        #expect(links("A sentence [with an aside] in it.\n").isEmpty)
    }

    @Test("An aside stays prose even in a note that defines other labels")
    func undefinedBracketsSurviveBesideDefinitions() {
        // The case the test above cannot reach: with a definition present
        // the reference matchers actually run, and the aside has to survive
        // them on its own merits rather than because nothing looked.
        let found = links(
            "See [mdn], but not [an aside] here.\n\n[mdn]: https://example.com\n"
        )
        #expect(found.count == 1)
        #expect(found.first?.text == "[mdn]")
    }

    @Test("Labels are compared in one canonical form")
    func labelKeyIsCanonical() {
        // Directly, because two labels normalised the same wrong way still
        // match each other and the rule looks fine from the outside.
        #expect(LiveDecorator.referenceKey("Read   More") == "read more")
        #expect(LiveDecorator.referenceKey("  read\tmore  ") == "read more")
        #expect(LiveDecorator.referenceKey("MDN") == "mdn")
    }

    @Test("A task checkbox is never read as a reference")
    func tasksSurvive() {
        #expect(links("- [ ] something to do\n- [x] done\n").isEmpty)
    }

    @Test("An inline link keeps its own form")
    func inlineLinksAreUntouched() {
        let found = links("See [the docs](https://example.com).\n\n[docs]: https://elsewhere.test\n")
        #expect(found.count == 1)
        #expect(found.first?.destination == "https://example.com")
    }

    @Test("A footnote is not a reference")
    func footnotesSurvive() {
        let text = "A claim.[^1]\n\n[^1]: The note.\n"
        #expect(links(text).isEmpty)
        #expect(definitions(text).isEmpty)
    }

    @Test("A full reference is not split into two shortcuts")
    func fullReferenceIsNotSplit() {
        // Longest first: matching the shortcut form first would take the
        // `[text]` and leave `[mdn]` behind as prose.
        let found = links("[text][mdn]\n\n[mdn]: https://example.com\n[text]: https://wrong.test\n")
        #expect(found.count == 1)
        #expect(found.first?.text == "[text][mdn]")
        #expect(found.first?.destination == "https://example.com")
    }

    @Test("A wikilink is not a reference")
    func wikilinksSurvive() {
        #expect(links("See [[Another Note]].\n\n[another note]: https://example.com\n").isEmpty)
    }

    @Test("An image keeps its own form")
    func imagesSurvive() {
        #expect(links("![alt](picture.png)\n\n[alt]: https://example.com\n").isEmpty)
    }
}
