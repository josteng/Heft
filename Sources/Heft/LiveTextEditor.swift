import AppKit
import HeftCore
import SwiftUI

struct FindSelection: Equatable {
    let range: NSRange
    let generation: Int
}

/// The editing surface: one continuous TextKit 2 text view.
///
/// Replaces the block-swapping editor. That design rendered each block as a
/// SwiftUI view and swapped the focused one for a text field, which meant every
/// text-editor behaviour — caret movement across blocks, list continuation,
/// keeping an emptied line, stable heights — had to be re-implemented by hand,
/// and each one was a fresh bug.
///
/// Here the document is always one editable buffer, the way Obsidian's editor
/// is. Markup is *collapsed* rather than removed: hidden runs keep their
/// characters in the storage and are given a hairline font and clear colour, so
/// they occupy no visible space. The text on disk is never rewritten, and
/// selecting across hidden markup still copies the real source.
///
/// TextKit 2 rather than 1 because `NSTextLayoutFragment` can be subclassed to
/// draw per-block decoration — rounded card backgrounds, padding, rules — which
/// TextKit 1's attribute vocabulary genuinely cannot express.
struct LiveTextEditor: NSViewRepresentable {
    @Binding var text: String
    let generation: Int
    let findSelection: FindSelection?
    let context: RenderContext
    let onAttachment: (NSPasteboard) -> String?
    let onFollowLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context nsContext: Context) -> NSScrollView {
        let textView = HeftTextKit2View(usingTextLayoutManager: true)
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = false
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.linkTextAttributes = [:]
        textView.delegate = nsContext.coordinator
        textView.onAttachment = onAttachment
        textView.textContainer?.widthTracksTextView = true
        // The delegate hands each paragraph its widgets; without it tables,
        // formulae, images and list glyphs have nothing to draw them.
        textView.textLayoutManager?.delegate = nsContext.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.string = text
        nsContext.coordinator.lastGeneration = generation
        nsContext.coordinator.restyle(textView)
        textView.onWidthChange = { [weak textView, weak coordinator = nsContext.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.restyle(textView)
        }
        textView.onTrackingEnded = { [weak textView, weak coordinator = nsContext.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.trackingEnded(textView)
        }
        textView.onFirstResponderChange = { [weak textView, weak coordinator = nsContext.coordinator] focused in
            guard let textView, let coordinator else { return }
            coordinator.focusChanged(focused, in: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context nsContext: Context) {
        guard let textView = scrollView.documentView as? HeftTextKit2View else { return }
        nsContext.coordinator.parent = self
        textView.onAttachment = onAttachment

        if let findSelection,
           nsContext.coordinator.lastFindGeneration != findSelection.generation {
            nsContext.coordinator.lastFindGeneration = findSelection.generation
            nsContext.coordinator.selectFindResult(findSelection.range, in: textView)
        } else if findSelection == nil {
            nsContext.coordinator.hideSelectionWhenUnfocused(in: textView)
        }

        // Link and embed rendering depends on the index, which finishes loading
        // after the first restyle and is rebuilt whenever the vault changes on
        // disk. Without this an embed styled before the index arrived stays an
        // unresolved orange filename instead of becoming a picture.
        let fingerprint = "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")/\(context.colorfulFormatting)"
        if nsContext.coordinator.indexFingerprint != fingerprint {
            nsContext.coordinator.indexFingerprint = fingerprint
            nsContext.coordinator.restyle(textView)
        }

        if nsContext.coordinator.lastGeneration != generation {
            nsContext.coordinator.lastGeneration = generation
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scroll(.zero)
            }
            nsContext.coordinator.restyle(textView)
        } else if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length), length: 0
            ))
            nsContext.coordinator.restyle(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveTextEditor
        var lastGeneration = -1
        var layout = LiveLayout()
        var indexFingerprint = ""
        var lastFindGeneration = -1
        private var revealedLine = NSRange(location: NSNotFound, length: 0)
        private var needsRevealRestyle = false
        private var pendingScope: InvalidationScope = .revealedLines
        private var restyleTask: Task<Void, Never>?
        private var revealsSelection = true

        init(_ parent: LiveTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            scheduleRestyle(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let line = (textView.string as NSString).lineRange(for: textView.selectedRange())
            // Only a change of *line* alters what is revealed; moving within a
            // line must not trigger a restyle or typing stutters.
            guard !NSEqualRanges(line, revealedLine) else { return }

            // Never mid-drag: see `HeftTextKit2View.isTrackingMouse`.
            restyle(textView, scope: .revealedLines)
        }

        /// Runs whatever restyle was held back while the mouse was down.
        func trackingEnded(_ textView: NSTextView) {
            guard needsRevealRestyle else { return }
            needsRevealRestyle = false
            let scope = pendingScope
            pendingScope = .revealedLines
            restyle(textView, scope: scope)
        }

        func selectFindResult(_ match: NSRange, in textView: NSTextView) {
            guard match.location != NSNotFound, match.length > 0 else { return }
            revealsSelection = true
            textView.setSelectedRange(match)
            restyle(textView)
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.showFindIndicator(for: match)
        }

        func focusChanged(_ focused: Bool, in textView: NSTextView) {
            let shouldReveal = focused || parent.findSelection != nil
            guard shouldReveal != revealsSelection else { return }
            revealsSelection = shouldReveal
            restyle(textView)
        }

        func hideSelectionWhenUnfocused(in textView: NSTextView) {
            guard textView.window?.firstResponder !== textView, revealsSelection else { return }
            revealsSelection = false
            restyle(textView)
        }

        private func scheduleRestyle(_ textView: NSTextView) {
            restyleTask?.cancel()
            restyleTask = Task { @MainActor [weak textView] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let textView else { return }
                self.restyle(textView)
            }
        }

        /// - Parameter scope: which fragments must be rebuilt afterwards.
        ///   Relaying out the whole document moves the scroll position, so
        ///   caret movement asks for `.revealedLines` and gets no jump.
        func restyle(_ textView: NSTextView, scope: InvalidationScope = .whole) {
            guard let storage = textView.textStorage else { return }

            // Nothing may touch attributes or layout while a drag is tracking,
            // whatever asked for it: SwiftUI can call `updateNSView` at any
            // moment, including from inside the loop.
            if (textView as? HeftTextKit2View)?.isTrackingMouse == true {
                pendingScope = pendingScope == .whole || scope == .whole ? .whole : .revealedLines
                needsRevealRestyle = true
                return
            }

            let selection = textView.selectedRange()
            let previouslyRevealed = revealedLine
            revealedLine = revealsSelection
                ? (textView.string as NSString).lineRange(for: selection)
                : NSRange(location: NSNotFound, length: 0)

            let width = textView.textContainer?.size.width ?? Theme.contentMaxWidth
            let previous = layout.signature
            layout = LiveStyler.apply(
                to: storage,
                revealedLine: revealedLine,
                context: parent.context,
                contentWidth: max(240, width - 8)
            )

            switch scope {
            case .revealedLines:
                if layout.signature != previous,
                   let manager = textView.textLayoutManager,
                   let content = manager.textContentManager {
                    // A multi-line widget such as a table belongs to its first
                    // paragraph. A find match can select a later row, so
                    // invalidating only that row would leave the old widget
                    // painted over the newly revealed source.
                    manager.invalidateLayout(for: content.documentRange)
                } else {
                    // Ordinary caret movement only changes the line it left
                    // and the one it entered, avoiding a full reflow.
                    invalidate(previouslyRevealed, in: textView)
                    invalidate(revealedLine, in: textView)
                }
            case .whole:
                // Editing inside a paragraph already invalidates it, so a full
                // relayout is only needed when widgets appear or disappear.
                if layout.signature != previous,
                   let manager = textView.textLayoutManager,
                   let content = manager.textContentManager {
                    manager.invalidateLayout(for: content.documentRange)
                }
            }

            settleLayout(textView)
            textView.scrollRangeToVisible(selection)
        }

        /// Lays the whole document out now instead of letting TextKit 2 do it
        /// lazily.
        ///
        /// Lazy layout estimates the height of regions it has not reached, and
        /// those estimates assume ordinary lines. This editor's fragments are
        /// nothing like ordinary: a six-line table is one 148pt fragment plus
        /// five hairlines, an embed is a 160pt line. So the estimate is far
        /// enough out that scrolling or clicking makes the document resize as
        /// layout catches up, sliding the text under the pointer and turning a
        /// click into a drag-selection. Notes are small enough that laying the
        /// whole thing out costs a few milliseconds and removes the guesswork.
        private func settleLayout(_ textView: NSTextView) {
            guard let manager = textView.textLayoutManager,
                  let content = manager.textContentManager,
                  textView.string.utf16.count <= 400_000
            else { return }
            manager.ensureLayout(for: content.documentRange)
        }

        enum InvalidationScope { case whole, revealedLines }

        private func invalidate(_ range: NSRange, in textView: NSTextView) {
            guard range.location != NSNotFound, range.length > 0,
                  let manager = textView.textLayoutManager,
                  let content = manager.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }
            manager.invalidateLayout(for: textRange)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            parent.onFollowLink(url)
            return true
        }
    }
}

extension LiveTextEditor.Coordinator: NSTextLayoutManagerDelegate {
    /// Hands every paragraph the widgets the last restyle computed for it.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = HeftLayoutFragment(
            textElement: textElement, range: textElement.elementRange
        )
        guard let content = textLayoutManager.textContentManager else { return fragment }
        let start = content.offset(from: content.documentRange.location, to: location)
        fragment.elementStart = start
        fragment.widget = layout.blocks[start]
        fragment.inlineMath = layout.inlineMath[start] ?? []
        return fragment
    }
}

/// Text view with vault-aware paste and list continuation.
final class HeftTextKit2View: NSTextView {
    var onAttachment: ((NSPasteboard) -> String?)?
    var onFirstResponderChange: ((Bool) -> Void)?
    /// Called when the usable width changes. Tables are measured against it, so
    /// a stale width leaves columns squeezed; the first layout in particular
    /// happens after the initial restyle, when the container is still zero.
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFirstResponderChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFirstResponderChange?(false) }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastWidth) > 1 else { return }
        lastWidth = newSize.width
        // Restyling invalidates layout, which is not safe to do from inside a
        // layout pass; the guard above keeps this from repeating.
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            self?.onWidthChange?()
        }
    }

    /// A click in a task line's gutter hits the drawn checkbox rather than the
    /// text, and toggles it. The box is painted, not a real control, so the hit
    /// test is done here against the same geometry `LiveStyler` laid out.
    /// True for as long as the text view is tracking a mouse drag.
    ///
    /// `super.mouseDown` runs its own event loop until the button comes up, and
    /// posts selection changes from inside it. Restyling there rewrites the
    /// attributes the loop is mid-way through hit-testing against, which lands
    /// the caret on the wrong character and leaves a stray selection behind.
    /// Restyling waits for the loop to finish instead.
    private(set) var isTrackingMouse = false
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, toggleTask(at: convert(event.locationInWindow, from: nil)) {
            return
        }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onTrackingEnded?()
    }


    private func toggleTask(at point: CGPoint) -> Bool {
        let text = string as NSString
        guard text.length > 0 else { return false }
        // Checkboxes sit in the gutter, which moves right with nesting depth.
        // This only rules out clicks far into the text; the exact gutter test
        // for the clicked line happens below.
        guard point.x < textContainerInset.width + LiveStyler.listIndent(depth: 6) else { return false }
        let index = min(characterIndexForInsertion(at: point), text.length - 1)
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        let source = text.substring(with: line)

        guard let marker = source.range(
            of: #"^[ \t]*([-*+]|\d+[.)])[ \t]+\[([ xX])\]"#, options: .regularExpression
        ) else { return false }

        let leading = source.prefix { $0 == " " || $0 == "\t" }
        let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
            + (leading.filter { $0 == " " }.count / 2)
        let indent = LiveStyler.listIndent(depth: depth) + textContainerInset.width
        guard point.x >= indent - 24, point.x <= indent - 4 else { return false }

        // The box is the last three characters of the matched marker.
        let boxStart = line.location + source.distance(from: source.startIndex, to: marker.upperBound) - 3
        let box = NSRange(location: boxStart, length: 3)
        let checked = text.substring(with: box).lowercased() == "[x]"
        let replacement = checked ? "[ ]" : "[x]"

        guard shouldChangeText(in: box, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: box, with: replacement)
        didChangeText()
        return true
    }

    override func paste(_ sender: Any?) {
        if let markdown = onAttachment?(NSPasteboard.general) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let markdown = onAttachment?(sender.draggingPasteboard) {
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Continues a list on Enter, and ends it when the item is left empty —
    /// the behaviour every editor has and the block version never got right.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        let line = text.substring(with: text.lineRange(for: NSRange(location: caret.location, length: 0)))
            .trimmingCharacters(in: .newlines)

        guard let marker = Self.listMarker(of: line) else {
            super.insertNewline(sender)
            return
        }

        // Enter on an item with no content ends the list instead of adding
        // another empty bullet.
        if line.count <= marker.count {
            let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
            let strip = NSRange(location: lineRange.location, length: line.count)
            if shouldChangeText(in: strip, replacementString: "") {
                textStorage?.replaceCharacters(in: strip, with: "")
                didChangeText()
            }
            super.insertNewline(sender)
            return
        }

        super.insertNewline(sender)
        insertText(marker, replacementRange: selectedRange())
    }

    /// `- `, `* `, `- [ ] `, `3. ` … with indentation, or nil for prose.
    /// A checked task yields an unchecked one.
    static func listMarker(of line: String) -> String? {
        guard let match = line.range(
            of: #"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#, options: .regularExpression
        ) else { return nil }
        return String(line[match])
            .replacingOccurrences(of: "[x]", with: "[ ]")
            .replacingOccurrences(of: "[X]", with: "[ ]")
    }
}
