import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// A note changed on disk while it is open, as a capture from Spotlight
/// changes the daily note, keeps the reader where they were scrolled to.
@MainActor
@Suite("External change keeps the scroll position")
struct ExternalChangeScrollTests {
    /// Published, as `AppModel.text` is: setting it alone re-renders.
    private final class Document: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var document: Document
        var generation = 0
        var keepsPosition = false

        var body: some View {
            LiveTextEditor(
                text: $document.text, documentIdentity: "daily.md", generation: generation,
                generationKeepsPosition: keepsPosition, findSelection: nil, insertion: nil,
                context: ExternalChangeScrollTests.context(),
                onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
            )
        }
    }

    /// As the window builds it on every update: its colors are dynamic and
    /// made afresh, so each is a new object that draws the same.
    static func context() -> RenderContext {
        var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        func fresh() -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemTeal : .systemBlue
            }
        }
        context.accentColor = fresh()
        context.linkColor = fresh()
        context.tagColor = fresh()
        return context
    }

    private static func editorView(in view: NSView) -> HeftTextKit2View? {
        if let found = view as? HeftTextKit2View { return found }
        for child in view.subviews {
            if let found = editorView(in: child) { return found }
        }
        return nil
    }

    private static func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// A daily note long enough to scroll: headings, tasks and timed lines
    /// of different lengths, as such a note grows over a day.
    private static func dailyNote() -> String {
        var lines = ["# Friday", ""]
        for hour in 0..<40 {
            lines.append("## Block \(hour)")
            for minute in 0..<6 {
                let words = String(repeating: "garden window kettle ", count: 1 + (hour * 7 + minute) % 9)
                lines.append(minute % 3 == 0 ? "- [ ] \(words)" : "- \(hour):\(minute)0 \(words)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @Test("A line appended on disk leaves the view where it was")
    func appendedLineKeepsTheScroll() async throws {
        let note = Self.dailyNote()
        let document = Document(note)
        let host = NSHostingView(rootView: Host(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await Self.settle()
        let view = try #require(Self.editorView(in: host))
        let clip = try #require(view.enclosingScrollView?.contentView)

        // The caret where the note opened, the view scrolled away from it with
        // the trackpad, which moves the clip view and leaves the caret.
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(NSRange(location: (note as NSString).length / 2, length: 0))
        await Self.settle()
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 200))
        view.enclosingScrollView?.reflectScrolledClipView(clip)
        await Self.settle()
        let before = clip.bounds.origin.y
        #expect(before > 1000, "the note did not scroll: \(before)")

        // The capture's line arrives at the end, as the file watcher hands it over.
        document.text = note + "\n- 10:15 captured from Spotlight\n"
        host.rootView = Host(document: document, generation: 1, keepsPosition: true)
        await Self.settle()

        let after = clip.bounds.origin.y
        #expect(abs(after - before) < 4, "scrolled from \(before) to \(after)")
    }

    /// The model's text and its generation are two changes, and SwiftUI can
    /// render the text before the generation moves: the editor then meets
    /// the new text with no generation to say what it is.
    @Test("The new text arriving before its generation keeps the view too")
    func textBeforeGenerationKeepsTheScroll() async throws {
        let note = Self.dailyNote()
        let document = Document(note)
        let host = NSHostingView(rootView: Host(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await Self.settle()
        let view = try #require(Self.editorView(in: host))
        let clip = try #require(view.enclosingScrollView?.contentView)

        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(NSRange(location: (note as NSString).length / 2, length: 0))
        await Self.settle()
        let before = clip.bounds.origin.y
        #expect(before > 1000, "the note did not scroll: \(before)")

        // The text lands, and renders, before the generation that says what it is.
        document.text = note + "\n- 10:15 captured from Spotlight\n"
        await Self.settle()
        host.rootView = Host(document: document, generation: 1, keepsPosition: true)
        await Self.settle()

        let after = clip.bounds.origin.y
        #expect(abs(after - before) < 4, "scrolled from \(before) to \(after)")
    }
}
