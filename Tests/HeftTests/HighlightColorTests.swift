import Foundation
import Testing
@testable import HeftCore

@Suite("Highlight colours")
struct HighlightColorTests {

    private func hidden(_ source: String) -> String {
        let ns = source as NSString
        return LiveDecorator.decorations(in: source)
            .flatMap(\.syntax)
            .sorted { $0.location < $1.location }
            .map { ns.substring(with: $0) }
            .joined()
    }

    @Test("The emoji after == names the colour and hides with the markers")
    func emojiIsMarkup() {
        let styles = LiveDecorator.decorations(in: "a ==🔴hot== b").map(\.style)
        #expect(styles.contains(.highlight(.red)))
        #expect(hidden("a ==🔴hot== b") == "==🔴==")
        // With a variation selector, which some keyboards append.
        #expect(hidden("==🟣\u{FE0F}x==") == "==🟣\u{FE0F}==")
        #expect(LiveDecorator.decorations(in: "==🟣\u{FE0F}x==").map(\.style) == [.highlight(.purple)])
    }

    @Test("A highlight without an emoji keeps the default colour")
    func plainHighlight() {
        #expect(LiveDecorator.decorations(in: "==hi==").map(\.style) == [.highlight(nil)])
        #expect(hidden("==hi==") == "====")
        // Any other emoji is text, not a colour.
        #expect(LiveDecorator.decorations(in: "==🍎hi==").map(\.style) == [.highlight(nil)])
        #expect(hidden("==🍎hi==") == "====")
    }

    @Test("An emoji with nothing after it is left visible")
    func loneEmojiStaysVisible() {
        // Hiding it would leave a highlight with nothing on screen.
        #expect(hidden("==🔴==") == "====")
    }

    @Test("The reading view takes the colour off the text")
    func readingViewSplitsColour() throws {
        let blocks = MarkdownModel.parse("Say ==🟢go== now").blocks
        guard case .paragraph(let inlines) = try #require(blocks.first) else {
            Issue.record("not a paragraph")
            return
        }
        let highlight = inlines.compactMap { inline -> (String, HighlightColor?)? in
            guard case .highlight(let content, let color) = inline else { return nil }
            return (MarkdownModel.plainText(content), color)
        }.first
        #expect(highlight?.0 == "go")
        #expect(highlight?.1 == .green)
    }

    @Test("An excerpt drops the colour emoji")
    func excerptDropsEmoji() {
        #expect(NoteText.excerpt("Buy ==🔵milk== today\n") == "Buy milk today")
    }
}
