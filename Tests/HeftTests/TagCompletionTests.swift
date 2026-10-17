import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// Typing `#` offers the vault's tags, most used first.
@Suite("Tag completion")
struct TagCompletionTests {

    private func detect(_ source: String, caret: Int? = nil) -> TagCompletionContext? {
        let location = caret ?? (source as NSString).length
        return TagCompletionContext.detect(in: source, selection: NSRange(location: location, length: 0))
    }

    @Test("A # starting a word is a tag being typed")
    func detectsTag() {
        #expect(detect("Notes #")?.query == "")
        #expect(detect("Notes #th")?.queryRange == NSRange(location: 7, length: 2))
        #expect(detect("#th")?.query == "th")
        #expect(detect("Notes #work/ad")?.query == "work/ad")
        #expect(detect("x\t#ta")?.query == "ta")
    }

    @Test("Headings, numbers, URLs, code, links and frontmatter are not tags")
    func refusesOthers() {
        #expect(detect("# ") == nil)
        #expect(detect("## H") == nil)
        #expect(detect("Issue #12") == nil)
        #expect(detect("see example.com/#part") == nil)
        #expect(detect("word#tag") == nil)
        #expect(detect("`code #ta") == nil)
        #expect(detect("[[Note #ta") == nil)
        #expect(detect("```\n#ta") == nil)
        #expect(detect("---\ntags: #ta\n---\nbody", caret: 13) == nil)
        #expect(detect("---\nk: v\n---\n#ta")?.query == "ta")
        // In the middle of a tag already written, completing would leave its tail.
        #expect(detect("#thesis more", caret: 3) == nil)
    }

    @Test("Tags starting with the query come before those containing it")
    func ordering() throws {
        let context = try #require(detect("x #th"))
        #expect(context.suggestions(from: ["math", "thesis", "other", "theory", "plain"])
            == ["thesis", "theory", "math", "other"])
        #expect(try #require(detect("x #")).suggestions(from: ["a", "b"]) == ["a", "b"])
    }

    @Test("Accepting writes the tag and one space")
    func accepting() throws {
        let typed = "Notes #th"
        let edit = try #require(detect(typed)).accepting("thesis", in: typed)
        #expect(edit.applied(to: typed) == "Notes #thesis ")
        #expect(edit.selection == NSRange(location: 14, length: 0))

        let before = "Notes #th more"
        let spaced = try #require(detect(before, caret: 9)).accepting("thesis", in: before)
        #expect(spaced.applied(to: before) == "Notes #thesis more")
        #expect(spaced.selection == NSRange(location: 14, length: 0))
    }

    @MainActor
    @Test("The editor offers the vault's tags, most used first, and writes the chosen one")
    func editorOffersTags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in ["A.md": "#thesis #travel", "B.md": "#thesis", "C.md": "#thesis #math"] {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))

        view.string = "Notes #"
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(view.visibleCompletions.first == "thesis")
        #expect(Set(view.visibleCompletions) == ["thesis", "travel", "math"])

        view.string = "Notes #t"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: false)
        #expect(view.visibleCompletions == ["thesis", "travel", "math"])
        view.moveDown(nil)
        view.insertNewline(nil)
        #expect(view.string == "Notes #travel ")

        // A space after # is a heading's, and closes the menu.
        view.string = "#"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(!view.visibleCompletions.isEmpty)
        view.string = "# "
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.updateLinkCompletion(allowStart: false)
        #expect(view.visibleCompletions.isEmpty)
    }
}
