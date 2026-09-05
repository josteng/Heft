import Foundation
import Testing
@testable import HeftCore

/// A keystroke inside a table cell reparses the table's paragraph alone.
///
/// `---` disqualified a paragraph from the fast path wherever it appeared,
/// and a table's separator row is made of it, so every keystroke in a cell
/// went through the full rescan. The dashes only open something when they
/// start a line, which is what the marker check now looks for.
@Suite("Typing inside a table")
struct TableFastPathTests {

    private func reuse(_ before: String, _ after: String) -> [MarkdownDecoration]? {
        let cache = LiveDecorator.DecorationCache(
            source: before as NSString, decorations: LiveDecorator.decorations(in: before)
        )
        return LiveDecorator.reuse(cache: cache, for: after as NSString)
    }

    @Test("A character typed into a cell takes the fast path")
    func cellEditIsLocal() {
        let before = "Intro paragraph.\n\n| a | b |\n|---|---|\n| one | two |\n\nOutro paragraph."
        let after = before.replacingOccurrences(of: "| one |", with: "| onex |")
        let reused = reuse(before, after)
        #expect(reused != nil)
        // And it says what the full scan says, table decoration included.
        #expect(reused.map(IncrementalDecorationCheck.canonical)
            == IncrementalDecorationCheck.canonical(LiveDecorator.decorations(in: after)))
    }

    /// Dashes at the start of a line are a rule or a fence, and either can
    /// change how the rest of the note parses.
    /// The edits sit strictly inside the paragraph: one at its very end is
    /// refused for that reason alone, and would prove nothing about dashes.
    @Test("A line of dashes still forces the full scan")
    func lineOfDashesFallsBack() {
        let before = "Some text\n---\nmore text after it"
        #expect(reuse(before, "Some text\n---\nmore textx after it") == nil)
        let indented = "Some text\n   ---\nmore text after it"
        #expect(reuse(indented, "Some text\n   ---\nmore textx after it") == nil)
    }

    @Test("Editing inside frontmatter still forces the full scan")
    func frontmatterFallsBack() {
        let before = "---\ntitle: note\n---\n\nBody text."
        #expect(reuse(before, "---\ntitle: notes\n---\n\nBody text.") == nil)
    }
}
