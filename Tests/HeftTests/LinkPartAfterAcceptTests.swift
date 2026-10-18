import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A note taken from the link menu leaves the caret after `]]`; typing `#` or
/// `|` there means the heading or text of that link, not a character after it.
@Suite("Link parts after a completed link")
@MainActor
struct LinkPartAfterAcceptTests {

    private func editor(after source: String) throws -> HeftTextKit2View {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-part-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Note\n\n## Plan\n".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        // `[[` opens the menu; Return takes its first note.
        view.insertText("[", replacementRange: view.selectedRange())
        view.insertText("[", replacementRange: view.selectedRange())
        view.updateLinkCompletion(allowStart: true)
        view.insertNewline(nil)
        return view
    }

    @Test("# right after the link goes inside it")
    func headingGoesInside() throws {
        let view = try editor(after: "See ")
        #expect(view.string == "See [[Note]]")
        view.insertText("#", replacementRange: view.selectedRange())
        #expect(view.string == "See [[Note#]]")
        #expect(view.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test("| right after the link goes inside it")
    func textGoesInside() throws {
        let view = try editor(after: "See ")
        view.insertText("|", replacementRange: view.selectedRange())
        #expect(view.string == "See [[Note|]]")
    }

    @Test("Once the caret has moved on, | is typed where it is")
    func onlyRightThen() throws {
        let view = try editor(after: "| ")
        view.insertText(" ", replacementRange: view.selectedRange())
        view.insertText("|", replacementRange: view.selectedRange())
        #expect(view.string == "| [[Note]] |")
    }
}
