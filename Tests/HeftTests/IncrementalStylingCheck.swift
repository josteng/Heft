import AppKit
import Foundation
import HeftCore
@testable import Heft

/// Proves that styling only what changed produces exactly what styling
/// everything produces.
///
/// The live surface keeps the previous pass and rewrites only where the two
/// disagree, which is the difference between a keystroke costing a whole
/// document's worth of work and costing a paragraph's. That is only safe while
/// the two really are indistinguishable, and "indistinguishable" here means
/// every attribute on every character — a missed reset shows up as markup that
/// stays collapsed after its construct is gone, or a heading that keeps its
/// size after the `#` is deleted.
///
/// So: run an edit script through an incrementally styled buffer, and after
/// every keystroke compare it against a buffer styled from scratch.
@MainActor
enum IncrementalStylingCheck {
    struct Result {
        var passed = 0
        var failures: [String] = []
        var ok: Bool { failures.isEmpty }
    }

    /// Mirrors what `LiveTextEditor.Coordinator` does, without a view.
    final class Driver {
        let storage = NSTextStorage()
        private var styled: RestyleScope.Snapshot?
        private var layout = LiveLayout()
        let context: RenderContext
        let width: CGFloat

        init(context: RenderContext, width: CGFloat) {
            self.context = context
            self.width = width
        }

        func resetStyling() {
            styled = nil
            layout = LiveLayout()
        }

        /// Edits the buffer the way typing does — replacing just the span that
        /// differs — then restyles incrementally.
        @discardableResult
        func type(_ text: String, selection: NSRange) -> LiveLayout {
            let edit = SourceEdit.between(storage.string as NSString, text as NSString)
            if edit.changed.length > 0 || edit.previous.length > 0 {
                storage.replaceCharacters(
                    in: edit.previous,
                    with: (text as NSString).substring(with: edit.changed)
                )
            }

            let source = storage.string as NSString
            let reveal = Reveal(selection: selection, in: source)
            let decorations = LiveDecorator.decorations(in: source as String)
            let snapshot = RestyleScope.Snapshot(
                source: source, decorations: decorations, reveal: reveal
            )
            let scope = styled.map { RestyleScope.scope(from: $0, to: snapshot) }
            styled = snapshot
            layout = LiveStyler.apply(
                to: storage, reveal: reveal, context: context,
                contentWidth: width, decorations: decorations,
                incremental: scope.map {
                    LiveStyler.Incremental(dirty: $0.dirty, edit: $0.edit, previous: layout)
                }
            )
            return layout
        }
    }

    /// Which kind of widget sits on each paragraph. The layout signature only
    /// records *where* widgets are; carrying one over from the previous pass
    /// could put the right number of them in the right places and still hand a
    /// paragraph the wrong one.
    static func widgetKinds(_ layout: LiveLayout) -> String {
        layout.blocks
            .map { "\($0.key):\(Mirror(reflecting: $0.value).children.first?.label ?? "\($0.value)")" }
            .sorted()
            .joined(separator: ",")
    }

    /// A buffer styled from scratch: the answer the incremental one must match.
    static func reference(
        _ text: String, selection: NSRange, context: RenderContext, contentWidth: CGFloat
    ) -> (NSTextStorage, LiveLayout) {
        let storage = NSTextStorage(string: text)
        let layout = LiveStyler.apply(
            to: storage, reveal: Reveal(selection: selection, in: text as NSString),
            context: context, contentWidth: contentWidth
        )
        return (storage, layout)
    }

    /// The first character whose attributes differ, described well enough to
    /// debug from.
    static func firstDifference(_ actual: NSTextStorage, _ expected: NSTextStorage) -> String? {
        guard actual.string == expected.string else {
            return "text differs: \(actual.string.debugDescription) vs \(expected.string.debugDescription)"
        }
        for location in 0..<actual.length {
            let lhs = actual.attributes(at: location, effectiveRange: nil)
            let rhs = expected.attributes(at: location, effectiveRange: nil)
            if lhs.count != rhs.count || !lhs.keys.allSatisfy({ key in
                guard let a = lhs[key], let b = rhs[key] else { return false }
                return (a as AnyObject).isEqual(b)
            }) {
                let context = (actual.string as NSString).substring(
                    with: (actual.string as NSString).lineRange(
                        for: NSRange(location: location, length: 0)
                    )
                )
                let keys = Set(lhs.keys).union(rhs.keys)
                    .filter { key in
                        let a = lhs[key], b = rhs[key]
                        guard let a, let b else { return true }
                        return !(a as AnyObject).isEqual(b)
                    }
                    .map(\.rawValue).sorted().joined(separator: ",")
                return "at \(location) in \(context.debugDescription): \(keys)"
            }
        }
        return nil
    }

    /// Documents covering everything the styler treats specially.
    static let corpus: [(String, String)] = [
        ("prose", """
        A plain paragraph with **bold**, *italic*, ~~struck~~, ==marked== and \
        `code` in it.

        A second paragraph, so there is an empty line to get the compact style.
        """),
        ("headings", """
        # Title

        Body under a heading.

        ### Third level
        More body.
        """),
        ("lists", """
        - first bullet
        - [ ] a task
        - [x] a done task
        \t- nested under it
        1. ordered
        2. also ordered
        """),
        ("quotes", """
        > A quoted line.
        > A second quoted line.

        > [!warning] Careful
        > The body of the callout.
        """),
        ("table", """
        Before the table.

        | a | b |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |

        After the table.
        """),
        ("fence", """
        Before.

        ```swift
        let x = 1
        func f() -> Int { x }
        ```

        After.
        """),
        ("math", """
        Inline $h(t)$ math in a sentence.

        $$e^{i\\pi} + 1 = 0$$

        After the display block.
        """),
        ("links", """
        A [[Wiki Link]] and an [external](https://example.com) one, plus a
        #tag and another #tag/nested in the same line.
        """),
        ("frontmatter", """
        ---
        title: A note
        tags: [one, two]
        ---

        Body after frontmatter.
        """),
        ("mixed", """
        ---
        title: Everything
        ---

        # Heading with `code` and $x^2$

        - [ ] task with **bold** and a [[Link]]

        > [!note] Callout
        > With a #tag inside.

        | col | col |
        |---|---|
        | `a` | **b** |

        ```python
        print("hi")
        ```

        ***

        <!-- a comment -->
        Final line with ![[embed.png]] on it.
        """),
    ]

    /// The same comparison, but driven through the real `HeftTextKit2View` and
    /// `LiveTextEditor.Coordinator` rather than a stand-in for them.
    ///
    /// The driver above proves the scoping arithmetic; this proves the editor
    /// asks for the right scope in the first place — that typing, deleting,
    /// Return, caret moves and swapping the open note all leave the buffer in
    /// the state a full restyle would have produced.
    static func runThroughEditor(into result: inout Result) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)

        for (name, document) in corpus {
            let editor = LiveTextEditor(
                text: .constant(document), generation: 0, generationKeepsPosition: false, findSelection: nil,
                context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
                onVimSearch: { _ in }
            )
            let coordinator = LiveTextEditor.Coordinator(editor)
            let view = HeftTextKit2View(usingTextLayoutManager: true)
            view.isVerticallyResizable = true
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
            view.textContainerInset = NSSize(width: 28, height: 28)
            view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
            view.textLayoutManager?.delegate = coordinator
            view.delegate = coordinator
            view.string = document
            coordinator.restyle(view)

            func compare(_ label: String) {
                let selection = view.selectedRange()
                let (expected, _) = reference(
                    view.string, selection: selection, context: context,
                    contentWidth: max(240, (view.textContainer?.size.width ?? 640) - 8)
                )
                guard let storage = view.textStorage else {
                    result.failures.append("\(name) \(label): no storage")
                    return
                }
                if let difference = firstDifference(storage, expected) {
                    result.failures.append("editor \(name) \(label): \(difference)")
                } else {
                    result.passed += 1
                }
            }

            // Typing, including the characters that turn prose into markup.
            for (index, character) in ["a", "*", "*", "b", "*", "*", " ", "#", "x"].enumerated() {
                view.setSelectedRange(NSRange(
                    location: min(index * 3, view.string.utf16.count), length: 0
                ))
                view.insertText(character, replacementRange: view.selectedRange())
                compare("typed \(character.debugDescription) at \(index * 3)")
            }
            // Backspace, which is where markup that failed to reset shows up.
            for step in 0..<6 {
                view.setSelectedRange(NSRange(
                    location: min(8, view.string.utf16.count), length: 0
                ))
                view.deleteBackward(nil)
                compare("deleted \(step)")
            }
            // Return, with its list and quote continuation.
            for location in [0, view.string.utf16.count / 2, view.string.utf16.count] {
                view.setSelectedRange(NSRange(
                    location: min(location, view.string.utf16.count), length: 0
                ))
                view.insertNewline(nil)
                compare("newline at \(location)")
            }
            // Caret moves alone.
            for location in stride(from: 0, through: view.string.utf16.count, by: 17) {
                view.setSelectedRange(NSRange(location: location, length: 0))
                compare("caret \(location)")
            }
            // Swapping the open note replaces the storage and every attribute
            // with it, which the editor has to notice.
            view.string = document + "\n\n> [!tip] appended\n> body\n"
            coordinator.resetStyling()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.restyle(view)
            compare("after document swap")
        }
    }

    static func run() -> Result {
        var result = Result()
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let width: CGFloat = 640

        func check(_ label: String, _ text: String, _ selection: NSRange, _ driver: Driver) {
            let layout = driver.type(text, selection: selection)
            let (expected, expectedLayout) = reference(
                text, selection: selection, context: context, contentWidth: width
            )
            if let difference = firstDifference(driver.storage, expected) {
                result.failures.append("\(label): \(difference)")
            } else if layout.signature != expectedLayout.signature {
                result.failures.append(
                    "\(label): widget layout differs\n  \(layout.signature)\n  \(expectedLayout.signature)"
                )
            } else if widgetKinds(layout) != widgetKinds(expectedLayout) {
                result.failures.append(
                    "\(label): widget kinds differ\n  \(widgetKinds(layout))\n  \(widgetKinds(expectedLayout))"
                )
            } else {
                result.passed += 1
            }
        }

        for (name, document) in corpus {
            let source = document as NSString

            // Typing one character at a time at a set of positions spread
            // through the document, which is the case that has to be fast and
            // therefore the case most likely to be scoped wrongly.
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let at = min(source.length, Int(Double(source.length) * fraction))
                let driver = Driver(context: context, width: width)
                check("\(name)@\(fraction) initial", document, NSRange(location: at, length: 0), driver)
                var text = document
                for (index, character) in ["x", " ", "*", "#", "|", "`", "$", "\n", "-", "["].enumerated() {
                    let caret = at + index
                    text = (text as NSString).replacingCharacters(
                        in: NSRange(location: caret, length: 0), with: character
                    )
                    check(
                        "\(name)@\(fraction) typed \(character.debugDescription)",
                        text, NSRange(location: caret + 1, length: 0), driver
                    )
                }
                // ...and taking it all back out again, which is where a missed
                // reset shows: markup that stays collapsed after its construct
                // has gone.
                for step in 0..<10 {
                    let caret = at + 9 - step
                    text = (text as NSString).replacingCharacters(
                        in: NSRange(location: caret, length: 1), with: ""
                    )
                    check(
                        "\(name)@\(fraction) deleted \(step)",
                        text, NSRange(location: caret, length: 0), driver
                    )
                }
            }

            // Moving the caret without typing: what reveals and what collapses
            // changes, and nothing else may.
            let driver = Driver(context: context, width: width)
            check("\(name) caret start", document, NSRange(location: 0, length: 0), driver)
            for location in stride(from: 0, through: source.length, by: max(1, source.length / 24)) {
                check(
                    "\(name) caret \(location)", document,
                    NSRange(location: location, length: 0), driver
                )
            }
            // A selection rather than a caret reveals differently again.
            if source.length > 8 {
                check(
                    "\(name) selection", document,
                    NSRange(location: 2, length: source.length - 4), driver
                )
            }
            check("\(name) unfocused", document, NSRange(location: 0, length: 0), driver)

            // Whole-document replacement, the case the editor has to notice and
            // restyle in full because assigning `string` drops every attribute.
            let replaced = Driver(context: context, width: width)
            check("\(name) fresh", document, NSRange(location: 0, length: 0), replaced)
            replaced.storage.setAttributedString(NSAttributedString(string: document + "\n\n# Appended"))
            replaced.resetStyling()
            check(
                "\(name) after reset", document + "\n\n# Appended",
                NSRange(location: 0, length: 0), replaced
            )
        }

        runThroughEditor(into: &result)
        return result
    }
}
