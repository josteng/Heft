import Foundation
import HeftCore
import Testing
@testable import Heft

/// What the right sidebar's Outline is told: the headings, and the one the
/// caret is under, published only when they change.
@MainActor
@Suite("Outline tracker")
struct OutlineTrackerTests {
    private static let note = "intro\n# One\ntext\n## Two\nmore"

    /// Typing updates the tracker several times a second; with no Outline
    /// showing it must not scan the note at all.
    @Test("Scans only while an Outline is showing")
    func scansWhenWatched() {
        let tracker = OutlineTracker()
        tracker.update(from: Self.note)
        #expect(tracker.outline.entries.isEmpty)
        tracker.watch()
        #expect(tracker.outline.entries.map(\.title) == ["One", "Two"])
        tracker.unwatch()
        tracker.update(from: "# Other")
        #expect(tracker.outline.entries.map(\.title) == ["One", "Two"], "not rescanned while hidden")
        tracker.watch()
        #expect(tracker.outline.entries.map(\.title) == ["Other"], "caught up on showing")
    }

    @Test("Follows the caret, and the text under it")
    func followsCaret() {
        let tracker = OutlineTracker()
        tracker.watch()
        tracker.update(from: Self.note)
        let text = Self.note as NSString
        #expect(tracker.current == nil, "above the first heading")
        tracker.caretMoved(to: text.range(of: "text").location)
        #expect(tracker.current == 0)
        tracker.caretMoved(to: text.range(of: "more").location)
        #expect(tracker.current == 1)
        // A heading typed above shifts every index after it: the caret's
        // offset now falls in Two, the third heading.
        tracker.update(from: "# New\n" + Self.note)
        #expect(tracker.current == 2)
    }

    @Test("Publishes only on a change")
    func publishesOnChange() {
        let tracker = OutlineTracker()
        tracker.watch()
        tracker.update(from: Self.note)
        var sent = 0
        let subscription = tracker.objectWillChange.sink { sent += 1 }
        tracker.update(from: Self.note + " typed")
        tracker.caretMoved(to: 1)
        tracker.caretMoved(to: 2)
        #expect(sent == 0)
        tracker.caretMoved(to: (Self.note as NSString).length)
        #expect(sent == 1)
        subscription.cancel()
    }
}
