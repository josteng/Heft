import Foundation
import Testing
@testable import HeftCore

/// What the live surface draws for a Windows note is what it draws for the
/// same note in Unix endings.
@Suite("Windows notes on the live surface")
struct LineEndingDecorationTests {

    @Test("A table keeps every row")
    func table() {
        let source = "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n| 3 | 4 |\r\n\r\nAfter\r\n"
        let tables = LiveDecorator.decorations(in: source).compactMap { decoration -> NSRange? in
            if case let .table(layout) = decoration.style, layout.rows.count == 3 { return decoration.range }
            return nil
        }
        // The rows and not the break after them, as in a Unix note.
        #expect(tables == [NSRange(location: 0, length: (source as NSString).range(of: "\r\n\r\nAfter").location)])
    }

    @Test("A fence's language has no carriage return in it")
    func fenceLanguage() {
        let decorations = LiveDecorator.decorations(in: "```swift\r\nlet x = 1\r\n```\r\n")
        #expect(decorations.contains { $0.style == .codeBlock(language: "swift") })
        let open = LiveDecorator.decorations(in: "```swift\r\nlet x = 1")
        #expect(open.contains { $0.style == .codeBlock(language: "swift") })
    }
}
