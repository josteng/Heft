import Foundation
import Testing
@testable import HeftCore

/// The iPad's Back and Forward: where a window has been.
@Suite("Navigation history")
struct NavigationHistoryTests {

    @Test("Back and forward walk the places visited")
    func walks() {
        var history = NavigationHistory<String>()
        #expect(!history.canGoBack && !history.canGoForward)
        history.visit("a")
        #expect(!history.canGoBack, "one place has nothing before it")
        history.visit("b")
        history.visit("c")
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.back() == "b")
        #expect(history.back() == "a")
        #expect(history.back() == nil)
        #expect(history.current == "a")
        #expect(history.forward() == "b")
        #expect(history.current == "b")
        #expect(history.canGoForward)
    }

    /// The window reports the place it shows after going back; recording it
    /// again would put a second copy ahead and lose Forward.
    @Test("Visiting the current place records nothing")
    func revisitIsNoOp() {
        var history = NavigationHistory<String>()
        history.visit("a")
        history.visit("b")
        _ = history.back()
        history.visit("a")
        #expect(history.places == ["a", "b"])
        #expect(history.forward() == "b")
    }

    @Test("A new place after going back drops what was ahead")
    func branching() {
        var history = NavigationHistory<String>()
        ["a", "b", "c"].forEach { history.visit($0) }
        _ = history.back()
        _ = history.back()
        history.visit("d")
        #expect(history.places == ["a", "d"])
        #expect(!history.canGoForward)
    }

    @Test("Places that can no longer be shown are passed over")
    func skipsUnusable() {
        var history = NavigationHistory<String>()
        ["a", "gone", "c"].forEach { history.visit($0) }
        #expect(history.back { $0 == "gone" } == "a")
        #expect(history.forward { $0 == "gone" } == "c")
        var stuck = NavigationHistory<String>()
        ["gone", "c"].forEach { stuck.visit($0) }
        #expect(stuck.back { $0 == "gone" } == nil)
        #expect(stuck.current == "c", "nothing moved")
    }

    @Test("Only the latest places are kept")
    func limited() {
        var history = NavigationHistory<Int>(limit: 3)
        (1...5).forEach { history.visit($0) }
        #expect(history.places == [3, 4, 5])
        #expect(history.current == 5)
        #expect(history.back() == 4)
    }
}
