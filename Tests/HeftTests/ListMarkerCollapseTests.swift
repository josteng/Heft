import Foundation
import Testing
@testable import HeftCore

/// How much of a list marker is hidden.
///
/// A collapsed character has no width, so whatever is hidden here cannot be
/// seen, moved through or typed into. Hiding the whole whitespace run meant a
/// second space after the marker changed nothing on screen: the caret stood
/// still, the item did not move, and the only evidence of the keystroke was in
/// the file. The marker and one space hide; the rest is ordinary whitespace.
@Suite("List marker collapse")
struct ListMarkerCollapseTests {

    /// What the editor hides on the first line of `document`, as text.
    private func hidden(_ document: String) -> String? {
        let source = document as NSString
        for decoration in LiveDecorator.decorations(in: document) {
            guard case .listMarker = decoration.style else { continue }
            return decoration.syntax.map { source.substring(with: $0) }.joined()
        }
        return nil
    }

    @Test("One space after the marker hides with it")
    func theOrdinaryMarkerHidesWhole() {
        #expect(hidden("- item") == "- ")
        #expect(hidden("1. item") == "1. ")
        #expect(hidden("- [ ] item") == "- [ ] ")
    }

    @Test("Further spaces stay visible")
    func extraSpacesSurvive() {
        #expect(hidden("-  item") == "- ")
        #expect(hidden("-     item") == "- ")
        #expect(hidden("1.   item") == "1. ")
        #expect(hidden("- [ ]   item") == "- [ ] ")
    }

    /// Indentation is hidden too: the glyph is placed from the paragraph
    /// indent, so leaving it visible would indent the item twice.
    @Test("Leading indentation still hides")
    func indentationStillHides() {
        #expect(hidden("\t- item") == "\t- ")
        #expect(hidden("\t-   item") == "\t- ")
    }

    /// A marker with nothing after it is the line being typed, and the match
    /// stops at the end of the line rather than running past it.
    @Test("A marker alone on its line hides no more than it has")
    func anEmptyItemStaysInBounds() {
        #expect(hidden("- ") == "- ")
        #expect(hidden("-  ") == "- ")
    }
}
