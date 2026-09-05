import Foundation
import Testing
@testable import HeftCore

/// A URL usually arrives in a note pasted, with nobody stopping to wrap it in
/// `[label](…)` first. Before these, only the bracketed form was decorated, so
/// the commonest way to put a link in a note produced plain grey text.
@Suite("Autolinks")
struct AutolinkTests {

    /// Every link decoration, as (range, destination).
    private func links(_ document: String) -> [(range: NSRange, destination: String)] {
        LiveDecorator.decorations(in: document).compactMap { decoration in
            guard case .link(let destination) = decoration.style else { return nil }
            return (decoration.range, destination)
        }
    }

    private func decoration(_ document: String) -> MarkdownDecoration? {
        LiveDecorator.decorations(in: document).first { decoration in
            if case .link = decoration.style { return true }
            return false
        }
    }

    @Test("A bare URL is a link")
    func bare() {
        let found = links("Bare: https://example.com/earn")
        #expect(found.count == 1)
        #expect(found.first?.destination == "https://example.com/earn")
        #expect(found.first?.range == NSRange(location: 6, length: 24))
    }

    /// Nothing is hidden: the URL is its own label, so collapsing any of it
    /// would leave the reader with less than they typed.
    @Test("A bare URL hides nothing")
    func bareHidesNothing() {
        #expect(decoration("https://x.dev")?.syntax.isEmpty == true)
    }

    @Test("An angle autolink is a link, and its brackets hide")
    func angle() {
        let document = "<https://example.com/earn>"
        let found = links(document)
        #expect(found.count == 1)
        #expect(found.first?.destination == "https://example.com/earn")
        // The `<` and `>` collapse, so the line reads as the URL alone.
        #expect(decoration(document)?.syntax == [
            NSRange(location: 0, length: 1),
            NSRange(location: 25, length: 1),
        ])
    }

    /// The bracketed form runs first and protects its range, so the URL inside
    /// it cannot also be claimed by the bare matcher.
    @Test("A bracketed link is decorated once, not twice")
    func bracketedWinsOnce() {
        let found = links("[earn](https://example.com/earn)")
        #expect(found.count == 1)
        #expect(found.first?.range == NSRange(location: 0, length: 32))
    }

    @Test("A URL inside code stays code")
    func insideCode() {
        #expect(links("run `https://x.dev` now").isEmpty)
    }

    @Test("Trailing sentence punctuation is not part of the URL")
    func trailingPunctuation() {
        #expect(links("see https://x.dev/a, then").first?.destination == "https://x.dev/a")
        #expect(links("see https://x.dev/a.").first?.destination == "https://x.dev/a")
        #expect(links("really? https://x.dev/a!").first?.destination == "https://x.dev/a")
    }

    /// A closing paren the URL never opened belongs to the sentence.
    @Test("An unopened closing bracket is left to the prose")
    func unbalancedBracket() {
        #expect(links("(see https://example.com)").first?.destination == "https://example.com")
        #expect(links("[see https://example.com]").first?.destination == "https://example.com")
    }

    /// ...but one the URL did open is part of it, which is how Wikipedia
    /// disambiguation links survive.
    @Test("A balanced bracket stays in the URL")
    func balancedBracket() {
        #expect(
            links("https://en.wikipedia.org/wiki/Heft_(disambiguation)").first?.destination
                == "https://en.wikipedia.org/wiki/Heft_(disambiguation)"
        )
    }

    /// The regex needs a character after `://`, so a lone "https://" never
    /// matches it. What reaches the guard is a URL whose only remaining
    /// character is punctuation the trimmer then takes away.
    @Test("A scheme with nothing left after trimming is not a link")
    func emptyScheme() {
        #expect(links("https://").isEmpty)
        #expect(links("see https://, ok").isEmpty)
        #expect(links("https://.").isEmpty)
    }
}
