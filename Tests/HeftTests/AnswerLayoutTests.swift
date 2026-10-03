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
}
