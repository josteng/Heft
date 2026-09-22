import Foundation
import Testing
@testable import HeftCore

/// `- - -` is a rule, and `- ` at the start of a line is a list marker, so
/// one line matches both. A rule that was also decorated as a bullet turned
/// into one the moment the caret revealed its dashes.
@Suite("Thematic breaks")
struct ThematicBreakTests {

    private func styles(_ document: String, line: String) -> [MarkdownDecoration.Style] {
        let source = document as NSString
        let target = source.range(of: line)
        return LiveDecorator.decorations(in: document)
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.style)
    }

    private func isRule(_ style: MarkdownDecoration.Style) -> Bool {
        if case .thematicBreak = style { return true }
        return false
    }

    private func isListMarker(_ style: MarkdownDecoration.Style) -> Bool {
        if case .listMarker = style { return true }
        return false
    }

    @Test("Every spelling of a rule is one, and none is a list")
    func rulesAreNotLists() {
        for rule in ["---", "- - -", "***", "* * *", "___", "_ _ _", "----", "-  -  -"] {
            let styles = styles("Above.\n\n\(rule)\n\nBelow.\n", line: rule)
            #expect(styles.contains(where: isRule), "\(rule) is not a rule")
            #expect(!styles.contains(where: isListMarker), "\(rule) is also a bullet")
        }
    }

    @Test("A rule tight under a list is still a rule")
    func ruleEndsAList() {
        let styles = styles("- item one\n- item two\n- - -\nAfter.\n", line: "- - -")
        #expect(styles.contains(where: isRule))
        #expect(!styles.contains(where: isListMarker))
    }

    @Test("Dashes under a paragraph stay a heading, not a rule")
    func setextStillWins() {
        let styles = styles("Heading text\n---\nAfter.\n", line: "---")
        #expect(!styles.contains(where: isRule), "the H2's underline became a rule")
    }

    @Test("An ordinary bullet is untouched")
    func bulletsStillWork() {
        let styles = styles("- item one\n- item two\n", line: "- item one")
        #expect(styles.contains(where: isListMarker))
        #expect(!styles.contains(where: isRule))
    }
}
