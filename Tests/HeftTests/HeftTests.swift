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
