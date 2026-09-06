import Foundation
import Testing
@testable import HeftCore

/// Gaps found by auditing the decorator against CommonMark. Each of these was
/// producing something actively wrong rather than merely missing.
@Suite("CommonMark gaps")
struct CommonMarkGapTests {

    private func decorations(_ document: String) -> [MarkdownDecoration] {
        LiveDecorator.decorations(in: document)
    }

    private func styles(_ document: String) -> [MarkdownDecoration.Style] {
        decorations(document).map(\.style)
    }

    private func hidden(_ document: String) -> [String] {
        let source = document as NSString
        return decorations(document).flatMap(\.syntax).map { source.substring(with: $0) }
    }

    private func links(_ document: String) -> [String] {
        decorations(document).compactMap {
            if case .link(let destination) = $0.style { return destination }
            return nil
        }
    }

    private func hasEmphasis(_ document: String) -> Bool {
        styles(document).contains {
            if case .italic = $0 { return true }
            if case .bold = $0 { return true }
            return false
        }
    }

    // MARK: - Backslash escapes

    /// Escaping is how an author says "do not format this". Ignoring it
    /// formatted the text anyway *and* hid the backslashes, so characters
    /// vanished and the note read as the opposite of what was written.
    @Test("An escaped delimiter does not open emphasis")
    func escapedEmphasis() {
        #expect(!hasEmphasis("not \\*emphasis\\* here"))
        #expect(!hasEmphasis("a \\_b\\_ c"))
    }

    @Test("An escaped bracket does not make a link")
    func escapedLink() {
        #expect(links("\\[not a link\\](x)").isEmpty)
    }

    /// The backslash collapses and the character it protects stays, which is
    /// what CommonMark renders.
    @Test("The backslash is hidden, the character is not")
    func hidesTheBackslash() {
        #expect(hidden("a \\* b") == ["\\"])
    }

    /// `\\` is an escaped backslash, so the `*` after it is a real delimiter.
    /// Matching left to right and non-overlapping is what gets this right.
    @Test("An escaped backslash leaves the next delimiter working")
    func escapedBackslash() {
        #expect(hasEmphasis("a \\\\*b*"))
    }

    /// Backslashes inside maths are LaTeX, not markdown escapes. Reading them
    /// as escapes protected them, which stopped `$$…$$` matching at all and
    /// left the formula in the note as text.
    @Test("LaTeX keeps its backslashes")
    func mathIsNotEscaped() {
        let found = styles("$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$\n")
        #expect(found.contains { if case .blockMath = $0 { return true } else { return false } })
    }

    // MARK: - Code spans

    /// A code span holds a backtick of its own by using two to delimit it.
    /// The single-backtick pattern stopped at the inner one and styled the
    /// wrong half.
    @Test("A double-backtick span may contain a backtick")
    func doubleBacktickSpan() {
        let source = "``a ` b``"
        let code = decorations(source).first {
            if case .inlineCode = $0.style { return true } else { return false }
        }
        #expect(code?.range == NSRange(location: 0, length: 9))
    }

    // MARK: - Emphasis

    /// `***x***` is strong and emphasis together. The double pattern claimed
    /// the first two asterisks and stranded the third inside its own span.
    @Test("Triple asterisks are bold and italic over the same text")
    func tripleEmphasis() {
        let found = decorations("***both***").filter {
            if case .bold = $0.style { return true }
            if case .italic = $0.style { return true }
            return false
        }
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.range == NSRange(location: 0, length: 10) })
        #expect(hidden("***both***") == ["***", "***", "***", "***"])
    }

    // MARK: - Headings

    /// A closing sequence is decoration, not content: `## x ##` is the heading
    /// "x", and the trailing hashes were left on screen.
    @Test("A heading's closing hashes are hidden too")
    func atxClosingSequence() {
        #expect(hidden("## heading ##") == ["## ", " ##"])
        // Without the space it is part of the text, and stays.
        #expect(hidden("## heading##") == ["## "])
    }

    // MARK: - Autolinks

    @Test("An email in angle brackets is a mailto link")
    func angleEmail() {
        #expect(links("<user@example.com>") == ["mailto:user@example.com"])
        // The brackets collapse, which is what separates the angle form from
        // the bare one that would otherwise match the same address.
        #expect(hidden("<user@example.com>") == ["<", ">"])
    }

    @Test("A bare email is a mailto link")
    func bareEmail() {
        #expect(links("write to user@example.com today") == ["mailto:user@example.com"])
    }

    /// A scheme is supplied, or the link would be handed to the browser as a
    /// relative path.
    @Test("A www address is linked with a scheme")
    func wwwAutolink() {
        #expect(links("see www.example.com/a for more") == ["https://www.example.com/a"])
        #expect(links("see www.example.com.").first == "https://www.example.com")
    }

    /// Obsidian links a bare host when a slash follows it, and Heft follows
    /// Obsidian rather than GFM here, because a vault has to read the same in
    /// both. Without the slash a dotted word is just a word.
    @Test("A bare domain links when a path follows, and only then")
    func bareDomainWithPath() {
        #expect(links("enrol at developer.example.com/programs today") == ["https://developer.example.com/programs"])
        #expect(links("see example.com/docs.") == ["https://example.com/docs"])
        #expect(links("(see example.com/docs)") == ["https://example.com/docs"])
        #expect(links("example.com alone, then Note.md and Heft.app").isEmpty)
        #expect(links("a version like 0.2.0/x is not a host either").isEmpty)
    }

    /// An address inside a link's destination is already spoken for.
    @Test("An address inside a link is not linked twice")
    func noDoubleLinking() {
        #expect(links("[mail](mailto:user@example.com)") == ["mailto:user@example.com"])
    }
}
