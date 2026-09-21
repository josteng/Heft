import AppKit
import Foundation
import Testing
@testable import Heft

/// `heft spell`. The checker itself is macOS's, so what is worth asserting is
/// that the verb skips the same spans the editor does and points at the right
/// place in the file.
///
/// The words here are ones a system dictionary has to reject to be a
/// dictionary at all, so the suite does not turn on how strict this machine's
/// is. Nothing asserts a particular *correction*, which does vary.
@MainActor
@Suite("Spell CLI")
struct SpellCLITests {

    private func findings(_ text: String, grammar: Bool = false) -> [SpellCLI.Finding] {
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
        return SpellCLI.check(text, path: "Note.md", tag: tag, grammar: grammar)
    }

    private func words(_ text: String) -> [String] {
        findings(text).filter { $0.kind == "spelling" }.map(\.text)
    }

    /// The point of the verb: the same answer the editor draws, which means
    /// the same spans skipped.
    @Test("Code, tags and math are skipped, prose is not")
    func skipsSource() {
        let text = """
        A delibrate typo in prose.

        Inline `delibrate` and a #delibrate tag.

        ```swift
        let delibrate = 1
        ```
        """
        #expect(words(text) == ["delibrate"], "only the prose one should be reported")
    }

    @Test("A link destination is skipped and its label is not")
    func skipsDestinations() {
        #expect(words("A [delibrate label](notes/delibrate-path.md) here.") == ["delibrate"])
    }

    // MARK: - Where it points

    @Test("Line and column are one-based and count from the line's start")
    func position() {
        let text = "# Title\n\nA delibrate typo.\n"
        let found = findings(text)
        #expect(found.count == 1)
        #expect(found.first?.line == 3)
        #expect(found.first?.column == 3)
    }

    /// Counted in characters rather than UTF-16 units, or every column after
    /// an emoji or an accent is wrong by the width of its encoding.
    @Test("A column counts characters, not UTF-16 units")
    func columnCountsCharacters() {
        let plain = findings("xx A delibrate typo.\n").first
        let wide = findings("\u{1F600}\u{00E9} A delibrate typo.\n").first
        #expect(plain?.column == 6)
        #expect(wide?.column == 6, "an emoji and an accent must each count as one character")
    }

    @Test("A misspelling on the first line is on line one")
    func firstLine() {
        #expect(findings("A delibrate typo.\n").first?.line == 1)
        #expect(findings("A delibrate typo.\n").first?.column == 3)
    }

    @Test("Findings come back in document order")
    func documentOrder() {
        let text = "A delibrate one.\n\nAnd a recieve two.\n\nAnd occured three.\n"
        let found = findings(text)
        #expect(found.map(\.line) == found.map(\.line).sorted())
        #expect(found.count >= 3)
    }

    // MARK: - The two kinds

    /// Grammar is the blue underline and has to be separable from the red one,
    /// which is what `--no-grammar` and the `kind` field are for.
    @Test("Grammar is reported apart from spelling, and only when asked")
    func grammarIsSeparate() {
        let text = "The the duplicated word is here.\n"
        #expect(findings(text, grammar: false).isEmpty, "that sentence is spelled correctly")

        let both = findings(text, grammar: true)
        #expect(both.contains { $0.kind == "grammar" })
        #expect(both.allSatisfy { $0.kind == "grammar" })
    }

    /// A grammar result covers the whole sentence and names the clause inside
    /// it, so pointing at the sentence would send a reader to the wrong word.
    @Test("A grammar finding points at the clause, not the sentence")
    func grammarPointsAtTheClause() {
        let text = "Everything here is fine. The the duplicated word is here.\n"
        let found = findings(text, grammar: true).first { $0.kind == "grammar" }
        #expect(found != nil, "a doubled word is the one thing every grammar pass catches")
        #expect(found?.text == "The the", "the clause, not the sentence around it")
        #expect(found?.column == 26)
        #expect(found?.note.isEmpty == false, "a grammar finding says what is wrong")
    }

    @Test("A clean note reports nothing")
    func clean() {
        #expect(findings("A sentence that is spelled correctly.\n", grammar: true).isEmpty)
    }
}
