import AppKit
import Foundation
import HeftCore
import SwiftUI
@testable import Heft

/// What a keystroke costs on the main thread.
///
/// The number that matters is the key-repeat interval: macOS delivers a held
/// key every `KeyRepeat × 15ms`, as low as 30ms on a fast setting. Anything
/// slower than that per keystroke and a held key cannot keep up, which is what
/// "it types a-by-a instead of aaaaaaa" is.
enum TypingPerformanceCheck {
    struct Sample {
        let label: String
        let characters: Int
        let median: Double
        let worst: Double
        let restyleMedian: Double
        let restyleWorst: Double
        var total: Double { median + restyleMedian }
    }

    static func document(paragraphs: Int) -> String {
        var parts: [String] = ["# A realistic note\n"]
        for index in 0..<paragraphs {
            parts.append("""
            ## Section \(index)

            Some prose with **bold**, *italic*, `code`, a [[Wiki Link]] and a
            [markdown](https://example.com) link, plus a #tag and $x^2$ math.

            - a list item
            - another item with **bold** inside
              - a nested one

            > A quote line that goes on for a while so the line wraps.

            ```swift
            let value = \(index)
            ```

            | a | b |
            |---|---|
            | 1 | 2 |

            """)
        }
        return parts.joined(separator: "\n")
    }

    /// Formulae are bitmaps, so a note full of them is the case where a
    /// restyle that re-renders instead of reusing would show.
    static func mathHeavy() -> String {
        var parts: [String] = ["# Math\n"]
        for index in 0..<120 {
            parts.append("Paragraph \(index) with $x^{\(index)} + \\frac{a}{b}$ inline.\n")
            parts.append("$$\n\\sum_{i=0}^{\(index)} i^2\n$$\n")
        }
        return parts.joined(separator: "\n")
    }

    static func prose(words: Int) -> String {
        let vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon", "note", "vault", "editor"]
        var out = "# Long prose\n\n"
        for index in 0..<words {
            out += vocabulary[index % vocabulary.count] + (index % 18 == 17 ? "\n\n" : " ")
        }
        return out
    }

    @MainActor
    static func measureTyping(in document: String, label: String, keystrokes: Int) -> Sample {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "bench.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, context: context,
            onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = document
        coordinator.restyle(view)

        // Type into the middle of the note: the end is the easy case, because
        // there is nothing below to re-lay out.
        let caret = (document as NSString).length / 2
        var timings: [Double] = []
        var restyles: [Double] = []
        for index in 0..<keystrokes {
            view.setSelectedRange(NSRange(location: caret + index, length: 0))
            let start = DispatchTime.now().uptimeNanoseconds
            view.insertText("a", replacementRange: view.selectedRange())
            let mid = DispatchTime.now().uptimeNanoseconds
            // The restyle the edit scheduled. In the app it runs 16ms later on
            // the main thread, so its cost is part of what a held key pays.
            coordinator.restyle(view)
            let end = DispatchTime.now().uptimeNanoseconds
            timings.append(Double(mid - start) / 1_000_000)
            restyles.append(Double(end - mid) / 1_000_000)
        }
        let sorted = timings.sorted()
        let sortedRestyles = restyles.sorted()
        return Sample(
            label: label,
            characters: (document as NSString).length,
            median: sorted[sorted.count / 2],
            worst: sorted.last ?? 0,
            restyleMedian: sortedRestyles[sortedRestyles.count / 2],
            restyleWorst: sortedRestyles.last ?? 0
        )
    }

    @MainActor
    static func run() -> [Sample] {
        [
            measureTyping(in: document(paragraphs: 6), label: "small", keystrokes: 40),
            measureTyping(in: document(paragraphs: 25), label: "medium", keystrokes: 40),
            measureTyping(in: document(paragraphs: 60), label: "large", keystrokes: 40),
            measureTyping(in: document(paragraphs: 150), label: "huge", keystrokes: 30),
            measureTyping(in: mathHeavy(), label: "math-heavy", keystrokes: 30),
            measureTyping(in: prose(words: 12000), label: "long-prose", keystrokes: 30),
        ]
    }
}
