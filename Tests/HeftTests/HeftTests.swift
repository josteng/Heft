import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import Heft
@testable import HeftCore

@Suite("Heft Core")
struct HeftCoreTests {
    @Test("Parsing, formatting, links, and settings")
    func coreChecks() {
        let result = SelfCheck.run()
        for failure in result.failures {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(result.ok)
        #expect(result.passed > 0)
    }
}

@Suite("Live surface")
struct LiveSurfaceTests {
    @Test("Incremental styling matches a full restyle")
    @MainActor
    func incrementalStyling() {
        let result = IncrementalStylingCheck.run()
        for failure in result.failures.prefix(20) {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(result.ok)
        #expect(result.passed > 0)
    }
}

@Suite("Tables")
struct TableTests {
    @Test("Cell ranges, cursors, and structural edits")
    func tableChecks() {
        let result = TableCheck.run()
        for failure in result.failures {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(result.ok)
        #expect(result.passed > 0)
    }

    @Test("Editing a table in place through the real editor")
    @MainActor
    func tableSurface() {
        let result = TableSurfaceCheck.run()
        for failure in result.failures {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(result.ok)
        #expect(result.passed > 0)
    }
}

@Suite("Heft App")
struct HeftAppIntegrationTests {
    @Test("Disposable vault workflow")
    @MainActor
    func disposableVaultWorkflow() async {
        let result = await AppIntegrationCheck.run()
        for failure in result.failures {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(result.ok)
        #expect(result.passed > 0)
    }
}

@Suite("Typing performance")
struct TypingPerformanceTests {
    @Test("Reusing the previous parse is cheaper than redoing it")
    func decorationReuseCost() {
        for (label, document) in [
            ("structured 20KB", TypingPerformanceCheck.document(paragraphs: 60)),
            ("structured 50KB", TypingPerformanceCheck.document(paragraphs: 150)),
            ("prose 25KB", TypingPerformanceCheck.prose(words: 4000)),
            ("prose 74KB", TypingPerformanceCheck.prose(words: 12000)),
            ("realistic 20KB", TypingPerformanceCheck.realistic(sections: 40)),
            ("realistic 50KB", TypingPerformanceCheck.realistic(sections: 100)),
        ] {
            let source = document as NSString
            // Type into the middle of a paragraph, which is what typing is.
            let at = source.length / 2
            var full: [Double] = []
            var reused: [Double] = []
            var hits = 0
            var cache = LiveDecorator.DecorationCache(
                source: source, decorations: LiveDecorator.decorations(in: document)
            )
            for step in 0..<25 {
                let edited = cache.source.replacingCharacters(
                    in: NSRange(location: min(at + step, cache.source.length), length: 0), with: "x"
                ) as NSString

                var start = DispatchTime.now().uptimeNanoseconds
                let fromScratch = LiveDecorator.decorations(in: edited as String)
                full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

                start = DispatchTime.now().uptimeNanoseconds
                let viaCache = LiveDecorator.decorations(in: edited, reusing: cache)
                reused.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

                if LiveDecorator.reuse(cache: cache, for: edited) != nil { hits += 1 }
                cache = LiveDecorator.DecorationCache(source: edited, decorations: viaCache)
            }
            let f = full.sorted()[full.count / 2]
            let r = reused.sorted()[reused.count / 2]
            print(String(
                format: "REUSE %@: full %.2fms, reused %.2fms (%.1fx), fast path %d/25",
                label, f, r, f / max(0.001, r), hits
            ))
        }
    }

    @Test("Where a keystroke's time goes")
    func decorationCost() {
        for (label, document) in [
            ("large", TypingPerformanceCheck.document(paragraphs: 60)),
            ("huge", TypingPerformanceCheck.document(paragraphs: 150)),
            ("long-prose", TypingPerformanceCheck.prose(words: 12000)),
        ] {
            var timings: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = LiveDecorator.decorations(in: document)
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = timings.sorted()
            print(String(
                format: "DECOR %@ (%d chars): median %.1fms",
                label, (document as NSString).length, sorted[sorted.count / 2]
            ))
        }
    }

    @MainActor
    @Test("What backspace costs")
    func deletingCost() {
        for sample in TypingPerformanceCheck.runDeleting() {
            print(String(
                format: "DEL %@ (%d chars): median %.1fms, worst %.1fms, spread %.0fx",
                sample.label, sample.characters, sample.median, sample.worst,
                sample.worst / max(0.01, sample.median)
            ))
            // Deleting must coalesce while the key is held, exactly as typing
            // does. Prose is the case with nothing to force a synchronous
            // pass, so it is the one that can be held to a budget; a caret
            // inside a table deliberately styles at once and is not.
            if sample.label == "prose held" {
                #expect(
                    sample.median < 3,
                    Comment(rawValue: "held backspace costs \(sample.median)ms in prose")
                )
            }
        }
    }

    @MainActor
    @Test("A keystroke costs less than a key repeat")
    func typingCost() {
        for sample in TypingPerformanceCheck.run() {
            print(String(
                format: "PERF %@ (%d chars): insert %.1fms, restyle %.1fms (worst %.1f), TOTAL %.1fms",
                sample.label, sample.characters, sample.median,
                sample.restyleMedian, sample.restyleWorst, sample.total
            ))
            // macOS delivers a held key every `KeyRepeat × 15ms`, as little as
            // 30ms. What blocks that repeat is the work done *before* the
            // character is drawn, so that is what this guards; the styling
            // itself runs afterwards and coalesces across a burst.
            #expect(
                sample.median < 12,
                Comment(rawValue: "a keystroke blocks for \(sample.median)ms on "
                    + "\(sample.label), which a held key cannot outrun")
            )
        }
    }
}

@Suite("Incremental decoration")
struct IncrementalDecorationTests {
    @Test("Reusing the previous parse answers what a full scan would")
    func matchesFullScan() {
        let result = IncrementalDecorationCheck.run()
        for failure in result.failures.prefix(10) {
            Issue.record(Comment(rawValue: failure))
        }
        print("DECOR-DIFF \(result.passed) agreed, \(result.failures.count) disagreed, "
            + "fast path \(result.reused), fell back \(result.fellBack)")
        #expect(result.failures.isEmpty)
        #expect(result.reused > 0, "the fast path never ran, so nothing was proven")
    }
}

@Suite("Dirty scope")
struct DirtyScopeTests {
    /// Typing inside a list item must not restyle the item below it.
    ///
    /// Every dirty range used to take its neighbouring lines, so a character
    /// typed on one list line rebuilt the next line's bullet on every
    /// keystroke — visible as the dot flickering.
    @Test("Typing inside a line dirties that line alone")
    func typingStaysOnItsLine() {
        let document = "- one\n- two\n- three\n- four\n"
        let source = document as NSString
        let decorations = LiveDecorator.decorations(in: document)
        // Just before the newline, inside the first item's text.
        let at = 5
        let edited = source.replacingCharacters(
            in: NSRange(location: at, length: 0), with: "X"
        ) as NSString

        let before = RestyleScope.Snapshot(
            source: source, decorations: decorations,
            reveal: Reveal(selection: NSRange(location: at, length: 0), in: source)
        )
        let after = RestyleScope.Snapshot(
            source: edited, decorations: LiveDecorator.decorations(in: edited as String),
            reveal: Reveal(selection: NSRange(location: at + 1, length: 0), in: edited)
        )
        let dirty = RestyleScope.dirtyRanges(from: before, to: after)
        let firstLine = edited.lineRange(for: NSRange(location: 0, length: 0))
        #expect(
            dirty.allSatisfy { NSMaxRange($0) <= NSMaxRange(firstLine) },
            Comment(rawValue: "typing on line one dirtied \(dirty), past line one "
                + "(\(firstLine)), so the bullet below it is rebuilt")
        )

        // But an edit that changes what the lines *are* still takes its
        // neighbours, or their spacing and markers go stale.
        let split = source.replacingCharacters(
            in: NSRange(location: at, length: 0), with: "\n"
        ) as NSString
        let afterSplit = RestyleScope.Snapshot(
            source: split, decorations: LiveDecorator.decorations(in: split as String),
            reveal: Reveal(selection: NSRange(location: at + 1, length: 0), in: split)
        )
        let splitDirty = RestyleScope.dirtyRanges(from: before, to: afterSplit)
        #expect(
            splitDirty.contains { NSMaxRange($0) > NSMaxRange(firstLine) },
            "splitting a line must still restyle what follows it"
        )
    }
}

@Suite("List glyph stability")
@MainActor
struct ListGlyphStability {
    @Test("Typing on one list line keeps the next line's bullet")
    func bulletSurvives() {
        let document = "- one\n- two\n- three\n- four\n"
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "b.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
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

        func glyphOffsets() -> [Int] {
            view.liveLayout.blocks.compactMap { offset, widget in
                if case .list = widget { return offset }
                return nil
            }.sorted()
        }

        let before = glyphOffsets()
        #expect(before.count == 4, Comment(rawValue: "expected four bullets, got \(before)"))

        // Type inside the first item, several times, as a person would.
        for step in 0..<5 {
            coordinator.pretendLastEditWasLongAgo()
            view.setSelectedRange(NSRange(location: 5 + step, length: 0))
            view.insertText("x", replacementRange: view.selectedRange())
            let after = glyphOffsets()
            #expect(
                after.count == 4,
                Comment(rawValue: "after keystroke \(step) the bullets are \(after), "
                    + "so one vanished from the layout and is redrawn next pass")
            )
        }
    }
}

@Suite("Dirty sweep")
struct DirtySweep {
    /// Typing inside a line's own text must not restyle its neighbours.
    ///
    /// It used to, through four separate paths, and the visible result was the
    /// bullet on the line below the caret being rebuilt on every keystroke —
    /// a flicker one line down from where you are writing.
    @Test("Typing inside a line's text never reaches past it")
    func typingStaysLocal() {
        let documents: [(String, String)] = [
            ("plain list", "- one\n- two\n- three\n"),
            ("checkbox list", "- [ ] one\n- [ ] two\n- [ ] three\n"),
            ("nested list", "- one\n  - nested\n- two\n"),
            ("ordered list", "1. one\n2. two\n3. three\n"),
            ("prose then list", "Some prose here.\n- one\n- two\n"),
            ("list with bold", "- one **bold**\n- two\n"),
            ("list with link", "- see [[Note]] here\n- two\n"),
            ("heading then list", "# Title\n- one\n- two\n"),
        ]
        for (name, document) in documents {
            let source = document as NSString
            let decorations = LiveDecorator.decorations(in: document)
            for at in 1..<source.length {
                // Only positions clearly inside a line's prose: the character
                // before is a letter, so this is not the run of markers a line
                // begins with, where typing "[" really can make a checkbox.
                let previous = source.substring(with: NSRange(location: at - 1, length: 1))
                guard previous.rangeOfCharacter(from: .letters) != nil else { continue }
                let edited = source.replacingCharacters(
                    in: NSRange(location: at, length: 0), with: "x"
                ) as NSString
                let before = RestyleScope.Snapshot(
                    source: source, decorations: decorations,
                    reveal: Reveal(selection: NSRange(location: at, length: 0), in: source)
                )
                let after = RestyleScope.Snapshot(
                    source: edited,
                    decorations: LiveDecorator.decorations(in: edited as String),
                    reveal: Reveal(selection: NSRange(location: at + 1, length: 0), in: edited)
                )
                let dirty = RestyleScope.dirtyRanges(from: before, to: after)
                let line = edited.lineRange(for: NSRange(location: at, length: 0))
                #expect(
                    !dirty.contains {
                        $0.location < line.location || NSMaxRange($0) > NSMaxRange(line)
                    },
                    Comment(rawValue: "\(name): typing at \(at) dirtied \(dirty), "
                        + "past its own line \(line), so a neighbour is restyled")
                )
            }
        }
    }
}

@Suite("Reported list case")
struct ReportedListCase {
    @Test("The reported document: long wrapping list lines")
    func longLines() {
        let document = """
        - dfasdfasdfasdfasdfddddddddddddddddddddddddd
        - aasasdasdfasdffffffffffffffffffffffasdfsaaadddddddddddddddddddddddddddddddddddddddd
        - adfasdf

        """
        let source = document as NSString
        let decorations = LiveDecorator.decorations(in: document)
        var reaching: [Int] = []
        for at in 1..<source.length {
            let edited = source.replacingCharacters(
                in: NSRange(location: at, length: 0), with: "x"
            ) as NSString
            let before = RestyleScope.Snapshot(
                source: source, decorations: decorations,
                reveal: Reveal(selection: NSRange(location: at, length: 0), in: source)
            )
            let after = RestyleScope.Snapshot(
                source: edited, decorations: LiveDecorator.decorations(in: edited as String),
                reveal: Reveal(selection: NSRange(location: at + 1, length: 0), in: edited)
            )
            let dirty = RestyleScope.dirtyRanges(from: before, to: after)
            let line = edited.lineRange(for: NSRange(location: at, length: 0))
            if dirty.contains(where: {
                $0.location < line.location || NSMaxRange($0) > NSMaxRange(line)
            }) { reaching.append(at) }
        }
        print("REPORTED reaches past its line at \(reaching) of 1..<\(source.length)")
    }
}


@Suite("Widget keys during a held key")
@MainActor
struct WidgetKeysWhileRepeating {
    /// The reported case: holding a key on one list line makes the marker on
    /// the line below disappear.
    ///
    /// A held key defers its styling, so the widgets keep their pre-edit
    /// offsets for the whole repeat. A fragment rebuilt in that window asks for
    /// its widget at an offset that has moved and is handed nothing.
    @Test("A held key keeps the marker on the line below")
    func markerSurvivesARepeat() {
        let document = "- adfajjjjjjjjjjjjjjjjj\n- \n"
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(document), documentIdentity: "b.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = document
        coordinator.restyle(view)

        /// What a fragment beginning at `start` would be handed right now.
        func hasMarker(at start: Int) -> Bool {
            if case .list = coordinator.layout.blocks[coordinator.layoutKey(for: start)] {
                return true
            }
            return false
        }
        let secondLine = 24
        #expect(hasMarker(at: 0) && hasMarker(at: secondLine), "both markers to begin with")

        // Hold the key: each repeat edits the storage and defers its styling.
        var caret = 22
        for repeatIndex in 1...6 {
            coordinator.pretendEditsAreArrivingInABurst()
            view.setSelectedRange(NSRange(location: caret, length: 0))
            view.insertText("j", replacementRange: view.selectedRange())
            caret += 1
            #expect(
                hasMarker(at: secondLine + repeatIndex),
                Comment(rawValue: "after repeat \(repeatIndex) the marker on the line "
                    + "below is gone; it is keyed \(repeatIndex) characters back")
            )
        }

        // When the key is released the restyle lands and the keys are real.
        coordinator.restyle(view)
        #expect(coordinator.pendingShift == nil, "the restyle closes the window")
        #expect(hasMarker(at: secondLine + 6), "and the marker is still there")
    }
}

@Suite("Week layout")
struct WeekLayoutTests {

    /// The column the 1st lands in is the one off-by-one that stays invisible
    /// until a month happens to start on the day the week starts on.
    @Test("A month's first day lands in the right column")
    func leadingDays() {
        // September 2026 starts on a Tuesday (weekday 3).
        #expect(WeekLayout.leadingDays(firstOfMonth: 3, firstWeekday: 2) == 1)  // Monday-first
        #expect(WeekLayout.leadingDays(firstOfMonth: 3, firstWeekday: 1) == 2)  // Sunday-first
        #expect(WeekLayout.leadingDays(firstOfMonth: 3, firstWeekday: 7) == 3)  // Saturday-first

        // A month starting on the very day the week starts needs no padding,
        // and must not wrap to a whole blank row.
        for start in 1...7 {
            #expect(WeekLayout.leadingDays(firstOfMonth: start, firstWeekday: start) == 0)
        }

        // And the day before it needs a full six.
        for start in 1...7 {
            let dayBefore = (start + 5) % 7 + 1
            #expect(WeekLayout.leadingDays(firstOfMonth: dayBefore, firstWeekday: start) == 6)
        }

        // Never off the end of the grid, whatever the pairing.
        for start in 1...7 {
            for first in 1...7 {
                let leading = WeekLayout.leadingDays(firstOfMonth: first, firstWeekday: start)
                #expect(leading >= 0 && leading <= 6)
            }
        }
    }

    @Test("Column headings rotate with the first weekday")
    func symbols() {
        #expect(WeekLayout.symbols(firstWeekday: 1) == ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
        #expect(WeekLayout.symbols(firstWeekday: 2) == ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])
        #expect(WeekLayout.symbols(firstWeekday: 7) == ["Sa", "Su", "Mo", "Tu", "We", "Th", "Fr"])

        // Whatever the rotation, it is still the seven days exactly once.
        for start in 1...7 {
            #expect(Set(WeekLayout.symbols(firstWeekday: start)).count == 7)
        }
    }

    /// The heading over a column has to name the day the cells beneath it
    /// actually hold, which is the pairing the two functions are only correct
    /// about *together*.
    @Test("A day falls under its own heading")
    func headingsMatchTheGrid() {
        let names = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        for start in 1...7 {
            let headings = WeekLayout.symbols(firstWeekday: start)
            for weekday in 1...7 {
                let column = WeekLayout.leadingDays(firstOfMonth: weekday, firstWeekday: start)
                #expect(
                    headings[column] == names[weekday - 1],
                    "weekday \(weekday) with week starting \(start)"
                )
            }
        }
    }

    @Test("Every option resolves to a real weekday")
    func options() {
        for option in FirstWeekday.allCases {
            let index = option.resolved()
            #expect(index >= 1 && index <= 7, "\(option.label) resolved to \(index)")
        }
        #expect(FirstWeekday.monday.resolved() == 2)
        #expect(FirstWeekday.sunday.resolved() == 1)
        #expect(FirstWeekday.saturday.resolved() == 7)
        // System follows the locale rather than a fixed day.
        #expect(FirstWeekday.system.weekdayIndex == nil)
    }
}

@Suite("Math colour")
@MainActor
struct MathColourTests {

    /// The glyph colour is baked into the bitmap, so getting it wrong is
    /// permanent for as long as that image is cached. This is the check the
    /// `resolved(_:)` docstring asks for and that the inline path was
    /// skipping: it passed the dynamic `.textColor` straight through, and a
    /// formula on a light page came out in the dark-mode colour.
    @Test("A formula is drawn in the appearance's own text colour")
    func formulaFollowsAppearance() throws {
        func luminance(of image: NSImage) throws -> Double {
            let data = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: data))
            var total = 0.0
            var counted = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                    // Only the ink. The background is transparent, and
                    // averaging it in would drown the glyphs out.
                    guard pixel.alphaComponent > 0.5 else { continue }
                    let rgb = pixel.usingColorSpace(.sRGB) ?? pixel
                    total += 0.2126 * rgb.redComponent
                        + 0.7152 * rgb.greenComponent
                        + 0.0722 * rgb.blueComponent
                    counted += 1
                }
            }
            #expect(counted > 0, "the formula rendered no ink at all")
            return counted == 0 ? 0 : total / Double(counted)
        }

        func context(_ scheme: ColorScheme) -> RenderContext {
            var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
            context.appearance = RenderContext.appearance(for: scheme)
            return context
        }

        // Through `InlineText.pieces`, not `MathRenderer` directly: the bug
        // was never in the renderer, it was the call site handing it an
        // unresolved dynamic colour. A test that resolves the colour itself
        // would pass with the bug still in place.
        func rendered(_ scheme: ColorScheme) throws -> NSImage {
            let pieces = InlineText.pieces(
                [.math("\\frac{a}{b} + \\sqrt{c}", display: true)],
                context: context(scheme)
            )
            for piece in pieces {
                if case .mathBlock(let image, _) = piece { return image }
            }
            Issue.record("no formula was rendered for \(scheme)")
            throw CancellationError()
        }

        let light = try rendered(.light)
        let dark = try rendered(.dark)

        let lightInk = try luminance(of: light)
        let darkInk = try luminance(of: dark)

        // Dark ink on a light page, light ink on a dark one. Asserted as an
        // ordering plus a floor rather than exact values, so the check does
        // not break when a system colour is retuned.
        #expect(lightInk < 0.5, "a formula on a light page is dark ink (got \(lightInk))")
        #expect(darkInk > 0.5, "a formula on a dark page is light ink (got \(darkInk))")
        #expect(lightInk < darkInk)
    }

    @Test("Resolving without an appearance is not silently the same colour")
    func appearanceActuallyChangesResolution() {
        var light = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        light.appearance = RenderContext.appearance(for: .light)
        var dark = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        dark.appearance = RenderContext.appearance(for: .dark)
        #expect(light.resolved(.textColor) != dark.resolved(.textColor))
        #expect(light.resolved(.labelColor) != dark.resolved(.labelColor))
    }
}

@Suite("PDF export")
@MainActor
struct PDFExportTests {

    static let note = """
    # Quarterly Notes

    A paragraph with **bold**, *italic*, `code` and some $E = mc^2$ maths.

    ## A table

    | Engine | Throughput | Notes |
    | --- | ---: | :---: |
    | SGLang FP8 | ~112 t/s | **fast** |
    | vLLM FP8 | 115.1 t/s | `stable` |

    ## A list

    - first item
    - second item
      - nested item
    - [ ] an unchecked task
    - [x] a finished one

    > [!note] A callout
    > With a body worth keeping.

    $$
    \\int_0^1 x^2 \\, dx = \\frac{1}{3}
    $$
    """

    @Test("A note becomes a readable PDF")
    func exportsAPDF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("note.pdf")
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)

        #expect(PDFExport.write(text: Self.note, context: context, to: destination))
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let document = try #require(PDFDocument(url: destination))
        #expect(document.pageCount >= 1)

        // The point of exporting through the live surface is that the PDF
        // holds the *rendered* note. So the prose has to be in there, and the
        // markup that produced it must not be.
        let contents = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        #expect(contents.contains("Quarterly Notes"))
        #expect(contents.contains("second item"))
        #expect(contents.contains("A callout"))
        // Every cell of the table reached the page, which only happens if the
        // grid widget drew. Reaching for the TextKit 1 layout manager anywhere
        // in the export path drops the view back to TextKit 1, where
        // NSTextLayoutFragment does not exist and every widget silently stops
        // being drawn — the text still renders, so it reads as a styling bug.
        #expect(contents.contains("SGLang FP8"))
        #expect(contents.contains("Throughput"))

        // The markup characters are still *in* the PDF's text, because the
        // buffer equals the file and collapsing is a font change rather than a
        // deletion. So the claim worth asserting is not that they are absent,
        // it is that they are invisible.
    }

    /// The two ways the export used to come out wrong, asserted where they are
    /// actually observable: on the view the PDF is printed from.
    @Test("The exported page is laid out inside the paper, with markup hidden")
    func renderViewGeometry() throws {
        let printable: CGFloat = 483
        let view = PDFExport.renderView(
            text: Self.note,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            width: printable
        )

        // Nothing may be laid out past the page. The text view re-imposes its
        // own 28pt gutter on every frame change, so sizing the container to
        // the full printable width lays the text out 28pt too far right and
        // clips the last word of every line.
        let manager = try #require(view.textLayoutManager)
        var widest: CGFloat = 0
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            widest = max(widest, fragment.layoutFragmentFrame.maxX)
            return true
        }
        #expect(widest > 0, "nothing was laid out")
        #expect(
            widest <= printable + 1,
            "text runs \(widest - printable)pt past the right edge of the page"
        )

        // The fragment frames alone do not catch it: they are measured from
        // the container, which can itself be wider than the space left for it.
        // What clips a line is the container plus both gutters exceeding the
        // page, since the text is *drawn* offset by the leading one.
        let inset = view.textContainerInset.width
        let container = try #require(view.textContainer).size.width
        #expect(
            container + inset * 2 <= view.frame.width + 1,
            "the text area (\(container)) plus its two \(inset)pt gutters is wider than the page (\(view.frame.width))"
        )

        // No caret, so no line reveals its own block markup. With a selection
        // at 0 the first line came out with a literal `#` in the PDF.
        //
        // The hash is not merely collapsed now, it is replaced outright by a
        // zero-width space, so what is asserted is that nothing readable
        // precedes the heading rather than that the `#` is small.
        let storage = try #require(view.textStorage)
        let title = (storage.string as NSString).range(of: "Quarterly Notes")
        #expect(title.location != NSNotFound)
        let before = (storage.string as NSString)
            .substring(to: title.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            before.allSatisfy { $0 == "\u{200B}" },
            "something readable precedes the heading: \(before.debugDescription)"
        )
    }

    /// A note longer than a page has to actually paginate. Getting this wrong
    /// silently loses everything past the first page, which is the kind of
    /// thing nobody notices until they have sent the file to someone.
    @Test("A long note runs to more than one page")
    func paginates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let long = (1...240).map { "Paragraph \($0) of a note that keeps going." }
            .joined(separator: "\n\n")
        let destination = directory.appendingPathComponent("long.pdf")
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)

        #expect(PDFExport.write(text: long, context: context, to: destination))
        let document = try #require(PDFDocument(url: destination))
        #expect(document.pageCount > 1, "got \(document.pageCount) page(s)")

        let contents = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        #expect(contents.contains("Paragraph 1 of"))
        #expect(contents.contains("Paragraph 240 of"), "the last paragraph reached the PDF")
    }
}

@Suite("Quoted blocks")
struct QuotedBlockTests {

    private func quoteLines(_ source: String) -> [(line: Int, quote: QuoteLine)] {
        let text = source as NSString
        var result: [(Int, QuoteLine)] = []
        for decoration in LiveDecorator.decorations(in: source) {
            guard case .quoteLine(let quote) = decoration.style else { continue }
            var line = 1
            for index in 0..<decoration.range.location
            where text.character(at: index) == UInt16(10) { line += 1 }
            result.append((line, quote))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// The block matchers are anchored to the start of a line, so everything
    /// after a `>` used to be quoted prose: no bullet, no indent, and
    /// `> ## Heading` at body size. A quote is where a lot of real notes keep
    /// their lists.
    @Test("A list written inside a quote is a list")
    func listsInQuotes() throws {
        let found = quoteLines("""
        > - a bullet
        > - [ ] unchecked
        > - [x] checked
        > 1. first
        > 2) second
        >   - nested once
        > \tnested by tab
        """)
        #expect(found.count == 7)

        guard case .list(let kind, let depth, let marker) = found[0].quote.nested else {
            Issue.record("a plain bullet in a quote was not a list")
            return
        }
        #expect(kind == .bullet(shape: .forLevel(0)))
        #expect(depth == 0)
        #expect(marker == "- ")

        #expect(found[1].quote.nested == .list(kind: .task(.unchecked), depth: 0, marker: "- [ ] "))
        #expect(found[2].quote.nested == .list(kind: .task(.done), depth: 0, marker: "- [x] "))
        #expect(found[3].quote.nested == .list(kind: .ordered, depth: 0, marker: "1. "))
        #expect(found[4].quote.nested == .list(kind: .ordered, depth: 0, marker: "2) "))

        // Indentation is measured from where the quote's markers stop, not
        // from the start of the line, or every quoted list would read as
        // nested one level deeper than it is.
        guard case .list(_, let nestedDepth, _) = found[5].quote.nested else {
            Issue.record("an indented bullet in a quote was not a list")
            return
        }
        #expect(nestedDepth == 1)
    }

    @Test("A heading written inside a quote is a heading")
    func headingsInQuotes() {
        let found = quoteLines("""
        > # One
        > ###### Six
        > ####### Seven hashes is not a heading
        > #tag is not a heading
        > Plain quoted prose
        """)
        #expect(found.count == 5)
        #expect(found[0].quote.nested == .heading(level: 1))
        #expect(found[1].quote.nested == .heading(level: 6))
        // Seven hashes: six are taken, and the seventh is not a space, so it
        // is not a heading at all rather than an h6 whose title starts with #.
        #expect(found[2].quote.nested == nil)
        // A tag needs no space after the hash, which is exactly what tells the
        // two apart.
        #expect(found[3].quote.nested == nil)
        #expect(found[4].quote.nested == nil)
    }

    /// A callout's header line is already spoken for: `[!kind]` claims what
    /// follows the marker, and reading a bullet out of it would collapse the
    /// callout's own syntax twice.
    @Test("A callout header is not read as a nested block")
    func calloutHeaderIsNotNested() {
        let found = quoteLines("""
        > [!note] A callout
        > - with a list inside
        """)
        #expect(found.count == 2)
        #expect(found[0].quote.isCalloutHeader)
        #expect(found[0].quote.nested == nil)
        #expect(found[1].quote.nested != nil, "the body line still gets its bullet")
    }

    @Test("A marker with nothing after it is not a list")
    func strayMarkers() {
        // `-` alone, and `-text` with no space, are not list items outside a
        // quote either.
        #expect(quoteLines("> -")[0].quote.nested == nil)
        #expect(quoteLines("> -text")[0].quote.nested == nil)
        #expect(quoteLines("> 1.text")[0].quote.nested == nil)
        #expect(quoteLines("> 5 not ordered")[0].quote.nested == nil)
    }

    /// The markup that introduces the nested block has to be collapsed, or the
    /// literal `- ` sits beside the drawn bullet.
    @Test("The nested marker is collapsed with the quote's own")
    func nestedMarkerIsSyntax() throws {
        let source = "> - a bullet"
        let decoration = try #require(
            LiveDecorator.decorations(in: source).first {
                if case .quoteLine = $0.style { return true }
                return false
            }
        )
        let covered = decoration.syntax.reduce(0) { $0 + $1.length }
        #expect(covered == 4, "`> ` and `- ` are both syntax (covered \(covered))")
    }
}

@Suite("Attachment folders")
struct AttachmentFolderTests {

    private func vault(_ folders: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-attach-\(UUID().uuidString)")
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        return root
    }

    /// A vault has one attachment folder per project, not one per subfolder.
    /// Creating a second `assets` beside a note the first time something is
    /// pasted into a subfolder scatters attachments across the tree.
    @Test("A subfolder attachment path finds the nearest one above the note")
    func walksUp() throws {
        let root = try vault(["Projects/Heft/assets", "Projects/Heft/Notes"])
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = ObsidianSettings()
        settings.attachmentFolderPath = "./assets"

        let deep = root.appendingPathComponent("Projects/Heft/Notes/design.md")
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: deep).standardizedFileURL.path
                == root.appendingPathComponent("Projects/Heft/assets").standardizedFileURL.path
        )

        // A note sitting beside the folder still uses that one, not one above.
        let beside = root.appendingPathComponent("Projects/Heft/plan.md")
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: beside).standardizedFileURL.path
                == root.appendingPathComponent("Projects/Heft/assets").standardizedFileURL.path
        )
    }

    /// Nothing is created by the search, so with no such folder anywhere the
    /// answer is unchanged: beside the note.
    @Test("With none above, the folder beside the note is still the answer")
    func fallsBackBesideTheNote() throws {
        let root = try vault(["Projects/Heft/Notes"])
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = ObsidianSettings()
        settings.attachmentFolderPath = "./assets"
        let note = root.appendingPathComponent("Projects/Heft/Notes/design.md")
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: note).standardizedFileURL.path
                == root.appendingPathComponent("Projects/Heft/Notes/assets").standardizedFileURL.path
        )
    }

    /// The walk must stop at the vault. Reaching a folder of the same name
    /// outside it would write attachments into somebody else's directory.
    @Test("The walk never leaves the vault")
    func staysInsideTheVault() throws {
        let outer = try vault(["assets", "TheVault/Notes"])
        defer { try? FileManager.default.removeItem(at: outer) }
        let root = outer.appendingPathComponent("TheVault")

        var settings = ObsidianSettings()
        settings.attachmentFolderPath = "./assets"
        let note = root.appendingPathComponent("Notes/design.md")
        let resolved = settings.attachmentDirectory(vaultRoot: root, noteURL: note)
        #expect(
            resolved.standardizedFileURL.path
                == root.appendingPathComponent("Notes/assets").standardizedFileURL.path
        )
        #expect(
            resolved.standardizedFileURL.path != outer.appendingPathComponent("assets").standardizedFileURL.path,
            "an assets folder outside the vault was used"
        )
    }

    /// A file of that name is not a folder, and writing into it would fail.
    @Test("A file of the same name is not mistaken for the folder")
    func ignoresFiles() throws {
        let root = try vault(["Projects/Notes"])
        defer { try? FileManager.default.removeItem(at: root) }
        try "not a folder".write(
            to: root.appendingPathComponent("Projects/assets"),
            atomically: true, encoding: .utf8
        )

        var settings = ObsidianSettings()
        settings.attachmentFolderPath = "./assets"
        let note = root.appendingPathComponent("Projects/Notes/design.md")
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: note).standardizedFileURL.path
                == root.appendingPathComponent("Projects/Notes/assets").standardizedFileURL.path
        )
    }

    /// The other three Obsidian forms are untouched.
    @Test("The other attachment forms are unchanged")
    func otherFormsUnchanged() throws {
        let root = try vault(["Files", "Notes"])
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Notes/design.md")

        var settings = ObsidianSettings()
        #expect(settings.attachmentDirectory(vaultRoot: root, noteURL: note).path == root.path)

        settings.attachmentFolderPath = "./"
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: note).standardizedFileURL.path
                == root.appendingPathComponent("Notes").standardizedFileURL.path
        )

        settings.attachmentFolderPath = "Files"
        #expect(
            settings.attachmentDirectory(vaultRoot: root, noteURL: note).standardizedFileURL.path
                == root.appendingPathComponent("Files").standardizedFileURL.path
        )
    }
}

@Suite("Callout completion")
struct CalloutCompletionTests {

    private func detect(_ source: String) -> CalloutCompletionContext? {
        // `|` marks the caret and is removed before detection.
        let caret = (source as NSString).range(of: "|")
        let text = source.replacingOccurrences(of: "|", with: "")
        return CalloutCompletionContext.detect(
            in: text, selection: NSRange(location: caret.location, length: 0)
        )
    }

    @Test("A callout being typed is detected, and only there")
    func detection() throws {
        #expect(detect("> [!|")?.query == "")
        #expect(detect("> [!war|")?.query == "war")
        #expect(detect("> [!war|]")?.query == "war")
        #expect(detect(">[!war|")?.query == "war", "the space after > is optional")
        #expect(detect(">> [!war|")?.query == "war", "nested quotes still open callouts")
        #expect(detect("  > [!war|")?.query == "war", "so does an indented quote")

        // Not a quote at all.
        #expect(detect("[!war|") == nil)
        #expect(detect("some text [!war|") == nil)
        // `[!kind]` is only read on the line that opens the quote; on a body
        // line it is literal text, so completing there would be a trap.
        #expect(detect("> first line\n> [!war|") == nil)
        // The caret has to be in what is being typed.
        #expect(detect("> [!warning] and a title|") == nil)
        #expect(detect("|> [!warning]") == nil)
        // Something has to follow the marker.
        #expect(detect("> |") == nil)
        #expect(detect("> [|") == nil)
    }

    @Test("The closing bracket is noticed")
    func closingBracket() throws {
        #expect(try #require(detect("> [!war|]")).hasClosingBracket)
        #expect(try #require(detect("> [!war|")).hasClosingBracket == false)
    }

    @Test("Suggestions rank a prefix above a substring, and know the aliases")
    func suggestions() throws {
        let all = try #require(detect("> [!|")).suggestions()
        #expect(all.count == CalloutKind.allCases.count, "an empty query offers every kind")
        #expect(all.first?.kind == .note, "in Obsidian's own order")

        let warn = try #require(detect("> [!warn|")).suggestions()
        #expect(warn.first?.kind == .warning)

        // An alias finds the kind it spells, and says which spelling matched
        // so it is clear why `tldr` offered `abstract`.
        let tldr = try #require(detect("> [!tldr|")).suggestions()
        #expect(tldr.first?.kind == .abstract)
        #expect(tldr.first?.matchedAlias == "tldr")

        // The canonical name always outranks an alias of another kind.
        let question = try #require(detect("> [!qu|")).suggestions()
        #expect(question.first?.kind == .question)

        #expect(try #require(detect("> [!zzz|")).suggestions().isEmpty)
    }

    /// Accepting writes the canonical name. The aliases exist so a row can be
    /// found, not so one vault spells a callout four ways.
    @Test("Accepting writes the canonical name and closes the bracket")
    func accepting() throws {
        let fresh = try #require(detect("> [!warn|"))
        let edit = fresh.accepting(fresh.suggestions()[0].insertion)
        var text = "> [!warn" as NSString
        text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        #expect(text as String == "> [!warning] ")
        #expect(edit.selection.location == text.length, "the caret lands where the title goes")

        // Editing a callout that already has its bracket must not add another.
        let existing = try #require(detect("> [!warn|] Title"))
        let second = existing.accepting("warning")
        var line = "> [!warn] Title" as NSString
        line = line.replacingCharacters(in: second.range, with: second.replacement) as NSString
        #expect(line as String == "> [!warning] Title")
    }
}

@Suite("Completion surface")
@MainActor
struct CompletionSurfaceTests {

    private func editor() -> (HeftTextKit2View, LiveTextEditor.Coordinator) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(""), documentIdentity: "probe.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        return (view, coordinator)
    }

    /// The pure detector agreeing is not the same as the menu opening: the
    /// two share one panel, and the kind has to be picked before the items
    /// are built.
    @Test("Typing a callout marker opens the menu")
    func opensOnCalloutMarker() {
        let (view, _) = editor()
        view.string = "> [!"
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.updateLinkCompletion(allowStart: true)

        let offered = view.visibleCompletions
        #expect(offered.contains("note"))
        #expect(offered.contains("warning"))
        #expect(offered.count == CalloutKind.allCases.count)

        // Narrowing filters it down rather than starting again.
        view.string = "> [!warn"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: false)
        #expect(view.visibleCompletions.first == "warning")

        // And leaving the construct closes it.
        view.string = "plain text"
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.updateLinkCompletion(allowStart: false)
        #expect(view.visibleCompletions.isEmpty)
    }

    /// The menu must not appear in the middle of a word already being typed,
    /// which is what `allowStart` on a non-empty query would do.
    @Test("The menu only opens on a fresh marker")
    func opensOnlyOnAnEmptyQuery() {
        let (view, _) = editor()
        view.string = "> [!warn"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(view.visibleCompletions.isEmpty)
    }
}

@Suite("External change polling")
@MainActor
struct ExternalChangePollingTests {

    /// Reading the whole note once a second, per window, forever, is what an
    /// idle Heft was costing — a full file read per second against an
    /// iCloud-backed vault whether or not anyone was using it. The
    /// modification date now answers almost all of those without opening the
    /// file, and this is the claim that gate must not break: an edit made by
    /// another program still arrives.
    @Test("A note edited by another program is still picked up")
    func externalEditStillReloads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        try "first version\n".write(to: note, atomically: true, encoding: .utf8)

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        #expect(model.current?.relativePath == "Note.md")
        #expect(model.text == "first version\n")

        // Nothing has changed, so a poll must leave the buffer alone.
        model.reloadCurrentIfChangedExternally()
        #expect(model.text == "first version\n")

        try "second version\n".write(to: note, atomically: true, encoding: .utf8)
        model.reloadCurrentIfChangedExternally()
        #expect(model.text == "second version\n", "an external edit reached the buffer")
    }

    /// The date is only trusted once it has stood long enough to be: a write
    /// landing in the same second as the one already recorded can leave the
    /// timestamp untouched, so a fresh file is always read rather than
    /// dismissed on a matching date.
    @Test("A same-second rewrite is not dismissed on a matching date")
    func sameSecondRewriteIsRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        try "first\n".write(to: note, atomically: true, encoding: .utf8)
        // Stamped through the same path both times, so the two reads really
        // are the same date rather than two doubles that merely print alike.
        let stamp = Date()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: note.path)

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )

        // Rewritten with the modification date the model already recorded,
        // which is exactly what a write in the same second looks like.
        try "rewritten\n".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: note.path)

        model.reloadCurrentIfChangedExternally()
        #expect(model.text == "rewritten\n", "a same-second rewrite was skipped on a matching date")
    }
}

@Suite("Obsidian comments")
struct ObsidianCommentTests {

    private func comments(_ source: String) -> [String] {
        let text = source as NSString
        return LiveDecorator.decorations(in: source).compactMap { decoration in
            guard case .comment = decoration.style else { return nil }
            return text.substring(with: decoration.range)
        }
    }

    /// A vault written in Obsidian is full of `%%` comments, and they showed
    /// here as literal text, percent signs and all.
    @Test("Both comment spellings are comments")
    func bothSpellings() {
        #expect(comments("Before %%hidden%% after.") == ["%%hidden%%"])
        #expect(comments("Before <!--hidden--> after.") == ["<!--hidden-->"])
        #expect(comments("%%\nA block\nspanning lines\n%%") == ["%%\nA block\nspanning lines\n%%"])
    }

    /// The two shapes are matched separately on purpose. One loose pattern for
    /// both would let an *inline* comment leap across lines and swallow the
    /// prose between two unrelated `%%` — which prose about percentages
    /// really can contain.
    @Test("An inline comment cannot swallow the lines between two percentages")
    func inlineDoesNotSpanLines() {
        let found = comments("Grew 20%% last year.\n\nShrank 5%% this year.")
        #expect(found.isEmpty, "matched \(found)")
    }

    @Test("A comment inside a fence is code, not a comment")
    func fencesWin() {
        #expect(comments("```\n%%not a comment%%\n```").isEmpty)
        #expect(comments("```\n<!-- not a comment -->\n```").isEmpty)
    }

    @Test("A lone marker is not a comment")
    func loneMarkers() {
        #expect(comments("100% done").isEmpty)
        #expect(comments("A %% with no partner").isEmpty)
    }
}

@Suite("Footnotes")
struct FootnoteTests {

    private func footnotes(_ source: String) -> [(kind: String, label: String, text: String)] {
        let text = source as NSString
        return LiveDecorator.decorations(in: source).compactMap { decoration in
            switch decoration.style {
            case .footnoteReference(let label):
                ("ref", label, text.substring(with: decoration.range))
            case .footnoteDefinition(let label):
                ("def", label, text.substring(with: decoration.range))
            default:
                nil
            }
        }
    }

    @Test("References and definitions are told apart")
    func detection() {
        let found = footnotes("""
        A claim[^1] and another[^cox].

        [^1]: First note.
        [^cox]: Second note.
        """)
        #expect(found.filter { $0.kind == "ref" }.map(\.label) == ["1", "cox"])
        #expect(found.filter { $0.kind == "def" }.map(\.label) == ["1", "cox"])

        // A definition is not a reference that happens to be followed by a
        // colon, which is why definitions are matched first.
        #expect(footnotes("[^1]: A note").allSatisfy { $0.kind == "def" })
    }

    @Test("A label may repeat, and each use is its own reference")
    func repeatedLabels() {
        let refs = footnotes("One[^1] and again[^1].").filter { $0.kind == "ref" }
        #expect(refs.count == 2)
        #expect(refs.allSatisfy { $0.label == "1" })
    }

    @Test("Bracket pairs that are not footnotes are left alone")
    func nonFootnotes() {
        #expect(footnotes("[a link](https://example.com)").isEmpty)
        #expect(footnotes("[^ ] has a space").isEmpty)
        #expect(footnotes("[^] is empty").isEmpty)
        #expect(footnotes("A caret ^ on its own").isEmpty)
        #expect(footnotes("[plain]").isEmpty)
    }

    /// A reference is an inline span and reveals only with the caret inside
    /// it, or a sentence with three footnotes in it would dissolve into
    /// brackets the moment it was clicked. A definition owns its line.
    @Test("A reference reveals per caret, a definition per line")
    func revealPolicy() {
        #expect(!Reveal.revealsWithItsLine(.footnoteReference(label: "1")))
        #expect(Reveal.revealsWithItsLine(.footnoteDefinition(label: "1")))
    }

    /// The markers hide and the label stays, so a collapsed reference is the
    /// bare number and a definition still reads as the numbered note it is.
    @Test("Only the brackets are markup")
    func syntaxRanges() throws {
        let source = "A claim[^12] here."
        let decoration = try #require(
            LiveDecorator.decorations(in: source).first {
                if case .footnoteReference = $0.style { return true }
                return false
            }
        )
        let text = source as NSString
        let hidden = decoration.syntax.map { text.substring(with: $0) }
        #expect(hidden == ["[^", "]"])
        #expect(text.substring(with: decoration.range) == "[^12]")
    }
}

@Suite("Task states")
struct TaskStateTests {

    private func kinds(_ source: String) -> [ListMarkerKind] {
        LiveDecorator.decorations(in: source).compactMap {
            guard case .listMarker(let kind, _) = $0.style else { return nil }
            return kind
        }
    }

    /// Obsidian puts a checkbox on any `- [c]` and carries the character
    /// through for a theme to style, which is where `[/]`, `[-]` and `[>]`
    /// come from. Reading only `[ ]` and `[x]` made every one of those render
    /// as a plain bullet, so a note full of half-done work looked like prose.
    @Test("Any single character between the brackets is a task")
    func customStates() {
        #expect(kinds("- [ ] a") == [.task(.unchecked)])
        #expect(kinds("- [x] a") == [.task(.done)])
        #expect(kinds("- [X] a") == [.task(.done)])
        #expect(kinds("- [/] a") == [.task(.other("/"))])
        #expect(kinds("- [-] a") == [.task(.other("-"))])
        #expect(kinds("- [>] a") == [.task(.other(">"))])
        #expect(kinds("- [?] a") == [.task(.other("?"))])
        #expect(kinds("- [!] a") == [.task(.other("!"))])
    }

    /// Only `[x]` is finished. `[/]` is in progress and `[-]` is abandoned,
    /// and striking either through would say the work was completed.
    @Test("Only a ticked task counts as done")
    func onlyTickedIsDone() {
        #expect(TaskState(marker: "x").isDone)
        #expect(TaskState(marker: "X").isDone)
        #expect(!TaskState(marker: " ").isDone)
        #expect(!TaskState(marker: "/").isDone)
        #expect(!TaskState(marker: "-").isDone)
        #expect(!TaskState(marker: ">").isDone)
    }

    @Test("Brackets that are not a task stay a plain bullet")
    func notTasks() {
        // Two characters is not a state.
        #expect(kinds("- [ab] a") == [.bullet(shape: .forLevel(0))])
        // No brackets at all.
        #expect(kinds("- plain") == [.bullet(shape: .forLevel(0))])
        #expect(kinds("1. plain") == [.ordered])
        // An ordered *task* is still a task: the box wins over the numeral,
        // which is what Obsidian draws for `1. [ ] a` too.
        #expect(kinds("1. [ ] a") == [.task(.unchecked)])
    }

    /// The same reading applies inside a quote, where the marker is found by
    /// a separate hand-written scan rather than by the list regex.
    @Test("A quoted task reads its state the same way")
    func quotedTasks() {
        func quoted(_ source: String) -> QuotedBlock? {
            for decoration in LiveDecorator.decorations(in: source) {
                if case .quoteLine(let quote) = decoration.style { return quote.nested }
            }
            return nil
        }
        #expect(quoted("> - [ ] a") == .list(kind: .task(.unchecked), depth: 0, marker: "- [ ] "))
        #expect(quoted("> - [x] a") == .list(kind: .task(.done), depth: 0, marker: "- [x] "))
        #expect(quoted("> - [/] a") == .list(kind: .task(.other("/")), depth: 0, marker: "- [/] "))
    }
}

@Suite("Presentation deck")
struct PresentationDeckTests {

    private func slideCount(_ source: String) -> Int {
        PresentationDeck.slides(from: MarkdownModel.parse(source).blocks).count
    }

    @Test("A top-level rule starts the next slide")
    func splitsOnRules() {
        #expect(slideCount("One\n\n---\n\nTwo") == 2)
        #expect(slideCount("One\n\n***\n\nTwo\n\n___\n\nThree") == 3)
        #expect(slideCount("Just one slide") == 1)
        // A note with nothing in it is still a deck of one, not of none.
        #expect(slideCount("") == 1)
    }

    /// The three `---` that must not split a note, all of which appear in an
    /// ordinary note and would otherwise fill a deck with blank slides.
    @Test("Frontmatter, fences and table rows are not slide breaks")
    func nonBreaks() {
        #expect(slideCount("---\ntags: [a]\n---\n\nOnly slide") == 1)
        #expect(slideCount("Text\n\n```\n---\n```\n\nMore") == 1)
        #expect(slideCount("| a | b |\n| --- | --- |\n| 1 | 2 |") == 1)
        // `---` under a paragraph is a setext heading, not a rule.
        #expect(slideCount("A Heading\n---\n\nBody") == 1)
    }
}

@Suite("Daily capture")
struct DailyCaptureTests {

    private func stamp(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components)!
    }

    /// Capturing into a note that happens to be empty used to leave a bare
    /// `- 14:32 …` as the whole file: no title, and the first thing in the
    /// note a bullet with nothing above it to write under. `Inbox.md` already
    /// scaffolded itself; the daily note did not.
    @Test("An empty note gets a heading before its first item")
    func scaffoldsAnEmptyNote() throws {
        let written = try DailyNoteCapture.contents(
            byCapturing: "first thought", in: "", at: stamp(14, 32), title: "2026-09-03"
        )
        #expect(written == "# 2026-09-03\n\n- 14:32 first thought\n")

        // A note left holding only whitespace is empty for this purpose: a
        // stray newline should not be the difference between a titled note
        // and an untitled one.
        let fromBlank = try DailyNoteCapture.contents(
            byCapturing: "first thought", in: "\n\n", at: stamp(14, 32), title: "2026-09-03"
        )
        #expect(fromBlank == "# 2026-09-03\n\n- 14:32 first thought\n")
    }

    @Test("A note with content is appended to, not rewritten")
    func appendsToAnExistingNote() throws {
        let written = try DailyNoteCapture.contents(
            byCapturing: "second", in: "# 2026-09-03\n\n- 09:00 first\n",
            at: stamp(14, 32), title: "2026-09-03"
        )
        #expect(written == "# 2026-09-03\n\n- 09:00 first\n- 14:32 second\n")
    }

    /// The marker is the insertion point, and the *last* one wins: a body
    /// pasted in or accepted from a proposal can bring a second, and taking
    /// the first would split a day's log in two.
    @Test("Items land above the last daily-log marker")
    func insertsAboveTheLastMarker() throws {
        let note = """
        # 2026-09-03

        ## Log
        <!-- heft:daily-log -->

        ## Pasted
        <!-- heft:daily-log -->

        ## Notes

        """
        let written = try DailyNoteCapture.contents(
            byCapturing: "an item", in: note, at: stamp(14, 32), title: "2026-09-03"
        )
        let markers = written.components(separatedBy: DailyNoteCapture.insertionMarker).count - 1
        #expect(markers == 2, "both markers survive")
        let item = try #require(written.range(of: "- 14:32 an item"))
        let firstMarker = try #require(written.range(of: DailyNoteCapture.insertionMarker))
        #expect(item.lowerBound > firstMarker.upperBound, "the item went to the later marker")
    }

    @Test("Nothing is captured from nothing")
    func rejectsEmptyCaptures() {
        #expect(throws: DailyNoteCaptureError.self) {
            try DailyNoteCapture.contents(byCapturing: "   \n ", in: "", at: stamp(9, 0))
        }
    }
}

@Suite("Emphasis while typing")
@MainActor
struct PendingEmphasisTests {

    /// Whether the character at `offset` is drawn bold / italic once the
    /// document has been styled with the caret at `caret`.
    private func traits(_ source: String, caret: Int, at offset: Int) -> (bold: Bool, italic: Bool) {
        let storage = NSTextStorage(string: source)
        let text = source as NSString
        _ = LiveStyler.apply(
            to: storage,
            reveal: Reveal(selection: NSRange(location: caret, length: 0), in: text),
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 600
        )
        let font = storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        return (traits.contains(.boldFontMask), traits.contains(.italicFontMask))
    }

    /// `**bold**` only styled once the closing pair arrived, so text stayed
    /// plain until the span was finished. Obsidian styles from the opening
    /// delimiter.
    @Test("An unclosed delimiter styles the text after it")
    func stylesWhileTyping() {
        let source = "Typing **bold now"
        let offset = (source as NSString).range(of: "bold now").location
        #expect(traits(source, caret: source.count, at: offset).bold)

        let italic = "Typing *slanted now"
        let slanted = (italic as NSString).range(of: "slanted now").location
        #expect(traits(italic, caret: italic.count, at: slanted).italic)
    }

    /// The whole safety of the feature. An unclosed `*` left in a note years
    /// ago must not italicise the rest of its line forever, so the styling
    /// only lands on the line the caret is on.
    @Test("It applies only on the caret's line")
    func onlyOnTheCaretLine() {
        let source = "Typing **bold now\n\nA later paragraph."
        let offset = (source as NSString).range(of: "bold now").location
        #expect(traits(source, caret: source.count, at: offset).bold == false)
        #expect(traits(source, caret: offset, at: offset).bold)
    }

    /// The delimiter stays on screen while the span is open: it carries no
    /// `syntax`, so nothing is collapsed. An unclosed `**` is literal text in
    /// the file and hiding it would misrepresent it.
    @Test("The open delimiter is not hidden")
    func delimiterStaysVisible() {
        let source = "Typing **bold now"
        let stars = (source as NSString).range(of: "**").location
        let storage = NSTextStorage(string: source)
        _ = LiveStyler.apply(
            to: storage,
            reveal: Reveal(selection: NSRange(location: source.count, length: 0), in: source as NSString),
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 600
        )
        let font = storage.attribute(.font, at: stars, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 0) > 1, "the open `**` was collapsed")
    }

    /// The finished span is coloured as well as weighted, so styling only the
    /// weight while typing made a span change appearance twice — once as it
    /// opened and again as it closed — which reads as a glitch rather than as
    /// the span being completed.
    @Test("Emphasis being typed takes the same colour as a finished span")
    func coloursWhileTyping() {
        func colour(_ source: String, at offset: Int) -> NSColor? {
            let storage = NSTextStorage(string: source)
            var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
            context.colorfulFormatting = true
            _ = LiveStyler.apply(
                to: storage,
                reveal: Reveal(
                    selection: NSRange(location: source.count, length: 0), in: source as NSString
                ),
                context: context,
                contentWidth: 600
            )
            return storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        }

        let open = "Typing **bold now"
        let closed = "Typing **bold now**"
        let offset = (open as NSString).range(of: "bold now").location
        #expect(colour(open, at: offset) == colour(closed, at: offset))
        #expect(colour(open, at: offset) == AppearanceSettings.defaultBoldColor)

        let openItalic = "Typing *slanted now"
        let italicOffset = (openItalic as NSString).range(of: "slanted now").location
        #expect(colour(openItalic, at: italicOffset) == AppearanceSettings.defaultItalicColor)
    }

    @Test("Things that are not emphasis are left alone")
    func notEmphasis() {
        // A space after the delimiter means it cannot open.
        #expect(!traits("Cost is 5 * 3 dollars", caret: 21, at: 14).italic)
        // `_` never opens inside a word.
        #expect(!traits("A snake_case name", caret: 17, at: 14).italic)
        // A list marker is a marker, not an opening delimiter.
        #expect(!traits("* an item", caret: 9, at: 4).italic)
    }

    /// A closed span keeps its own styling and does not also start a pending
    /// one, which is what `closedStarts` is for.
    @Test("A closed span is not also treated as open")
    func closedSpansWin() {
        let source = "Closed **bold** and plain after."
        let after = (source as NSString).range(of: "and plain after").location
        #expect(!traits(source, caret: source.count, at: after).bold)
        let inside = (source as NSString).range(of: "bold").location
        #expect(traits(source, caret: source.count, at: inside).bold)
    }
}

@Suite("Command line spec")
struct CommandLineSpecTests {

    /// Reads a source file by *name*, wherever under `Sources/` it lives.
    ///
    /// Deliberately not by path. What this check is about is the dispatch
    /// table agreeing with `CommandLineSpec`, which is a fact about the code
    /// rather than about which target holds it — and a hard-coded path turns
    /// moving a file between targets into two failing tests that say nothing
    /// about the invariant. It still fails loudly on a name that is missing
    /// or ambiguous, because either means the scrape below is reading
    /// something other than what it thinks.
    private func source(named name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let found = FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == name } ?? []
        guard found.count == 1 else {
            Issue.record("expected exactly one \(name) under Sources/, found \(found.count)")
            return ""
        }
        return try String(contentsOf: found[0], encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: full).compactMap { match in
            // A pattern with no capture group has nothing at index 1, and
            // asking for it raises rather than returning nil.
            guard match.numberOfRanges > 1 else { return nil }
            return Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// `CommandLineSpec` is what `heft help` prints and what `install.sh`
    /// bakes into the shell wrapper, so a verb missing from it is a verb no
    /// agent can discover and the wrapper turns into `heft open <verb>`.
    /// That is not hypothetical: it is what happened to `heft export`.
    @Test("Every dispatched verb is in the spec")
    func specCoversDispatch() throws {
        let main = try source(named: "Main.swift")
        let agent = try source(named: "AgentCLI.swift")

        // `[a-z]` first, so the `--help` and `-h` aliases compared on the same
        // line are not mistaken for verbs of their own.
        var dispatched = matches(#"arguments\.first == "([a-z][a-z-]*)""#, in: main)
        dispatched.formUnion(matches(#"case "([a-z-]+)": \w+\(root:"#, in: agent))
        // The vault queries share one dispatch line rather than a comparison
        // each, so they are scraped from the list that line matches against.
        if let line = main.range(of: #"\[("[a-z]+", )+"[a-z]+"\]\.contains\(verb\)"#,
                                 options: .regularExpression) {
            dispatched.formUnion(matches(#""([a-z-]+)""#, in: String(main[line])))
        } else {
            Issue.record("the vault-query dispatch list moved; this scrape needs updating")
        }
        #expect(dispatched.count >= 14, "the scrape found only \(dispatched.sorted())")

        let declared = Set(CommandLineSpec.verbs.map(\.name))
        let missing = dispatched.subtracting(declared).sorted()
        #expect(missing.isEmpty, "not in CommandLineSpec: \(missing.joined(separator: ", "))")
    }

    /// And nothing is promised that does not exist, which would send an agent
    /// after a verb the binary rejects.
    @Test("Every declared verb is dispatched")
    func dispatchCoversSpec() throws {
        let main = try source(named: "Main.swift")
        let agent = try source(named: "AgentCLI.swift")
        let combined = main + agent
        for verb in CommandLineSpec.verbs {
            // `help` is dispatched through `wantsHelp` rather than by a
            // literal comparison, precisely so that no-arguments cannot be
            // mistaken for a help request.
            if verb.name == "help" {
                #expect(combined.contains("CommandLineSpec.wantsHelp"))
                continue
            }
            #expect(
                combined.contains("\"\(verb.name)\""),
                "`heft \(verb.name)` is promised by the spec but never dispatched"
            )
        }
    }

    /// The wrapper is generated by asking the binary, so this is the contract
    /// `install.sh` depends on.
    @Test("The verb list is machine-readable")
    func verbNamesAreUsable() {
        let names = CommandLineSpec.verbNames.split(separator: "\n").map(String.init)
        #expect(names.count == CommandLineSpec.verbs.count)
        #expect(names.contains("export"))
        #expect(names.contains("backlinks"))
        // A verb name with a shell metacharacter would break the `case` arm it
        // is pasted into.
        for name in names {
            #expect(
                name.allSatisfy { $0.isLowercase || $0 == "-" },
                "`\(name)` is not safe to paste into the wrapper's case statement"
            )
        }
    }

    /// No arguments must never mean "print help".
    ///
    /// That is how the Dock, Finder and `open` launch a Mac app. Treating it
    /// as a help request made Heft print usage to a stdout nobody was reading
    /// and exit — one bounce in the Dock and no window — and it shipped that
    /// way until someone tried to open the app.
    @Test("An empty command line starts the app, it does not ask for help")
    func emptyArgumentsAreNotAHelpRequest() {
        #expect(!CommandLineSpec.wantsHelp([]), "a bare app launch was taken as a help request")
        #expect(!CommandLineSpec.wantsHelp([""]))
        // A path is a path, even one that looks like a word.
        #expect(!CommandLineSpec.wantsHelp(["/Users/someone/Vault"]))
        #expect(!CommandLineSpec.wantsHelp(["helpful-notes.md"]))
        // And the real requests still are ones.
        #expect(CommandLineSpec.wantsHelp(["help"]))
        #expect(CommandLineSpec.wantsHelp(["--help"]))
        #expect(CommandLineSpec.wantsHelp(["-h"]))
        #expect(CommandLineSpec.wantsHelp(["help", "--json"]))
    }

    @Test("Help is complete and parseable")
    func helpIsUsable() throws {
        let text = CommandLineSpec.helpText()
        for verb in CommandLineSpec.verbs where verb.name != "open" && verb.name != "help" {
            #expect(text.contains("heft \(verb.name)"), "`\(verb.name)` is missing from help")
        }
        // The JSON form is what an agent reads, so it has to survive a decode.
        let data = Data(CommandLineSpec.helpJSON().utf8)
        let decoded = try JSONDecoder().decode([CommandLineSpec.Verb].self, from: data)
        #expect(decoded == CommandLineSpec.verbs)
        // Every verb says something about itself.
        for verb in decoded {
            #expect(!verb.summary.isEmpty, "`\(verb.name)` has no summary")
        }
    }

    /// `stats` and `render` are documented as safe against a live vault, and
    /// the new query verbs are too. Anything that writes must not claim to be.
    @Test("Read-only verbs are the ones that only read")
    func readOnlyIsHonest() {
        let writes = ["open", "propose", "drop", "daily", "export", "agent-setup", "rename"]
        for verb in CommandLineSpec.verbs {
            #expect(
                verb.isReadOnly == !writes.contains(verb.name),
                "`\(verb.name)` claims isReadOnly == \(verb.isReadOnly)"
            )
        }
    }
}

@Suite("Menu anchors")
struct MenuAnchorTests {

    /// A `CommandGroup(after: X)` whose anchor `X` is also *replaced*
    /// elsewhere in the same `Commands` body hangs from nothing: the item
    /// lands in no menu, and a menu item that is not in a menu has no working
    /// key equivalent. Export as PDF was attached `after: .saveItem` while
    /// `.saveItem` was replaced twenty lines further down, which presented as
    /// "⇧⌘E does nothing" and looked for all the world like a reserved system
    /// shortcut.
    ///
    /// Read from the source because the failure is a placement one: it
    /// compiles, it runs, and the only symptom is a menu item that is not
    /// there.
    @Test("No command group anchors on a placement that is replaced")
    func noAnchorOnAReplacedGroup() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Heft/HeftApp.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        func placements(_ verb: String) -> Set<String> {
            let pattern = #"CommandGroup\(\#(verb): \.([A-Za-z]+)\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let full = NSRange(source.startIndex..., in: source)
            return Set(regex.matches(in: source, range: full).compactMap {
                Range($0.range(at: 1), in: source).map { String(source[$0]) }
            })
        }

        let replaced = placements("replacing")
        let anchored = placements("after").union(placements("before"))
        #expect(!replaced.isEmpty, "the scrape found no replaced groups")
        #expect(!anchored.isEmpty, "the scrape found no anchored groups")

        let broken = anchored.intersection(replaced).sorted()
        #expect(
            broken.isEmpty,
            "anchored on a replaced group: \(broken.joined(separator: ", "))"
        )
    }
}

@Suite("PDF export options")
@MainActor
struct PDFExportOptionsTests {

    private func export(
        _ text: String, _ options: PDFExportOptions, title: String? = nil
    ) throws -> PDFDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-opts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("out.pdf")
        #expect(PDFExport.write(
            text: text, context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            to: url, title: title, options: options
        ))
        let document = try #require(PDFDocument(url: url))
        try? FileManager.default.removeItem(at: directory)
        return document
    }

    private static let note = (1...90)
        .map { "## Section \($0)\n\nA paragraph of body text that is long enough to wrap." }
        .joined(separator: "\n\n")

    /// The whole point of the feature. The editor's type is sized to be read
    /// on a display at arm's length; printed at that size the same note ran to
    /// four pages where Obsidian took three.
    @Test("Text size changes how much fits on a page")
    func sizeChangesDensity() throws {
        let small = try export(Self.note, PDFExportOptions(bodyPointSize: 9)).pageCount
        let medium = try export(Self.note, PDFExportOptions(bodyPointSize: 12)).pageCount
        let full = try export(Self.note, PDFExportOptions(bodyPointSize: 15)).pageCount
        #expect(small < medium, "9pt took \(small) pages, 12pt took \(medium)")
        #expect(medium < full, "12pt took \(medium) pages, 15pt took \(full)")
    }

    /// The editor draws body text at 15, which is chosen to be read on a
    /// display; paper wants around 10-12.
    @Test("The default is smaller than the editor's own size")
    func defaultIsDownscaled() {
        #expect(PDFExportOptions().bodyPointSize == 12)
        #expect(PDFExportOptions().scale(forEditorBodySize: 15) == 0.8)
        #expect(PDFExportOptions(bodyPointSize: 15).scale(forEditorBodySize: 15) == 1)
    }

    /// The printed size is asked for in absolute points, so it must not move
    /// when the editor's own size does. That is the whole reason it is no
    /// longer stored as a percentage of it.
    @Test("The printed size does not follow the editor's size")
    func sizeIsAbsolute() {
        let options = PDFExportOptions(bodyPointSize: 12)
        for editorSize in [12.0, 15.0, 20.0, 30.0] {
            let printed = options.scale(forEditorBodySize: editorSize) * editorSize
            #expect(abs(printed - 12) < 0.001, "editor at \(editorSize) printed \(printed)")
        }
        // And a nonsense editor size cannot produce a nonsense scale.
        #expect(options.scale(forEditorBodySize: 0) == 1)
    }

    @Test("A size outside the range is clamped, not obeyed")
    func sizeIsClamped() {
        #expect(
            PDFExportOptions(bodyPointSize: 1).bodyPointSize
                == PDFExportOptions.bodySizeRange.lowerBound
        )
        #expect(
            PDFExportOptions(bodyPointSize: 900).bodyPointSize
                == PDFExportOptions.bodySizeRange.upperBound
        )
    }

    /// Measured off the finished page, not inferred.
    ///
    /// A point is 1/72 inch and the print system works in them, so this is the
    /// same on any display: what is asserted is that asking for N points puts
    /// N points on the paper.
    @Test("The text on the page really is the size that was asked for")
    func printedSizeIsMeasured() throws {
        func height(_ points: Double) throws -> CGFloat {
            let document = try export(
                "Hedgehog paragraph.", PDFExportOptions(bodyPointSize: points)
            )
            let selection = try #require(
                document.findString("Hedgehog", withOptions: [.literal]).first
            )
            let page = try #require(selection.pages.first)
            return selection.bounds(for: page).height
        }

        let small = try height(8)
        let medium = try height(12)
        let large = try height(16)

        // Linear in the requested size.
        #expect(abs(medium / small - 1.5) < 0.05, "8pt gave \(small), 12pt gave \(medium)")
        #expect(abs(large / small - 2.0) < 0.05, "8pt gave \(small), 16pt gave \(large)")

        // And the right magnitude: a line box is a little taller than the font
        // it holds, never several times it.
        for (points, measured) in [(8.0, small), (12.0, medium), (16.0, large)] {
            let ratio = Double(measured) / points
            #expect(ratio > 1 && ratio < 1.4, "\(points)pt measured \(measured), ratio \(ratio)")
        }
    }

    @Test("Paper size and orientation reach the page")
    func paperAndOrientation() throws {
        let short = "One short line."
        func size(_ options: PDFExportOptions) throws -> CGSize {
            let page = try #require(try export(short, options).page(at: 0))
            return page.bounds(for: .mediaBox).size
        }

        let a4 = try size(PDFExportOptions())
        #expect(abs(a4.width - 595) <= 1 && abs(a4.height - 842) <= 1, "A4 was \(a4)")

        let letter = try size(PDFExportOptions(paper: .letter))
        #expect(abs(letter.width - 612) <= 1 && abs(letter.height - 792) <= 1, "Letter was \(letter)")

        let landscape = try size(PDFExportOptions(isLandscape: true))
        #expect(landscape.width > landscape.height, "landscape was \(landscape)")
    }

    /// The note's name is not in its body, so an exported note otherwise
    /// arrives untitled.
    @Test("The note's name is added only when asked for")
    func titleIsOptional() throws {
        let body = "Just the body, no heading.\n"
        let without = try export(body, PDFExportOptions(), title: "Meeting Notes")
        let with = try export(body, PDFExportOptions(includesTitle: true), title: "Meeting Notes")

        func text(_ document: PDFDocument) -> String {
            (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        }
        #expect(!text(without).contains("Meeting Notes"))
        #expect(text(with).contains("Meeting Notes"))

        // Nothing is invented when there is no name to add.
        let unnamed = try export(body, PDFExportOptions(includesTitle: true), title: nil)
        #expect(text(unnamed).contains("Just the body"))
    }

    /// Every page carries text.
    ///
    /// The view is built to be *exactly* page-width once scaled, so with
    /// `horizontalPagination = .automatic` a rounding error of a fraction of a
    /// point made it a hair too wide and AppKit split it into two
    /// page-columns: the note came out as content, blank page, content, blank
    /// page. It appeared only at the narrowest margin, where the arithmetic
    /// lands exactly on the boundary, which is why every margin is checked.
    @Test("No margin produces blank pages")
    func noBlankPages() throws {
        for margin in PDFExportOptions.Margin.allCases {
            for size in [9.0, 12.0, 15.0] {
                let document = try export(
                    Self.note, PDFExportOptions(margin: margin, bodyPointSize: size)
                )
                for index in 0..<document.pageCount {
                    let page = try #require(document.page(at: index))
                    let ink = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(
                        !ink.isEmpty,
                        "page \(index + 1) of \(document.pageCount) is blank at \(margin.label) \(Int(size))pt"
                    )
                }
            }
        }
    }

    /// The trim must never eat a real page. A note ending in a table is the
    /// case that would expose it: a table is *drawn* by a layout fragment, so
    /// a text-based emptiness test would call its page blank and delete the
    /// end of the document.
    @Test("Trailing content is never trimmed away")
    func keepsTrailingContent() throws {
        let table = """


            | Engine | Throughput |
            | --- | --- |
            | SGLang | 112 t/s |
            | vLLM | 115 t/s |
            """
        let note = (1...70).map { "Paragraph \($0) of a note that keeps going." }
            .joined(separator: "\n\n") + table

        let document = try export(note, PDFExportOptions())
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }.joined()
        #expect(text.contains("Paragraph 70 of"), "the last paragraph was trimmed away")
        #expect(text.contains("115 t/s"), "the closing table was trimmed away")

        // And the pages that remain all carry something.
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(!(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// A wider margin leaves less room for text, so the same note needs more
    /// pages. Asserted through the output rather than by reading the setting
    /// back, which would prove only that a number was stored.
    @Test("Margins reach the page")
    func marginsApply() throws {
        let narrow = try export(Self.note, PDFExportOptions(margin: .narrow)).pageCount
        let wide = try export(Self.note, PDFExportOptions(margin: .wide)).pageCount
        #expect(narrow < wide, "narrow took \(narrow) pages, wide took \(wide)")
    }
}

@Suite("Export settings persistence")
struct PDFExportSettingsTests {

    /// The panel has to open showing what was last used, or every export is
    /// five decisions again.
    @Test("Options survive a round trip")
    func roundTrip() {
        let chosen = PDFExportOptions(
            paper: .legal, isLandscape: true, margin: .wide,
            bodyPointSize: 9.5, includesTitle: true
        )
        #expect(PDFExportOptions(decoding: chosen.encoded) == chosen)
    }

    /// A settings file from an older version, or a hand-edited one, must not
    /// stop the export working.
    @Test("Missing or corrupt settings fall back to the defaults")
    func survivesBadData() {
        #expect(PDFExportOptions(decoding: nil) == PDFExportOptions())
        #expect(PDFExportOptions(decoding: Data("not json".utf8)) == PDFExportOptions())
        #expect(PDFExportOptions(decoding: Data()) == PDFExportOptions())
    }

    /// Decoding re-runs the initialiser, so a stale file cannot put an
    /// out-of-range size into the print system.
    @Test("A stored size outside the range is clamped on the way back in")
    func clampsOnDecode() {
        // Written by hand, because the initialiser would have clamped it.
        let json = Data(#"{"colours":"paper","paper":"a4","isLandscape":false,"margin":"normal","bodyPointSize":9000,"includesTitle":false}"#.utf8)
        #expect(PDFExportOptions(decoding: json).bodyPointSize == PDFExportOptions.bodySizeRange.upperBound)
    }

    /// A file written before a setting existed must keep everything it did
    /// say. The synthesised `Codable` requires every field, so adding one
    /// made every older file undecodable and silently reset the lot.
    @Test("A settings file older than the code keeps what it does say")
    func toleratesMissingFields() {
        // No `colours` key: exactly what was on disk before that was added.
        let older = Data(#"{"paper":"legal","isLandscape":true,"margin":"wide","bodyPointSize":9.5,"includesTitle":true}"#.utf8)
        let restored = PDFExportOptions(decoding: older)
        #expect(restored.paper == .legal, "the stored paper size was lost")
        #expect(restored.isLandscape)
        #expect(restored.margin == .wide)
        #expect(restored.bodyPointSize == 9.5)
        #expect(restored.includesTitle)
        // And the field it could not know about takes its default.
        #expect(restored.colours == PDFExportOptions().colours)

        // A file with only one field keeps that one and defaults the rest.
        let sparse = Data(#"{"margin":"narrow"}"#.utf8)
        #expect(PDFExportOptions(decoding: sparse).margin == .narrow)
        #expect(PDFExportOptions(decoding: sparse).paper == PDFExportOptions().paper)
    }

    /// The store writes what it reads, against the real defaults, and puts
    /// back whatever was there.
    @Test("The store actually writes to defaults")
    func writesToDefaults() {
        let key = "dev.stenglein.Heft.export.pdf.roundTripProbe"
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let chosen = PDFExportOptions(paper: .tabloid, margin: .narrow, bodyPointSize: 9)
        defaults.set(chosen.encoded, forKey: key)
        #expect(PDFExportOptions(decoding: defaults.data(forKey: key)) == chosen)
    }
}

@Suite("Frecency")
struct FrecencyTests {

    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Pure recency puts a note opened once by accident above one opened every
    /// morning; pure frequency never lets go of last year's project. The point
    /// of one decaying score is that neither happens.
    @Test("Often beats once, and recent beats stale")
    func combinesBoth() {
        var store = Frecency()
        // Opened every day for a week, last used a day ago.
        for offset in 1...7 { store.record("habit", at: now.addingTimeInterval(-Double(offset) * day)) }
        // Opened once, an hour ago.
        store.record("accident", at: now.addingTimeInterval(-3600))
        #expect(store.score("habit", at: now) > store.score("accident", at: now))

        var stale = Frecency()
        // Heavily used, but a month ago.
        for _ in 1...20 { stale.record("old", at: now.addingTimeInterval(-30 * day)) }
        stale.record("fresh", at: now)
        #expect(stale.score("fresh", at: now) > stale.score("old", at: now))
    }

    @Test("A use halves in value every half-life")
    func decaysByHalves() {
        var store = Frecency()
        store.record("note", at: now)
        let immediate = store.score("note", at: now)
        let oneLife = store.score("note", at: now.addingTimeInterval(Frecency.halfLife))
        let twoLives = store.score("note", at: now.addingTimeInterval(2 * Frecency.halfLife))
        #expect(abs(oneLife - immediate / 2) < 0.0001)
        #expect(abs(twoLives - immediate / 4) < 0.0001)
    }

    @Test("Anything never used scores nothing")
    func unknownIsZero() {
        var store = Frecency()
        store.record("seen", at: now)
        #expect(store.score("unseen", at: now) == 0)
        #expect(!store.hasRecord(of: "unseen"))
        #expect(store.hasRecord(of: "seen"))
    }

    /// An untouched vault has to open the switcher in a sensible order rather
    /// than in whatever order a dictionary happened to enumerate.
    @Test("Items with no history keep the fallback order")
    func stableWithoutHistory() {
        let store = Frecency()
        let names = ["Charlie", "alpha", "Bravo"]
        let ranked = store.ranked(names, at: now, by: { $0 }, tiebreak: {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        #expect(ranked == ["alpha", "Bravo", "Charlie"])
    }

    @Test("Ranking puts the most used first and keeps the rest ordered")
    func ranksByScore() {
        var store = Frecency()
        store.record("Bravo", at: now.addingTimeInterval(-day))
        store.record("Bravo", at: now)
        store.record("Charlie", at: now)
        let ranked = store.ranked(["alpha", "Bravo", "Charlie", "delta"], at: now, by: { $0 }, tiebreak: {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        #expect(ranked.prefix(2) == ["Bravo", "Charlie"])
        #expect(ranked.suffix(2) == ["alpha", "delta"], "unused entries stay alphabetical")
    }

    /// A clock that has gone backwards — a timezone change, a restored
    /// backup — must not inflate a score into permanence.
    @Test("A backwards clock cannot inflate a score")
    func backwardsClock() {
        var store = Frecency()
        store.record("note", at: now)
        let past = store.score("note", at: now.addingTimeInterval(-10 * day))
        #expect(past == store.score("note", at: now))
    }

    @Test("The store survives a round trip and bad data")
    func persistence() {
        var store = Frecency()
        store.record("note", at: now)
        let restored = Frecency(decoding: store.encoded)
        #expect(abs(restored.score("note", at: now) - store.score("note", at: now)) < 0.0001)
        #expect(Frecency(decoding: nil) == Frecency())
        #expect(Frecency(decoding: Data("not json".utf8)) == Frecency())
    }

    /// A vault used for years must not grow an unbounded store.
    @Test("The store stays bounded")
    func prunes() {
        var store = Frecency()
        for index in 0..<900 { store.record("note-\(index)", at: now) }
        var kept = 0
        for index in 0..<900 where store.hasRecord(of: "note-\(index)") { kept += 1 }
        #expect(kept <= 400, "kept \(kept) entries")
        // And what it keeps is what was used most recently.
        #expect(store.hasRecord(of: "note-899"))
    }
}

@Suite("Switcher ranking")
struct SwitcherRankingTests {

    private func index(_ names: [String]) -> VaultIndex {
        let root = URL(fileURLWithPath: "/tmp/heft-rank")
        let items = names.map { name in
            VaultItem(
                url: root.appendingPathComponent("\(name).md"),
                relativePath: "\(name).md",
                kind: .markdown,
                name: name
            )
        }
        return VaultIndex.build(root: VaultItem(
            url: root, relativePath: "", kind: .folder, name: "", children: items
        ))
    }

    /// An alphabetical list of every note in a vault is a directory listing,
    /// not a switcher: the note wanted is almost always one of the last few.
    @Test("With nothing typed, the most-used notes come first")
    func emptyQueryRanksByUse() {
        let index = index(["Alpha", "Beta", "Gamma", "Delta"])
        let plain = index.search("", limit: 10).map(\.name)
        #expect(plain == ["Alpha", "Beta", "Delta", "Gamma"], "unranked is alphabetical")

        var frecency = Frecency()
        frecency.record("Gamma.md")
        frecency.record("Gamma.md")
        frecency.record("Delta.md")
        let ranked = index.search("", limit: 10) { frecency.score($0.relativePath) }.map(\.name)
        #expect(ranked.prefix(2) == ["Gamma", "Delta"])
        // And everything unused keeps its alphabetical order rather than
        // reshuffling between openings, which an unstable sort would do.
        #expect(ranked.suffix(2) == ["Alpha", "Beta"])
    }

    /// Familiarity is a nudge inside a tier, never across one. A note you have
    /// never opened that matches better still wins, which is what keeps typing
    /// predictable.
    @Test("A better match beats a more familiar one")
    func matchQualityWins() {
        let index = index(["Meeting", "Weekly Meeting Notes"])
        var frecency = Frecency()
        for _ in 1...50 { frecency.record("Weekly Meeting Notes.md") }

        let ranked = index.search("meet", limit: 10) {
            min(1, frecency.score($0.relativePath) / 4)
        }.map(\.name)
        // "Meeting" is a prefix match, the other only contains it. No amount
        // of use may reorder that.
        #expect(ranked.first == "Meeting", "got \(ranked)")
    }

    /// Within one tier, though, familiarity should decide.
    ///
    /// Both names here are prefix matches, and unranked the *shorter* one wins
    /// on the index's own tiebreak. The longer one is the familiar one, so
    /// this measures the boost overcoming that rather than agreeing with an
    /// order the index would have produced anyway.
    @Test("Between equal matches, the familiar one wins")
    func familiarityBreaksTies() {
        let index = index(["Report Alpha", "Report Beta"])
        #expect(
            index.search("report", limit: 10).map(\.name).first == "Report Beta",
            "unranked, the shorter name wins"
        )

        var frecency = Frecency()
        for _ in 1...4 { frecency.record("Report Alpha.md") }
        let ranked = index.search("report", limit: 10) {
            min(1, frecency.score($0.relativePath) / 4)
        }.map(\.name)
        #expect(ranked.first == "Report Alpha", "got \(ranked)")
    }

    @Test("An unused vault still returns everything, in order")
    func unusedVault() {
        let index = index(["Charlie", "alpha", "Bravo"])
        let empty = Frecency()
        let ranked = index.search("", limit: 10) { empty.score($0.relativePath) }.map(\.name)
        #expect(ranked == ["alpha", "Bravo", "Charlie"])
    }
}

@Suite("Separate use indices")
@MainActor
struct FrecencyStoreSeparationTests {

    /// The reader's ranking and the agent's are different questions for
    /// different readers, and merging them has a specific failure: one
    /// `heft propose` loop over thirty notes would displace weeks of the
    /// reader's own signal in a switcher they never asked to have reordered.
    @Test("An agent's work never reaches the reader's ranking")
    func storesAreSeparate() {
        let vault = "/tmp/heft-separation-\(UUID().uuidString)"
        let reader = FrecencyStore.notes(forVaultAt: vault)
        let agent = FrecencyStore.agentNotes(forVaultAt: vault)
        defer {
            for key in [
                "dev.stenglein.Heft.frecency.notes.\(vault)",
                "dev.stenglein.Heft.frecency.agent.\(vault)",
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        agent.record("proposed.md")
        agent.record("proposed.md")
        #expect(agent.score("proposed.md") > 0)

        // Read through a *fresh* instance. A store loads its copy once at
        // init, so asking the one built before the write would pass even if
        // both were writing to the same key — which is exactly the mistake
        // this test exists to catch.
        #expect(
            FrecencyStore.notes(forVaultAt: vault).score("proposed.md") == 0,
            "an agent's proposal reached the reader's index"
        )

        reader.record("opened.md")
        #expect(reader.score("opened.md") > 0)
        #expect(
            FrecencyStore.agentNotes(forVaultAt: vault).score("opened.md") == 0,
            "a reader's open reached the agent's index"
        )
    }

    /// Two vaults are two rankings: "the note I keep opening" is a fact about
    /// a vault, not about the app.
    @Test("Two vaults keep separate rankings")
    func vaultsAreSeparate() {
        let one = "/tmp/heft-vault-one-\(UUID().uuidString)"
        let two = "/tmp/heft-vault-two-\(UUID().uuidString)"
        defer {
            for path in [one, two] {
                UserDefaults.standard.removeObject(
                    forKey: "dev.stenglein.Heft.frecency.notes.\(path)"
                )
            }
        }
        FrecencyStore.notes(forVaultAt: one).record("note.md")
        #expect(FrecencyStore.notes(forVaultAt: one).score("note.md") > 0)
        #expect(FrecencyStore.notes(forVaultAt: two).score("note.md") == 0)
    }

    /// A store reads what a previous instance wrote, which is the whole point
    /// of it outliving a session.
    @Test("A use survives a new instance")
    func persistsAcrossInstances() {
        let vault = "/tmp/heft-persist-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "dev.stenglein.Heft.frecency.notes.\(vault)")
        }
        FrecencyStore.notes(forVaultAt: vault).record("note.md")
        #expect(FrecencyStore.notes(forVaultAt: vault).score("note.md") > 0)
    }
}

@Suite("Sandboxed preferences")
struct HeftDefaultsTests {

    /// The isolation cannot be half-applied. One setting still reaching
    /// `UserDefaults.standard` is enough to lose the property, and the one
    /// that matters most is `vaultPath`: a test launch that rewrites it aims
    /// Spotlight capture at a folder about to be deleted.
    @Test("Nothing reaches UserDefaults.standard directly")
    func everySettingGoesThroughTheAccessor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var offenders: [String] = []
        for directory in ["Sources/Heft", "Sources/HeftCore", "Sources/Heft/Views"] {
            let url = root.appendingPathComponent(directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names where name.hasSuffix(".swift") {
                // The accessor itself is the one place allowed to say it.
                guard name != "HeftDefaults.swift" else { continue }
                let text = (try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)) ?? ""
                if text.contains("UserDefaults.standard") {
                    offenders.append("\(directory)/\(name)")
                }
            }
        }
        #expect(offenders.isEmpty, "still using UserDefaults.standard: \(offenders.joined(separator: ", "))")
    }

    @Test("An empty or absent suite falls back to the real store")
    func fallsBackWithoutASuite() {
        // The environment is not set in the test process, so this is the
        // default path: sandboxing must be opt-in, never accidental.
        #expect(!HeftDefaults.isSandboxed)
        #expect(HeftDefaults.shared == UserDefaults.standard)
    }
}

@Suite("Offscreen view rendering")
@MainActor
struct OffscreenRenderTests {

    @Test("A settings view renders to an image offscreen")
    func rendersAccessory() throws {
        let renderer = ImageRenderer(content: PDFExportAccessory().frame(width: 460, height: 190))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced nothing")
        #expect(image.size.width > 100 && image.size.height > 50, "got \(image.size)")

        // Not a blank canvas: something was actually drawn.
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.alphaComponent > 0.1 && pixel.brightnessComponent < 0.75 { inked += 1 }
            }
        }
        #expect(inked > 50, "the render looks blank (\(inked) dark samples)")

        // Written out so it can be looked at when something is wrong.
        _ = inked
        if let directory = ProcessInfo.processInfo.environment["HEFT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("PDFExportAccessory.png")
            if let png = NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }
}

@Suite("Exported text layer")
@MainActor
struct ExportedTextLayerTests {

    private static let note = """
    # Quarterly Notes

    A paragraph with **bold**, *italic* and $E = mc^2$ maths.

    | Engine | Throughput |
    | --- | --- |
    | SGLang | 112 t/s |

    - a bullet
    - [x] a finished task

    > [!warning] Mind this
    > A callout body.

    $$
    \\int_0^1 x^2 \\, dx = \\frac{1}{3}
    $$
    """

    private func exportedText() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-layer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        #expect(PDFExport.write(
            text: Self.note,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            to: url
        ))
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// The page looked right all along; the invisible text behind it did not.
    /// Collapsing hides markup with a hairline clear font, which is still text
    /// as far as PDF is concerned, so an export carried its own source —
    /// copying a paragraph gave back `**bold**`.
    @Test("The markup is not in the exported text")
    func markupIsGone() throws {
        let text = try exportedText()
        #expect(!text.contains("# Quarterly"), "a heading's hashes reached the text layer")
        #expect(!text.contains("**bold**"), "emphasis markers reached the text layer")
        #expect(!text.contains("*italic*"))
        #expect(!text.contains("[!warning]"))
        #expect(!text.contains("- a bullet"), "a list marker reached the text layer")
    }

    /// A widget draws *over* source that is still present, so a table and a
    /// formula each appeared twice — once drawn, once as `| --- | ---: |` and
    /// its LaTeX. A screen reader read all of it, twice.
    @Test("Drawn constructs are not also present as source")
    func noDuplication() throws {
        let text = try exportedText()
        #expect(!text.contains("| --- |"), "the table's delimiter row reached the text layer")
        #expect(!text.contains("\\int_0^1"), "the formula's LaTeX reached the text layer")
        #expect(!text.contains("$$"))
    }

    /// And the prose is still there, still selectable. Stripping the markup
    /// must not strip the note.
    @Test("The prose survives")
    func proseSurvives() throws {
        let text = try exportedText()
            .replacingOccurrences(of: "\u{200B}", with: "")
        for expected in [
            "Quarterly Notes", "bold", "italic", "a bullet",
            "a finished task", "Mind this", "A callout body",
            "SGLang", "112 t/s",
        ] {
            #expect(text.contains(expected), "`\(expected)` was lost from the text layer")
        }
    }

    /// An inline formula occupies no width of its own: the gap it is drawn
    /// into is bought with a `.kern` on the last character of its collapsed
    /// `$…$`. Kerning is not applied to a zero-width space, so replacing that
    /// character closed the gap and the typeset maths landed on top of the
    /// words after it — visible on the page, and invisible to any test that
    /// only reads the text.
    @Test("The character carrying a formula's gap is kept")
    func keepsTheKernedCharacter() throws {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let view = PDFExport.renderView(
            text: "A line with $E = mc^2$ maths in it.\n", context: context, width: 483
        )
        let storage = try #require(view.textStorage)

        _ = storage

        // Measured from the layout, not from the attribute. The kern survives
        // on a zero-width space and is simply not applied to it, so a test
        // that reads the attribute passes while the page is wrong.
        func lineWidth(_ text: String) throws -> CGFloat {
            let view = PDFExport.renderView(text: text, context: context, width: 483)
            let manager = try #require(view.textLayoutManager)
            var width: CGFloat = 0
            manager.enumerateTextLayoutFragments(
                from: manager.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                for line in fragment.textLineFragments {
                    width = max(width, line.typographicBounds.width)
                }
                return false
            }
            return width
        }

        let withMaths = try lineWidth("A line with $E = mc^2$ maths in it.\n")
        let without = try lineWidth("A line with  maths in it.\n")
        #expect(
            withMaths - without > 15,
            "the formula has no room on the line: \(withMaths) vs \(without) without it"
        )
    }

    /// The visible page must be untouched by any of this: flattening happens
    /// after styling and replaces each character with one of the same count,
    /// so nothing may reflow.
    @Test("Flattening does not change the page")
    func layoutIsUnchanged() throws {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let view = PDFExport.renderView(text: Self.note, context: context, width: 483)
        let storage = try #require(view.textStorage)

        // Same length as the source, character for character.
        #expect(storage.length == (Self.note as NSString).length)

        // And the styling survived. A restyle triggered by the edits would
        // re-decorate a buffer with no markdown left and give back plain body
        // text — which is exactly what happened before both delegates were
        // detached.
        let heading = (storage.string as NSString).range(of: "Quarterly Notes")
        #expect(heading.location != NSNotFound)
        let font = storage.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 0) > 20, "the heading lost its styling (got \(font?.pointSize ?? -1))")
    }
}

@Suite("Callout icons")
@MainActor
struct CalloutIconTests {

    /// `SymbolConfiguration(paletteColors:)` is the obvious way to tint an SF
    /// Symbol and it silently **flattens** it: every `.fill` symbol becomes a
    /// solid silhouette, so `pencil.circle.fill` is a plain disc and
    /// `info.circle.fill` is the same plain disc. At 14pt it reads as "a
    /// coloured blob" and went unnoticed until a PDF made it big enough to
    /// look at.
    ///
    /// The test is that the glyph has a *hole* in it: a flattened symbol is
    /// opaque throughout, a real one leaves its detail as negative space so
    /// the callout's card shows through.
    @Test("A callout icon keeps its detail, not just its outline")
    func iconIsNotFlattened() throws {
        let side: CGFloat = 48
        let tint = NSColor.systemBlue
        let image = try #require(
            HeftLayoutFragment.tintedSymbol("pencil.circle.fill", side: side, tint: tint)
        )
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))

        // The middle of the glyph, where a disc would be solid and a pencil
        // is not.
        let inset = rep.pixelsWide / 4
        var opaque = 0
        var clear = 0
        for x in inset..<(rep.pixelsWide - inset) {
            for y in inset..<(rep.pixelsHigh - inset) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if pixel.alphaComponent > 0.9 { opaque += 1 }
                if pixel.alphaComponent < 0.1 { clear += 1 }
            }
        }
        #expect(opaque > 20, "the icon barely drew at all (\(opaque) opaque)")
        #expect(clear > 20, "the icon is a solid silhouette — its detail was flattened away")
    }

    /// And it is actually the colour that was asked for, not black. A template
    /// image keeps its detail but ignores the fill colour, which is why the
    /// mask is recoloured with `.sourceIn` rather than simply drawn.
    ///
    /// Compared between two tints rather than against a fixed value: a
    /// catalog colour resolves against whatever appearance is current, and the
    /// bitmap comes back in whichever colour space `lockFocus` chose, so an
    /// exact match is not a stable thing to assert. That one tint is warmer
    /// than the other is.
    @Test("A callout icon is drawn in its own tint")
    func iconIsTinted() throws {
        func averageInk(_ tint: NSColor) throws -> (red: Double, blue: Double) {
            let image = try #require(
                HeftLayoutFragment.tintedSymbol("flame.fill", side: 48, tint: tint)
            )
            let data = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: data))
            var red = 0.0, blue = 0.0, count = 0.0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          pixel.alphaComponent > 0.9 else { continue }
                    red += pixel.redComponent
                    blue += pixel.blueComponent
                    count += 1
                }
            }
            #expect(count > 50, "the icon barely drew (\(count) opaque pixels)")
            return (red / max(count, 1), blue / max(count, 1))
        }

        let orange = try averageInk(.systemOrange)
        let blue = try averageInk(.systemBlue)
        #expect(orange.red > blue.red, "an orange icon is not warmer than a blue one")
        #expect(blue.blue > orange.blue, "a blue icon is not cooler than an orange one")
        // And neither is the black a template image draws when the fill colour
        // is ignored.
        #expect(orange.red > 0.3, "the icon came out near-black (red \(orange.red))")
        #expect(blue.blue > 0.3, "the icon came out near-black (blue \(blue.blue))")
    }

    /// Two kinds must not share a cache entry just because they are the same
    /// size: they differ only by colour.
    @Test("The cache keys on the tint as well as the symbol")
    func cacheDistinguishesTints() throws {
        let warm = try #require(HeftLayoutFragment.tintedSymbol("flame.fill", side: 24, tint: .systemOrange))
        let cool = try #require(HeftLayoutFragment.tintedSymbol("flame.fill", side: 24, tint: .systemBlue))
        let warmData = try #require(warm.tiffRepresentation)
        let coolData = try #require(cool.tiffRepresentation)
        #expect(warmData != coolData, "the same glyph came back for two different tints")
    }
}

@Suite("Print colours")
struct PrintColoursTests {

    /// A yellow accent that reads well on a dark editor has almost no
    /// contrast against white paper. That is measurable, not a matter of
    /// taste, which is why the fix is automatic rather than a second palette
    /// to configure.
    @Test("A pale colour is darkened until it is legible on white")
    func palesAreDarkened() {
        // Roughly the yellow accent this came from.
        let yellow = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        #expect(
            PrintColours.contrastWithWhite(yellow) < PrintColours.minimumContrast,
            "the sample is not actually a low-contrast colour"
        )

        let onPaper = PrintColours.adjusted(yellow, for: .paper)
        #expect(
            PrintColours.contrastWithWhite(onPaper) >= PrintColours.minimumContrast,
            "still too pale: contrast \(PrintColours.contrastWithWhite(onPaper))"
        )

        // The hue is kept, so it is still recognisably the colour that was
        // chosen rather than a different one.
        let before = yellow.usingColorSpace(.sRGB)!.hueComponent
        let after = onPaper.usingColorSpace(.sRGB)!.hueComponent
        #expect(abs(before - after) < 0.02, "the hue moved from \(before) to \(after)")
    }

    /// A colour that is already dark enough must be left exactly as it is —
    /// darkening everything would flatten a carefully chosen palette.
    @Test("A colour with enough contrast is untouched")
    func darkColoursAreLeftAlone() {
        for colour in [
            NSColor(srgbRed: 0.1, green: 0.1, blue: 0.6, alpha: 1),
            NSColor(srgbRed: 0.6, green: 0, blue: 0, alpha: 1),
            NSColor.black,
        ] {
            let onPaper = PrintColours.adjusted(colour, for: .paper)
            #expect(
                PrintColours.luminance(onPaper) == PrintColours.luminance(colour),
                "an already-dark colour was changed"
            )
        }
    }

    @Test("Matching the editor changes nothing")
    func editorModeIsIdentity() {
        let yellow = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        let same = PrintColours.adjusted(yellow, for: .editor)
        #expect(PrintColours.luminance(same) == PrintColours.luminance(yellow))
    }

    @Test("Black and white has no colour left in it")
    func monochromeIsGrey() {
        for colour in [
            NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 0.4, blue: 1, alpha: 1),
            NSColor.systemRed,
        ] {
            let grey = PrintColours.adjusted(colour, for: .monochrome)
                .usingColorSpace(.sRGB)!
            #expect(abs(grey.redComponent - grey.greenComponent) < 0.001)
            #expect(abs(grey.greenComponent - grey.blueComponent) < 0.001)
            #expect(
                PrintColours.contrastWithWhite(grey) >= PrintColours.minimumContrast,
                "a grey that pale is no more legible than the colour was"
            )
        }
    }

    /// Every colour the export hands to the renderer goes through this, so a
    /// mode that only fixed the accent would leave links and headings pale.
    @Test("The default mode is the adjusted one")
    func defaultIsPaper() {
        #expect(PDFExportOptions().colours == .paper)
        #expect(PDFExportOptions(decoding: PDFExportOptions().encoded).colours == .paper)
    }
}

@Suite("Unsaved work survives")
@MainActor
struct DraftRecoveryTests {

    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first version\n".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func model(_ root: URL) -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
    }

    /// An unresolved conflict pauses autosave on purpose, so nothing writes
    /// the buffer anywhere. Everything typed after the conflict appeared used
    /// to exist only in memory, and a recovery copy was made when the window
    /// *closed* — which covers quitting and not losing power.
    @Test("A conflict leaves the buffer on disk as a draft")
    func conflictWritesADraft() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        #expect(model.current?.relativePath == "Note.md")

        model.text = "what I typed\n"
        // Somebody else changed the note, so saving must not overwrite it.
        try "changed elsewhere\n".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )
        model.save()

        #expect(model.saveConflict != nil, "no conflict was raised")
        #expect(
            DraftStore.draft(vault: root, relativePath: "Note.md") == "what I typed\n",
            "the buffer was left only in memory"
        )
        // And the note itself is untouched, which was always true.
        let onDisk = try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
        #expect(onDisk == "changed elsewhere\n")
    }

    /// Once the buffer reaches its note there is nothing left to recover, and
    /// a stale draft would be promoted into the vault for no reason.
    @Test("A successful save forgets the draft")
    func savingForgetsTheDraft() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        // The model is created *first*, and the draft written after: opening a
        // note recovers any draft it finds, so seeding one beforehand is
        // consumed by that path and never reaches the save. This is the draft
        // a conflict would have left behind while the note was already open.
        let model = model(root)
        model.text = "edited\n"
        DraftStore.write("edited\n", vault: root, relativePath: "Note.md")
        #expect(DraftStore.draft(vault: root, relativePath: "Note.md") != nil)

        model.save()
        #expect(
            DraftStore.draft(vault: root, relativePath: "Note.md") == nil,
            "a stale draft outlived the save and would be promoted on the next open"
        )
        let onDisk = try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
        #expect(onDisk == "edited\n", "the save did not happen")
    }

    /// The half that makes drafts worth writing: a draft left by a process
    /// that did not survive becomes an ordinary note in the vault, where it
    /// will be seen, rather than a file in a Library folder nobody visits.
    @Test("A draft that outlived its process is recovered on open")
    func draftIsRecoveredOnOpen() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        DraftStore.write("work that was never saved\n", vault: root, relativePath: "Note.md")

        _ = model(root)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let recovered = names.filter { $0.contains("Heft Recovery") }
        #expect(recovered.count == 1, "expected one recovery note, found \(names)")

        let text = try String(
            contentsOf: root.appendingPathComponent(recovered[0]), encoding: .utf8
        )
        #expect(text == "work that was never saved\n")
        // Taken, not left to be offered again on the next open.
        #expect(DraftStore.draft(vault: root, relativePath: "Note.md") == nil)
        // And the note itself was not touched.
        let onDisk = try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
        #expect(onDisk == "first version\n")
    }

    /// The common case after a clean quit: a draft that says exactly what the
    /// note says is not work at risk, and promoting it would litter the vault.
    @Test("A draft matching the note is discarded, not promoted")
    func matchingDraftIsNotPromoted() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        DraftStore.write("first version\n", vault: root, relativePath: "Note.md")

        _ = model(root)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.contains("Heft Recovery") }, "found \(names)")
        #expect(DraftStore.draft(vault: root, relativePath: "Note.md") == nil)
    }

    /// Two notes must not share a draft. The filename is a hash of the vault
    /// and note path, so a collision would silently swap one note's unsaved
    /// work for another's.
    @Test("Each note has its own draft")
    func draftsAreNotShared() throws {
        let root = try vault()
        defer {
            for path in ["Note.md", "Other.md", "Folder/Note.md"] {
                DraftStore.discard(vault: root, relativePath: path)
            }
            try? FileManager.default.removeItem(at: root)
        }
        DraftStore.write("one\n", vault: root, relativePath: "Note.md")
        DraftStore.write("two\n", vault: root, relativePath: "Other.md")
        DraftStore.write("three\n", vault: root, relativePath: "Folder/Note.md")

        #expect(DraftStore.draft(vault: root, relativePath: "Note.md") == "one\n")
        #expect(DraftStore.draft(vault: root, relativePath: "Other.md") == "two\n")
        #expect(DraftStore.draft(vault: root, relativePath: "Folder/Note.md") == "three\n")
    }
}

