import Foundation
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
