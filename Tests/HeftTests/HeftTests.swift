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
