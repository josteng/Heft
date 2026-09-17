import AppKit
import Testing
@testable import Heft

@MainActor
@Suite("Completion menu")
struct WikiCompletionPanelTests {

    @Test("The menu is regular glass whose corners run parallel to its rows")
    func glassWithConcentricRows() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        let panel = WikiCompletionPanel()
        textView.addSubview(panel)
        let item = WikiCompletionItem(title: "Example", detail: "", symbol: "doc", destination: "Example")
        panel.show(items: [item, item], selected: 0, below: NSRect(x: 20, y: 20, width: 1, height: 16), in: textView)
        panel.layoutSubtreeIfNeeded()

        #expect(!panel.subviews.contains { $0 is NSVisualEffectView })
        let glass = try #require(panel.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)

        let row = try #require(panel.subviews.compactMap { $0 as? WikiCompletionRow }.first)
        let rowRadius = try #require(row.layer?.cornerRadius)
        #expect(glass.cornerRadius == rowRadius + row.frame.minX)
    }
}
