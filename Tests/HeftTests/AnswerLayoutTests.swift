import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// An Ask answer is an AppKit text view inside SwiftUI, measured by SwiftUI
/// at whatever widths it likes to try. The text drawn must follow the width
/// the view is given, not the last width it was measured at.
@MainActor
@Suite("Ask answer layout")
struct AnswerLayoutTests {
    final class Unfocusable: NSWindow { override func makeFirstResponder(_ r: NSResponder?) -> Bool { false } }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    @Test("The answer wraps at the column's width, after the column changes width")
    func wrapsToColumn() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = AgentChat(question: "What else can you tell me?", scope: "")
        chat.turns[0].answer = String(repeating: "The beds by the south fence want tomatoes and the shed wants beans. ", count: 6)
        try AgentChatStore.save(chat, in: root)
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { model.closeWorkspace() }
        model.agent.load(vaultRoot: root)
        model.agent.open(try #require(model.agent.chats.first))

        let host = NSHostingView(rootView: AgentConversationView(runner: model.agent, onLeave: {}).environmentObject(model))
        let window = Unfocusable(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Wide, then narrow, then a little wider: as the right sidebar opens
        // and is dragged.
        for width in [520.0, 260, 300] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let answer = try #require(textViews(in: host).first)
            let container = try #require(answer.textContainer)
            #expect(answer.convert(answer.bounds, to: host).maxX <= width + 0.5, "the answer runs past the column at \(width)")
            #expect(abs(container.size.width - answer.bounds.width) < 0.5,
                    "laid out at \(container.size.width) in a view \(answer.bounds.width) wide")
            let used = try #require(answer.layoutManager).usedRect(for: container).height
            #expect(abs(answer.bounds.height - ceil(used)) < 1.5, "height \(answer.bounds.height) for text \(used) tall")
        }
    }

    @Test("A path in a question shows as its name, linked: a note as a note, a file as itself")
    func questionPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-question-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Projects/Garden plan.md")
        let pdf = root.appendingPathComponent("Seed list.pdf")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        try "y".write(to: pdf, atomically: true, encoding: .utf8)

        let shown = AnswerText.question("Compare \(note.path) with \(pdf.path)?", vaultRoot: root)
        #expect(String(shown.characters) == "Compare Garden plan with Seed list.pdf?")
        let links = shown.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.first?.scheme == AnswerText.noteScheme)
        #expect(links.last?.isFileURL == true)
    }

    @Test("Suggestions name the open note, and stand without one")
    func suggestions() {
        let withNote = ChatsPanel.suggestions(note: "Garden plan")
        #expect(withNote.first == "What is \u{201C}Garden plan\u{201D} about?")
        #expect(ChatsPanel.suggestions(note: nil).allSatisfy { !$0.contains("\u{201C}") })
        #expect(!ChatsPanel.suggestions(note: nil).isEmpty)
    }

    @Test("A dropped note is its wikilink, with its folder only when the name is not unique")
    func droppedNotes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-drop-\(UUID().uuidString)")
        for folder in ["Projects", "Archive"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Projects/Garden plan.md", "Projects/Budget.md", "Archive/Budget.md"] {
            try "x".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { model.closeWorkspace() }
        for _ in 0..<600 where model.index.notes.count < 3 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(model.askText(forDropped: root.appendingPathComponent("Projects/Garden plan.md")) == "[[Garden plan]]")
        #expect(model.askText(forDropped: root.appendingPathComponent("Archive/Budget.md")) == "[[Archive/Budget]]")
        let outside = URL(fileURLWithPath: "/Volumes/Elsewhere/report.pdf")
        #expect(model.askText(forDropped: outside) == outside.path)

        let shown = AnswerText.question("Compare [[Garden plan]] with it", vaultRoot: root)
        #expect(String(shown.characters) == "Compare Garden plan with it")
        #expect(shown.runs.compactMap(\.link).first?.scheme == AnswerText.noteScheme)
    }

    @Test("A path in the field keeps its text and shows its name; the folders are collapsed")
    func fieldCollapsesFolders() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-field-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Some Folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Some Folder/seed order.pdf")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let text = "Compare \(file.path) with [[Seeds]]"

        let host = NSHostingView(rootView: BarField(
            text: .constant(text), placeholder: "", onSubmit: {}, onMove: { _ in }, onCancel: {},
            onTab: { true }, onBackspaceWhenEmpty: { false }, selectAllRequest: 0,
            metrics: .sidebar, focusesOnAppear: false
        ))
        let window = Unfocusable(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try #require(textViews(in: host).first)
        let storage = try #require(view.textStorage)
        #expect(view.string == text, "the text sent is untouched")
        let ns = text as NSString
        let folder = ns.range(of: "Some Folder")
        let name = ns.range(of: "seed order.pdf")
        let bracket = ns.range(of: "[[")
        let size = { (at: Int) in (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        #expect(size(folder.location) < 1, "the folders are collapsed")
        #expect(size(bracket.location) < 1, "and a wikilink's brackets")
        #expect(size(name.location) > 10, "the name is drawn")
    }

    @Test("Block Markdown in an answer draws as headings, tasks and bullets, not as typed")
    func blockMarkdown() throws {
        let answer = "Two areas:\n\n## Heft\n\n- [ ] Sign the build\n- [x] Write notes\n- Testing the bar\n---\n```\n- kept\n```"
        let shown = AnswerText.attributed(answer)
        let text = String(shown.characters)
        #expect(text.hasPrefix("Two areas:\n\nHeft\n\n☐ Sign the build\n☑ Write notes\n• Testing the bar\n"))
        #expect(!text.contains("---"), "a rule is left out")
        #expect(text.contains("- kept") && !text.contains("• kept"), "a code block keeps what is in it")
        let heading = try #require(shown.range(of: "Heft"))
        #expect(shown[heading].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)

        // A wrapped item's later lines start under its text.
        let drawn = SelectableAnswer.appKit(shown)
        let item = (drawn.string as NSString).range(of: "☐ Sign")
        let style = try #require(drawn.attribute(.paragraphStyle, at: item.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > 5)
    }

    @Test("History groups chats by when they were last answered, leaving empty groups out")
    func historyGroups() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        func chat(_ title: String, daysAgo: Int) -> AgentChat {
            var made = AgentChat(question: title, scope: "")
            made.updatedAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return made
        }
        let chats = [chat("Today's", daysAgo: 0), chat("Yesterday's", daysAgo: 1), chat("Last week's", daysAgo: 4), chat("Old", daysAgo: 30)]
        let groups = ChatHistory<EmptyView>.grouped(chats, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
        #expect(groups.map { $0.chats.map(\.title) } == [["Today's"], ["Yesterday's"], ["Last week's"], ["Old"]])
        #expect(ChatHistory<EmptyView>.grouped([chats[3]], now: now, calendar: calendar).map(\.title) == ["Earlier"])
    }

    @Test("A chat named after a question with a path shows the file's name")
    func titleWithPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("feedback.pdf")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(AnswerText.shownTitle("Summarise the feedback here: \(file.path)") == "Summarise the feedback here: feedback.pdf")
    }

    @Test("A link in a chat finds its vault item, and Ask About puts one in the field")
    func linksAndAskAbout() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heft-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("Projects/Garden plan.md"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("Projects/plan.pdf"), atomically: true, encoding: .utf8)
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { model.closeWorkspace() }
        for _ in 0..<600 where model.tree == nil || model.index.notes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let note = try #require(URL(string: "\(AnswerText.noteScheme)://Garden%20plan"))
        #expect(model.vaultItem(forLink: note)?.relativePath == "Projects/Garden plan.md")
        let folder = try #require(URL(string: "\(AnswerText.noteScheme)://Projects"))
        #expect(model.vaultItem(forLink: folder)?.isFolder == true)
        #expect(model.vaultItem(forLink: root.appendingPathComponent("Projects/plan.pdf"))?.relativePath == "Projects/plan.pdf")
        #expect(model.vaultItem(forLink: URL(fileURLWithPath: "/Volumes/Elsewhere/plan.pdf")) == nil)

        model.askAbout(root.appendingPathComponent("Projects/Garden plan.md"))
        #expect(model.askInsertRequest == "[[Garden plan]]")
        #expect(model.isInspectorVisible)
        #expect(model.inspectorModeRequest == .chats)
    }

    final class FieldState: ObservableObject {
        @Published var text = ""
        @Published var focus = 0
    }

    private struct FieldHost: View {
        @ObservedObject var state: FieldState
        var body: some View {
            BarField(
                text: $state.text, placeholder: "", onSubmit: {}, onMove: { _ in }, onCancel: {},
                onTab: { true }, onBackspaceWhenEmpty: { false }, selectAllRequest: 0,
                metrics: .sidebar, focusRequest: state.focus, focusesOnAppear: false
            )
        }
    }

    /// Ask About and a drop add to the field and put the caret after: typing
    /// on must not replace what was added.
    @Test("Something added to the field leaves the caret after it, nothing selected")
    func caretAfterInsert() async throws {
        let state = FieldState()
        let host = NSHostingView(rootView: FieldHost(state: state))
        let window = Unfocusable(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        state.text = "Compare [[Garden plan]] "
        state.focus += 1
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try #require(textViews(in: host).first)
        #expect(view.selectedRange() == NSRange(location: (state.text as NSString).length, length: 0))
    }
}
