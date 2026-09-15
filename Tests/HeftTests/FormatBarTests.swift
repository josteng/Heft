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

    @Test("A selection that starts above the screen keeps the bar where it can be seen")
    func barStaysOnScreen() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.automaticallyAdjustsContentInsets = false
        // Stands in for the toolbar the editor scrolls beneath.
        scroll.contentInsets = NSEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 3000))
        text.isVerticallyResizable = false
        scroll.documentView = text
        window.contentView = scroll
        // Becoming the document view shrinks it to the clip, which leaves
        // nothing to scroll.
        text.setFrameSize(NSSize(width: 600, height: 3000))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        scroll.reflectScrolledClipView(scroll.contentView)
        let visible = text.visibleRect
        try #require(visible.height.isFinite && visible.minY > 900, "\(visible) \(scroll.contentView.bounds)")

        let bar = FormatBar()
        text.addSubview(bar)
        // Starts 300 pt above the screen and runs past its bottom.
        let tall = CGRect(x: 100, y: visible.minY - 300, width: 300, height: visible.height + 600)
        bar.update(for: tall, in: text, allowsSingleLineOnlyFormats: false)
        #expect(!bar.isHidden)
        #expect(bar.frame.minY >= visible.minY + 50)
        #expect(bar.frame.maxY <= visible.maxY)

        // A selection wholly off screen has nothing to show the bar over.
        let offScreen = CGRect(x: 100, y: visible.maxY + 500, width: 300, height: 20)
        bar.update(for: offScreen, in: text, allowsSingleLineOnlyFormats: true)
        #expect(bar.isHidden)
    }

    @Test("Nothing is drawn around the glass")
    func noOldChrome() {
        let bar = FormatBar()
        #expect(bar.shadow == nil)
        #expect(!bar.subviews.contains { $0 is NSVisualEffectView })
    }
}
