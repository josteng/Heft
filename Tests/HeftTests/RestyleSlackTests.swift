import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// An edit into a run of one character, which the text diff cannot place:
/// Return after `---x` with a blank line below. The break typed in carried
/// the hidden rule's hairline font, and the pass restyled the run's far end.
@Suite("An edit into a run of one character")
@MainActor
struct RestyleSlackTests {

    private func snapshot(_ text: String, caret: Int) -> RestyleScope.Snapshot {
        RestyleScope.Snapshot(
            source: text as NSString,
            decorations: LiveDecorator.decorations(in: text),
            reveal: Reveal(selection: NSRange(location: caret, length: 0), in: text as NSString)
        )
    }

    @Test("The dirty lines reach every place the edit could have been")
    func dirtyCoversTheRun() {
        let old = snapshot("---x\n\n## Check\n", caret: 4)
        let new = snapshot("---x\n\n\n## Check\n", caret: 5)
        let edit = SourceEdit.between(old.source, new.source)
        #expect(edit.changed == NSRange(location: 6, length: 1), "the scan places it at the run's end")
        #expect(edit.slack(from: old.source, to: new.source) == 2)
        let dirty = RestyleScope.dirtyRanges(from: old, to: new)
        #expect(dirty.contains { NSLocationInRange(4, $0) }, "the break typed after ---x")
    }

    @Test("Return after text typed onto a rule matches a full restyle")
    func editorMatchesAFullRestyle() {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let text = "---\n\n## Check\n"
        let editor = LiveTextEditor(
            text: .constant(text), documentIdentity: "slack.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = text
        // The caret placed before the first pass, as opening a note on it
        // does: what is typed next takes the rule's hidden markup.
        view.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.restyle(view)

        view.insertText("x", replacementRange: view.selectedRange())
        coordinator.restyle(view)
        view.insertNewline(nil)
        coordinator.restyle(view)

        let (expected, _) = IncrementalStylingCheck.reference(
            view.string, selection: view.selectedRange(), context: context,
            contentWidth: max(240, (view.textContainer?.size.width ?? 640) - 8)
        )
        #expect(view.string == "---x\n\n\n## Check\n")
        #expect(IncrementalStylingCheck.firstDifference(view.textStorage!, expected) == nil)
    }
}
