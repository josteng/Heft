import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Swapping the buffer for another note. TextKit builds the new document's
/// first fragment while the string is being assigned, before any restyle,
/// so what the delegate holds at that moment is what the fragment draws: a
/// new, empty note kept the previous note's table until the first keystroke.
@Suite("Swapping the document")
@MainActor
struct DocumentSwapTests {
    private func editor(_ body: String) -> (HeftTextKit2View, LiveTextEditor.Coordinator) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(body), documentIdentity: "s.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = body
        return (view, coordinator)
    }

    /// Lays the whole document out, the way drawing would, and reports the
    /// widgets its fragments carry.
    private func widgets(in view: HeftTextKit2View) -> [String] {
        guard let manager = view.textLayoutManager,
              let content = manager.textContentManager else { return [] }
        manager.ensureLayout(for: content.documentRange)
        var found: [String] = []
        manager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            if let widget = (fragment as? HeftLayoutFragment)?.widget {
                found.append(String(describing: widget).prefix(20).description)
            }
            return true
        }
        return found
    }

    @Test("Loading a note leaves nothing of the previous one for a draw to find")
    func loadLeavesNoLayoutBehind() throws {
        let (view, coordinator) = editor("Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nLast line.\n")
        coordinator.restyle(view)
        try #require(!coordinator.layout.blocks.isEmpty, "the first note has a table widget")
        try #require(!widgets(in: view).isEmpty)

        // The delegate is quiet for the assignment: a note whose last
        // restyle was slow defers the next one, and the view draws in that
        // gap with whatever the coordinator holds.
        view.delegate = nil
        coordinator.load("", into: view)
        #expect(coordinator.layout.blocks.isEmpty)
        #expect(view.liveLayout.blocks.isEmpty)
        #expect(coordinator.pendingShift == nil)
        #expect(widgets(in: view).isEmpty, "\(widgets(in: view))")

        view.delegate = coordinator
        coordinator.restyle(view)
        #expect(widgets(in: view).isEmpty)
    }
}
