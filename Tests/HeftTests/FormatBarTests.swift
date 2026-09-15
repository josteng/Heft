import AppKit
import HeftCore
import Testing
@testable import Heft

@MainActor
@Suite("Formatting bar")
struct FormatBarTests {

    @Test("The bar is one pill of regular glass holding its buttons")
    func glassPill() throws {
        let bar = FormatBar()
        let glass = try #require(bar.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
        #expect(glass.cornerRadius == FormatBar.height / 2)
        let stack = try #require(glass.contentView as? NSStackView)
        #expect(stack.arrangedSubviews.filter { $0 is NSButton }.count == InlineFormat.allCases.count + 1)
    }

    @Test("Nothing is drawn around the glass")
    func noOldChrome() {
        let bar = FormatBar()
        #expect(bar.shadow == nil)
        #expect(!bar.subviews.contains { $0 is NSVisualEffectView })
    }
}
