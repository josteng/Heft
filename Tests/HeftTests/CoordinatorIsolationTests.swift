import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// One editor's coordinator, handed another editor's text view.
///
/// The delegate callbacks arrive through the notification centre, which
/// delivers a text view's notifications to observers registered for other
/// views too. Every one of them read the view out of the notification and
/// acted on it, so a caret moving in one window restyled another window's
/// note with the wrong note's context and dropped its pointer regions. It
/// showed up first as two editor tests failing once in every several runs,
/// but only while the suite was loaded enough for the notification to land
/// mid-test.
@MainActor
@Suite("Editor coordinator isolation")
struct CoordinatorIsolationTests {

    private func coordinator(for textView: HeftTextKit2View) -> LiveTextEditor.Coordinator {
        let editor = LiveTextEditor(
            text: .constant(textView.string), documentIdentity: "own.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        textView.delegate = coordinator
        return coordinator
    }

    private func editor(_ source: String) -> HeftTextKit2View {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.string = source
        _ = LiveStyler.apply(
            to: view.textStorage!, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 644
        )
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    @Test("A caret moving in one editor leaves another editor's regions alone")
    func selectionChangeIgnoresForeignViews() {
        let own = editor("- [ ] mine\n")
        let coordinator = coordinator(for: own)

        let foreign = editor("- [ ] one\n- [ ] two\n")
        let before = foreign.pointerRects()
        #expect(before.count == 2)

        // The regions are deliberately kept until the view that owns them says
        // otherwise, so the edit below must not be what rebuilds them.
        foreign.string = "- [ ] one\n"
        _ = LiveStyler.apply(
            to: foreign.textStorage!, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 644
        )
        foreign.textLayoutManager?.ensureLayout(for: foreign.textLayoutManager!.documentRange)

        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: foreign)
        )

        #expect(foreign.pointerRects() == before, "the foreign view's cached regions were dropped")
    }

    @Test("An edit in one editor does not publish another editor's text")
    func textChangeIgnoresForeignViews() {
        let own = editor("mine\n")
        let coordinator = coordinator(for: own)

        let foreign = editor("theirs\n")
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: foreign)
        )

        #expect(coordinator.scheduledRestyleCount == 0)
    }
}
