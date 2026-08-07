import AppKit
import HeftCore
import SwiftUI

/// A self-sizing text view holding one block's markdown source.
///
/// This is the "focused" half of block editing: every other block renders as a
/// SwiftUI view, and the one under the cursor swaps to this so it can be typed
/// into. Using a real `NSTextView` rather than SwiftUI's `TextEditor` is what
/// buys undo, IME, spell-check, find, and system text services for free — the
/// things that make an editor feel native. Only the *boundary* behaviour
/// (leaving a block via the arrow keys) has to be written by hand.
struct BlockSourceField: NSViewRepresentable {
    @Binding var text: String
    /// Grows the container as the block gets taller.
    @Binding var height: CGFloat
    let isFocused: Bool
    /// The rendered block's own font. A heading edited at body size would
    /// change the block's height the moment it gained focus.
    let font: NSFont
    /// Where the user clicked, in the block's own coordinate space. The caret
    /// lands there rather than at the end, which is what makes clicking into a
    /// word feel like clicking into text instead of jumping to the end.
    let caretPoint: CGPoint?
    /// -1 when the caret leaves via the top, +1 via the bottom.
    let onMoveOut: (Int) -> Void
    /// Enter pressed on a trailing blank line: split into a new block.
    let onSplit: (String, String) -> Void
    /// Backspace at the very start: merge into the previous block.
    let onMergeBack: () -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BlockTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: CGFloat(0), height: unbounded))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let view = BlockTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        // Set explicitly: the focus comes from a click on a *different* view
        // (the rendered block), so the text view never receives the mouse-down
        // that would normally establish editing and start the caret blinking.
        view.isEditable = true
        view.isSelectable = true
        view.insertionPointColor = .controlAccentColor
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.font = font

        view.onMoveOut = onMoveOut
        view.onSplit = onSplit
        view.onMergeBack = onMergeBack
        view.onCommit = onCommit

        view.string = text
        context.coordinator.highlight(view)
        return view
    }

    func updateNSView(_ view: BlockTextView, context: Context) {
        context.coordinator.parent = self
        view.onMoveOut = onMoveOut
        view.onSplit = onSplit
        view.onMergeBack = onMergeBack
        view.onCommit = onCommit

        if view.string != text {
            view.string = text
            context.coordinator.highlight(view)
        }
        if isFocused, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            // The rendered block and this field share an origin and metrics, so
            // the tap point carries over directly.
            if let caretPoint {
                view.setSelectedRange(NSRange(
                    location: view.characterIndexForInsertion(at: caretPoint), length: 0
                ))
            } else {
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
            // Without this the caret exists but is not drawn until the next
            // real mouse event, so the block looks focused with no cursor.
            view.updateInsertionPointStateAndRestartTimer(true)
        }
        context.coordinator.reportHeight(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockSourceField
        init(_ parent: BlockSourceField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? BlockTextView else { return }
            parent.text = view.string
            highlight(view)
            reportHeight(view)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }

        func highlight(_ view: BlockTextView) {
            guard let storage = view.textStorage else { return }
            MarkdownStyler.applySource(to: storage, font: parent.font)
            // Match the rendered block's line spacing, or swapping between
            // rendered and source changes the block's height.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Theme.lineSpacing
            storage.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: storage.length)
            )
        }

        /// Reports the laid-out height so the SwiftUI row can size to content;
        /// without it the field collapses or clips as lines are added.
        func reportHeight(_ view: BlockTextView) {
            guard let layoutManager = view.layoutManager, let container = view.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let target = max(parent.font.pointSize + 8, ceil(used) + 2)
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
        }
    }
}

/// Text view that hands the caret back to the container at its edges.
final class BlockTextView: NSTextView {
    var onMoveOut: ((Int) -> Void)?
    var onSplit: ((String, String) -> Void)?
    var onMergeBack: (() -> Void)?
    var onCommit: (() -> Void)?

    private var caretIsOnFirstLine: Bool {
        let text = string as NSString
        return text.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location == 0
    }

    private var caretIsOnLastLine: Bool {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        return NSMaxRange(line) >= text.length
    }

    override func moveUp(_ sender: Any?) {
        if caretIsOnFirstLine { onMoveOut?(-1) } else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if caretIsOnLastLine { onMoveOut?(1) } else { super.moveDown(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        // At the very start with nothing selected, merge into the block above
        // rather than swallowing the keystroke.
        if selectedRange() == NSRange(location: 0, length: 0) {
            onMergeBack?()
            return
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        // A blank final line means "start a new block"; otherwise a newline is
        // an ordinary line break inside this block (lists, code, tables).
        let trailing = text.substring(from: min(caret.location, text.length))
        let precedesBlank = text.substring(to: caret.location).hasSuffix("\n")

        if precedesBlank, trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let head = text.substring(to: max(0, caret.location - 1))
            onSplit?(head, "")
            return
        }
        // In a list, Enter at the end starts the next item immediately rather
        // than waiting for a blank line — the container re-adds the marker.
        let currentLine = text.substring(with: text.lineRange(for: NSRange(location: caret.location, length: 0)))
        let isListItem = currentLine.range(
            of: #"^[ \t]*([-*+]|\d+[.)])[ \t]+"#, options: .regularExpression
        ) != nil
        if isListItem, caret.location >= text.length, !trailing.contains("\n") {
            onSplit?(string, "")
            return
        }
        super.insertNewline(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
        window?.makeFirstResponder(nil)
    }
}
