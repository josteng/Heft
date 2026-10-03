import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Commands that edit the note, applied the way the window applies them:
/// through a SwiftUI update of the editor.
@MainActor
@Suite("Editing commands")
struct EditingCommandTests {
    /// A plain property, as `AppModel.text` is.
    private final class Document: ObservableObject {
        var text = "Some prose"
        init(_ text: String = "Some prose") { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var document: Document
        var insertion: EditorInsertion?
        var checklistToggle = 0
        var listCommand: AppModel.PendingListCommand?

        var body: some View {
            LiveTextEditor(
                text: $document.text, documentIdentity: "callout.md", generation: 0,
                generationKeepsPosition: false, findSelection: nil, insertion: insertion,
                checklistToggle: checklistToggle, listCommand: listCommand,
                context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
                onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
            )
        }
    }

    private static func editorView(in view: NSView) -> HeftTextKit2View? {
        if let found = view as? HeftTextKit2View { return found }
        for child in view.subviews {
            if let found = editorView(in: child) { return found }
        }
        return nil
    }

    private static func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static func window(showing content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    /// The edit lands inside the same update that then checks the buffer
    /// against the note, whose value is from before the edit.
    @Test("Insert callout keeps its text and opens the callout menu")
    func calloutSurvivesTheUpdate() async throws {
        let document = Document()
        let host = NSHostingView(rootView: Host(document: document))
        let window = Self.window(showing: host)
        defer { window.close() }
        await Self.settle()
        let view = try #require(Self.editorView(in: host))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        host.rootView = Host(document: document, insertion: AppModel.callout(generation: 1))
        await Self.settle()

        #expect(view.string == "Some prose\n\n> [!")
        #expect(document.text == view.string)
        #expect(view.selectedRange() == NSRange(location: (view.string as NSString).length, length: 0))
        let panel = try #require(view.subviews.compactMap { $0 as? WikiCompletionPanel }.first)
        #expect(panel.listRect.height > WikiCompletionMetrics.height(rows: 1))
    }

    @Test("Toggle checkbox keeps its edit")
    func checklistSurvivesTheUpdate() async throws {
        let document = Document()
        let host = NSHostingView(rootView: Host(document: document))
        let window = Self.window(showing: host)
        defer { window.close() }
        await Self.settle()
        let view = try #require(Self.editorView(in: host))

        host.rootView = Host(document: document, checklistToggle: 1)
        await Self.settle()

        #expect(view.string.contains("[ ]"))
        #expect(document.text == view.string)
    }

    @Test("List commands keep their edits")
    func listCommandsSurviveTheUpdate() async throws {
        let document = Document()
        let host = NSHostingView(rootView: Host(document: document))
        let window = Self.window(showing: host)
        defer { window.close() }
        await Self.settle()
        let view = try #require(Self.editorView(in: host))

        host.rootView = Host(document: document, listCommand: .init(kind: .bullets, generation: 1))
        await Self.settle()
        #expect(view.string == "- Some prose")

        host.rootView = Host(document: document, listCommand: .init(kind: .indent, generation: 2))
        await Self.settle()
        #expect(view.string.hasSuffix("- Some prose"))
        #expect(view.string.first == "\t" || view.string.first == " ")
        #expect(document.text == view.string)
    }

    @Test("Indenting a selection moves every item in it, and only items")
    func indentMovesEverySelectedItem() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let source = "- a\n- b\nplain\n- c"
        view.string = source
        let selection = NSRange(location: 2, length: (source as NSString).length - 2)
        view.setSelectedRange(selection)

        view.runListCommand(.indent)
        #expect(view.string == "\t- a\n\t- b\nplain\n\t- c")
        #expect(view.selectedRange() == NSRange(location: 3, length: selection.length + 2))

        view.runListCommand(.outdent)
        #expect(view.string == source)
        #expect(view.selectedRange() == selection)

        view.insertTab(nil)
        #expect(view.string == "\t- a\n\t- b\nplain\n\t- c")
    }

    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    @Test("Indenting a selection is one undo step that puts it all back")
    func indentSelectionUndoes() {
        let host = UndoHost()
        host.manager.groupsByEvent = false
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = host
        let source = "- a\nplain\n- b"
        view.string = source
        let selection = NSRange(location: 0, length: (source as NSString).length)
        view.setSelectedRange(selection)

        host.manager.beginUndoGrouping()
        view.runListCommand(.indent)
        host.manager.endUndoGrouping()
        #expect(view.string == "\t- a\nplain\n\t- b")

        host.manager.undo()
        #expect(view.string == source)
        #expect(view.selectedRange() == selection)
    }

    @Test("The open menu shows the arrow, not the text cursor")
    func menuTakesTheArrow() throws {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant("Some prose"), documentIdentity: "callout.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.delegate = coordinator
        view.string = "Some prose"
        let window = Self.window(showing: view)
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 10, length: 0))

        view.type(AppModel.callout(generation: 1))
        let panel = try #require(view.subviews.compactMap { $0 as? WikiCompletionPanel }.first)
        let menu = panel.convert(panel.listRect, to: view)
        #expect(!menu.isEmpty)
        #expect(view.cursorOverride(at: CGPoint(x: menu.midX, y: menu.midY), among: []) == .arrow)
        #expect(view.cursorOverride(at: CGPoint(x: menu.maxX + 40, y: menu.midY), among: []) == nil)
    }

    /// A command over several lines must only replace what it changes:
    /// replaced whole, every line took the first character's attributes, and
    /// a line whose text was the same kept them, as the restyle only redoes
    /// what changed. Prose under twice-indented bullets got the hairline font.
    @Test("Lines a list command leaves alone keep their styling")
    func untouchedLinesKeepTheirStyling() async throws {
        let cases: [(String, [AppModel.PendingListCommand.Kind], Int)] = [
            ("- asf\n- asdfsdf\n\nadfasdf\nasfdsadf", [.indent, .indent], 0),
            ("bread\n* milk\n\nafter", [.bullets], 0),
            ("- milk\n\n- bread\nafter", [], 1),
        ]
        for (source, commands, checklist) in cases {
            let document = Document(source)
            let host = NSHostingView(rootView: Host(document: document))
            let window = Self.window(showing: host)
            defer { window.close() }
            await Self.settle()
            let view = try #require(Self.editorView(in: host))
            window.makeFirstResponder(view)
            let end = source.hasSuffix("after") ? (source as NSString).length - 6 : (source as NSString).length
            view.setSelectedRange(NSRange(location: 0, length: end))

            var steps: [Host] = commands.enumerated().map { index, kind in
                Host(document: document, listCommand: .init(kind: kind, generation: index + 1))
            }
            if checklist > 0 { steps.append(Host(document: document, checklistToggle: checklist)) }
            for step in steps {
                host.rootView = step
                await Self.settle()
                let width = max(240, (view.textContainer?.size.width ?? 640) - 8)
                let (expected, _) = IncrementalStylingCheck.reference(
                    view.string, selection: view.selectedRange(),
                    context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
                    contentWidth: width
                )
                let storage = try #require(view.textStorage)
                let difference = IncrementalStylingCheck.firstDifference(storage, expected)
                #expect(difference == nil, "\(source.debugDescription): \(difference ?? "")")
            }
        }
    }

    @Test("With Vim on, the callout menu takes the arrow keys")
    func vimTypesCalloutInInsertMode() throws {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant("Some prose"), documentIdentity: "callout.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = "Some prose"
        let window = Self.window(showing: view)
        defer { window.close() }
        view.vimEnabled = true
        view.setSelectedRange(NSRange(location: 9, length: 0))

        view.type(AppModel.callout(generation: 1))
        let panel = try #require(view.subviews.compactMap { $0 as? WikiCompletionPanel }.first)
        let opened = panel.listRect

        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: down,
            charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125
        ))
        view.keyDown(with: event)

        #expect(opened.height > 0)
        #expect(panel.listRect == opened)
        #expect(view.string == "Some prose\n\n> [!")
    }
}
