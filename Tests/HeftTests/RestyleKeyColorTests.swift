import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A keystroke after the settings were handed over again, unchanged,
/// restyles only the edited line. iOS makes its dynamic colours afresh on
/// every SwiftUI update, and a key built from their descriptions changed
/// each time: the whole note was relaid, and the page jumped while typing.
@MainActor
struct RestyleKeyColorTests {
    /// A colour equal to the last one as drawn, but a new object, as the
    /// iOS appearance hands out on every read.
    private func freshAccent() -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1)
                : NSColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)
        }
    }

    private func context() -> RenderContext {
        var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        context.accentColor = freshAccent()
        context.linkColor = freshAccent()
        return context
    }

    @Test func aKeystrokeAfterTheSameColorsAgainRestylesOnlyItsLine() {
        let restyler = LiveRestyler()
        var source = (1...40).map { "- item \($0) with a few words" }.joined(separator: "\n") + "\n"
        let storage = NSTextStorage(string: source)
        _ = restyler.restyle(storage, source: source as NSString, reveal: .none,
                             context: context(), width: 400, minimumContentWidth: 200)

        let caret = (source as NSString).length - 1
        storage.replaceCharacters(in: NSRange(location: caret, length: 0), with: "x")
        restyler.noteEdit(endingAt: caret, delta: 1)
        source = storage.string
        let outcome = restyler.restyle(storage, source: source as NSString, reveal: .none,
                                       context: context(), width: 400, minimumContentWidth: 200)

        guard case let .restyled(_, relayout) = outcome, case let .ranges(ranges) = relayout else {
            Issue.record("expected only the edited line relaid, got \(outcome)")
            return
        }
        #expect(ranges.allSatisfy { $0.length < 60 }, "\(ranges)")
    }

    @Test func aColorThatReallyChangedStillRestylesTheNote() {
        let restyler = LiveRestyler()
        let source = "- one\n- two\n" as NSString
        let storage = NSTextStorage(string: source as String)
        _ = restyler.restyle(storage, source: source, reveal: .none,
                             context: context(), width: 400, minimumContentWidth: 200)
        var changed = context()
        changed.accentColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let outcome = restyler.restyle(storage, source: source, reveal: .none,
                                       context: changed, width: 400, minimumContentWidth: 200)
        guard case .restyled = outcome else {
            Issue.record("a new accent kept the old styling: \(outcome)")
            return
        }
    }
}
