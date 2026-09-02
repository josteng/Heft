import Foundation
@testable import HeftCore

/// Proves the reusing decorator answers exactly what a full scan would.
///
/// The existing incremental-styling check cannot cover this on its own: it
/// compares an incrementally styled buffer against a from-scratch one, and if
/// both sides used the same reusing decorator a wrong reuse would agree with
/// itself. So this drives edit scripts through both decorators and compares the
/// decorations directly, and it also counts how often the fast path was taken —
/// a version that quietly always fell back would otherwise pass.
enum IncrementalDecorationCheck {
    struct Result {
        var passed = 0
        var failures: [String] = []
        var reused = 0
        var fellBack = 0
    }

    static let corpus: [(String, String)] = [
        ("prose", """
        # A note

        Some prose with **bold**, *italic*, `code`, a [[Wiki Link]] and a
        [markdown](https://example.com) link, plus a #tag and $x^2$ math.

        Another paragraph entirely, which the edit should never touch.
        """),
        ("lists", """
        - one
        - two with **bold**
          - nested
        - four

        1. ordered
        2. second
        """),
        ("fenced", """
        Before the fence.

        ```swift
        let value = **not bold**
        ```

        After the fence, with *emphasis*.
        """),
        ("table", """
        Intro paragraph.

        | a | b |
        |---|---|
        | 1 | 2 |

        Outro paragraph.
        """),
        ("frontmatter", """
        ---
        title: A note
        tags: [one, two]
        ---

        Body text with **bold**.
        """),
        ("quotes", """
        > A quote line
        > continued here

        Plain paragraph after it.
        """),
        ("comment", """
        Before.

        <!-- a comment
             over two lines -->

        After.
        """),
        ("math", """
        Inline $a+b$ here.

        $$
        \\sum_{i=0}^{n} i
        $$

        Trailing prose.
        """),
    ]

    /// A stable key, so two arrays holding the same decorations in a different
    /// order compare equal. Order among non-overlapping decorations does not
    /// affect styling; the contents do.
    static func canonical(_ decorations: [MarkdownDecoration]) -> [String] {
        decorations
            .map { "\($0.range.location)+\($0.range.length):\(String(describing: $0.style))"
                + ":\($0.syntax.map { "\($0.location)+\($0.length)" }.joined(separator: ","))" }
            .sorted()
    }

    /// A deterministic pseudo-random sequence, so a failure is reproducible.
    struct Seeded {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    /// Edits that are not single characters: pasted blocks, deletions, and the
    /// blank line that splits one paragraph into two. These are where a guard
    /// that looks redundant earns its place.
    static func adversarial(into result: inout Result) {
        let fragments = [
            "\n\n", "\n", "```\n", "| a | b |\n", "---\n", "$$\n", "<!-- x -->",
            "**bold**", "a\nb", "> quote\n", "# heading\n", "",
        ]
        var random = Seeded(state: 0x5EED)

        for (name, document) in corpus {
            for attempt in 0..<40 {
                var text = document
                var cache = LiveDecorator.DecorationCache(
                    source: text as NSString,
                    decorations: LiveDecorator.decorations(in: text)
                )
                for _ in 0..<6 {
                    let source = text as NSString
                    guard source.length > 2 else { break }
                    let at = random.next(source.length)
                    let deleting = random.next(3) == 0
                    let range = deleting
                        ? NSRange(
                            location: at,
                            length: min(1 + random.next(12), source.length - at)
                        )
                        : NSRange(location: at, length: 0)
                    let insert = deleting ? "" : fragments[random.next(fragments.count)]
                    // A replacement must not split a surrogate pair.
                    let safe = source.rangeOfComposedCharacterSequences(for: range)
                    let updated = source.replacingCharacters(in: safe, with: insert) as NSString

                    let expected = LiveDecorator.decorations(in: updated as String)
                    let actual = LiveDecorator.decorations(in: updated, reusing: cache)
                    if canonical(expected) == canonical(actual) {
                        result.passed += 1
                    } else {
                        result.failures.append(
                            "\(name) attempt \(attempt): replacing \(safe) with "
                                + "\(insert.debugDescription) disagreed"
                        )
                    }
                    if LiveDecorator.reuse(cache: cache, for: updated) != nil {
                        result.reused += 1
                    } else {
                        result.fellBack += 1
                    }
                    cache = LiveDecorator.DecorationCache(source: updated, decorations: actual)
                    text = updated as String
                }
            }
        }
    }

    static func run() -> Result {
        var result = Result()
        adversarial(into: &result)

        for (name, document) in corpus {
            // Edit at every position, typing and deleting, so the guards are
            // exercised against fences, tables, frontmatter and blank lines.
            for insert in ["x", " ", "*", "`", "#", "-", "|", "$", "\n"] {
                var text = document
                var cache = LiveDecorator.DecorationCache(
                    source: text as NSString,
                    decorations: LiveDecorator.decorations(in: text)
                )
                let step = max(1, (text as NSString).length / 12)
                for offset in stride(from: 0, to: (text as NSString).length, by: step) {
                    let source = text as NSString
                    let at = min(offset, source.length)
                    let updated = source.replacingCharacters(
                        in: NSRange(location: at, length: 0), with: insert
                    )
                    let expected = LiveDecorator.decorations(in: updated)
                    let actual = LiveDecorator.decorations(in: updated as NSString, reusing: cache)
                    if canonical(expected) == canonical(actual) {
                        result.passed += 1
                    } else {
                        result.failures.append(
                            "\(name): typing \(insert.debugDescription) at \(at) disagreed"
                        )
                    }
                    if LiveDecorator.reuse(cache: cache, for: updated as NSString) != nil {
                        result.reused += 1
                    } else {
                        result.fellBack += 1
                    }
                    cache = LiveDecorator.DecorationCache(source: updated as NSString, decorations: actual)
                    text = updated
                }
            }
        }
        return result
    }

}
