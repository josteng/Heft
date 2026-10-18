import Foundation
import Testing
@testable import HeftCore

/// A page title with brackets in it is written into a link with its brackets
/// escaped, `[\[Shop\] Sale](url)`. CommonMark and Obsidian read that as a
/// link; Heft read the first `\]` as the end of the label and showed the
/// whole thing as text.
@Suite("Escaped brackets in link text")
struct EscapedLinkTextTests {

    /// `[text](url)` links only: a bare URL inside one is linked on its own,
    /// with no markup to hide, and is not what these are about.
    private func links(_ document: String) -> [(text: String, destination: String)] {
        let source = document as NSString
        return LiveDecorator.decorations(in: document).compactMap { decoration in
            guard case .link(let destination) = decoration.style, !decoration.syntax.isEmpty
            else { return nil }
            return (source.substring(with: decoration.range), destination)
        }
    }

    @Test("Escaped brackets inside the label keep it a link")
    func escapedBracketsInLabel() {
        let document = "[\\[MY Shop\\] Big sale](https://example.com/deal)"
        let found = links(document)
        #expect(found.count == 1)
        #expect(found.first?.text == document)
        #expect(found.first?.destination == "https://example.com/deal")
    }

    @Test("An escaped opening bracket is still not a link")
    func escapedOpenerIsText() {
        #expect(links("\\[not a link](https://example.com)").isEmpty)
    }
}
