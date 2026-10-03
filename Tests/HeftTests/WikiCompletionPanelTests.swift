import AppKit
import Testing
@testable import Heft

@MainActor
@Suite("Completion menu")
struct WikiCompletionPanelTests {
    private static let anchor = NSRect(x: 20, y: 20, width: 1, height: 16)

    private static func items(_ count: Int) -> [WikiCompletionItem] {
        (0..<count).map {
            WikiCompletionItem(title: "Note \($0)", detail: "", symbol: "doc", destination: "Note \($0)")
        }
    }

    private static func editor() -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        return (window, textView)
    }

    @Test("A narrowing list keeps its frame, and only the menu takes clicks")
    func shrinkKeepsFrameAndClicksFallThrough() {
        let (window, textView) = Self.editor()
        defer { window.close() }
        let panel = WikiCompletionPanel()
        textView.addSubview(panel)

        panel.show(items: Self.items(5), selected: 0, below: Self.anchor, in: textView)
        panel.show(items: Self.items(2), selected: 0, below: Self.anchor, in: textView)
        panel.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        #expect(panel.frame.height == WikiCompletionMetrics.height(rows: 5))
        #expect(panel.listRect.height == WikiCompletionMetrics.height(rows: 2))

        let onMenu = NSPoint(x: panel.frame.midX, y: panel.frame.minY + 10)
        let pastMenu = NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 10)
        #expect(panel.hitTest(onMenu) != nil)
        #expect(panel.hitTest(pastMenu) == nil)

        panel.dismiss()
        #expect(panel.hitTest(onMenu) == nil)
        panel.show(items: Self.items(2), selected: 0, below: Self.anchor, in: textView)
        #expect(panel.frame.height == WikiCompletionMetrics.height(rows: 2))
    }

    @Test("Short of room, the menu stays clear of the toolbar and scrolls")
    func staysUnderTheToolbar() throws {
        let toolbar: CGFloat = 80
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: toolbar, left: 0, bottom: 0, right: 0)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        // Scrolled into the note, so text runs on under the toolbar.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 420))
        let clip = scrollView.contentView.bounds
        let toolbarEdge = clip.minY + toolbar
        let anchor = NSRect(x: 20, y: clip.maxY - 30, width: 1, height: 16)

        let panel = WikiCompletionPanel()
        textView.addSubview(panel)
        panel.show(items: Self.items(13), selected: 0, below: anchor, in: textView)

        let menuTop = panel.frame.minY + panel.listRect.minY
        #expect(menuTop >= toolbarEdge)
        #expect(panel.frame.minY + panel.listRect.maxY <= anchor.minY)
        #expect(panel.listRect.height < WikiCompletionMetrics.height(rows: 13))
    }

    @Test("Any height counts as some number of rows")
    func rowsFitAnyHeight() {
        #expect(WikiCompletionMetrics.rows(fitting: .greatestFiniteMagnitude) > 1000)
        #expect(WikiCompletionMetrics.rows(fitting: .infinity) > 1000)
        #expect(WikiCompletionMetrics.rows(fitting: -50) == 0)
        #expect(WikiCompletionMetrics.rows(fitting: WikiCompletionMetrics.height(rows: 3)) == 3)
    }

    @Test("Rows writing the same thing keep separate identities")
    func duplicateDestinations() {
        let item = WikiCompletionItem(title: "Example", detail: "", symbol: "doc", destination: "Example")
        let ids = WikiCompletionList.rows(for: [item, item]).map(\.id)
        #expect(Set(ids).count == 2)
    }
}
