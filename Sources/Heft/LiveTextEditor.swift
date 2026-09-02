import AppKit
import HeftCore
import HeftVimCore
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
    @ObservedObject private var vim = VimSettings.shared
    @Binding var text: String
    let generation: Int
    let findSelection: FindSelection?
    let context: RenderContext
    let onAttachment: (NSPasteboard) -> String?
    let onFollowLink: (URL) -> Void
    let onVimSearch: (VimHostAction) -> Void

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
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.usesFindBar = false
        textView.vimCaretColor = context.accentColor
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.linkTextAttributes = [:]
        textView.delegate = nsContext.coordinator
        textView.onAttachment = onAttachment
        textView.onVimSearch = onVimSearch
        textView.completionIndex = context.index
        // Also set here, not only in `updateNSView`: a note typed into before
        // SwiftUI's first update pass would expand `{{title}}` to nothing.
        textView.noteTitle = context.current?.name ?? ""
        textView.vimEnabled = vim.isEnabled
        textView.vimContinuesMarkdownStructure = vim.continuesMarkdownStructure
        textView.textContainer?.widthTracksTextView = true
        // The delegate hands each paragraph its widgets; without it tables,
        // formulae, images and list glyphs have nothing to draw them.
        textView.textLayoutManager?.delegate = nsContext.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // With a full-size content window, AppKit overlays this scroll view
        // beneath the toolbar and computes the initial safe inset for us. The
        // document starts below the controls but can move behind their native
        // scroll-edge effect.
        scrollView.automaticallyAdjustsContentInsets = true

        textView.string = text
        nsContext.coordinator.lastGeneration = generation
        nsContext.coordinator.restyle(textView)
        textView.onNeedsRestyle = { [weak textView, weak coordinator = nsContext.coordinator] in
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
        textView.onVimSearch = onVimSearch
        textView.completionIndex = context.index
        textView.vimCaretColor = context.accentColor
        // What `{{title}}` in a custom replacement expands to.
        textView.noteTitle = context.current?.name ?? ""
        textView.vimEnabled = vim.isEnabled
        textView.vimContinuesMarkdownStructure = vim.continuesMarkdownStructure
        textView.updateLinkCompletion(allowStart: false)

        // `string` includes the input method's marked text, while the SwiftUI
        // binding only represents committed source. Comparing and replacing
        // them mid-composition discards the next dead-key character.
        guard !textView.hasMarkedText() else { return }

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
        let fingerprint = "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")/"
            + "\(context.colorfulFormatting)/\(context.accentColor)/\(context.linkColor)/\(context.tagColor)/"
            + "\(context.codeColor)/\(context.boldColor)/\(context.italicColor)/\(context.headingColors)"
        if nsContext.coordinator.indexFingerprint != fingerprint {
            nsContext.coordinator.indexFingerprint = fingerprint
            nsContext.coordinator.restyle(textView)
        }

        if nsContext.coordinator.lastGeneration != generation {
            nsContext.coordinator.lastGeneration = generation
            if textView.string != text {
                textView.string = text
                nsContext.coordinator.resetStyling()
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.resetVim()
                textView.scroll(.zero)
            }
            nsContext.coordinator.restyle(textView)
        } else if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            nsContext.coordinator.resetStyling()
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
        private var reveal = Reveal.none
        private var revealedSpans = ""
        private var needsRevealRestyle = false
        private var restyleTask: Task<Void, Never>?
        private var revealsSelection = true
        /// What the storage's attributes currently represent, and the settings
        /// they were produced under. Together they are what makes a restyle
        /// incremental: the next one only has to touch where these disagree
        /// with the document in front of it.
        private var styled: RestyleScope.Snapshot?
        private var styleKey = ""

        /// Forgets that the storage is styled at all, forcing the next restyle
        /// to do the whole document.
        ///
        /// Assigning `NSTextView.string` replaces the storage's contents *and*
        /// drops every attribute on the floor, so the next pass cannot assume
        /// anything it did not rewrite is still styled.
        func resetStyling() { styled = nil }

        init(_ parent: LiveTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            (textView as? HeftTextKit2View)?.updateLinkCompletion(allowStart: true)
            scheduleRestyle(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            let line = (textView.string as NSString).lineRange(for: selection)
            // Block markup reveals per line, inline spans per caret position,
            // so both have to be checked. Moving within a line and within the
            // same set of spans changes nothing on screen, and restyling there
            // would put a stutter into every arrow key.
            (textView as? HeftTextKit2View)?.updateFormatBar()
            (textView as? HeftTextKit2View)?.updateLinkCompletion(allowStart: false)
            (textView as? HeftTextKit2View)?.updateVimCursor()
            // Backspace only reverts a substitution while the caret has not
            // left it. Moving away — by key, by click, or by anything else
            // that lands here — makes the next backspace an ordinary delete.
            (textView as? HeftTextKit2View)?.forgetSubstitution()

            guard !NSEqualRanges(line, reveal.line)
                || spanSignature(for: selection) != revealedSpans
            else { return }

            // Never mid-drag: see `HeftTextKit2View.isTrackingMouse`.
            restyle(textView)
        }

        /// Which revealable spans a caret sits inside, as a comparable key.
        private func spanSignature(for selection: NSRange) -> String {
            layout.revealableSpans.indices
                .filter { Reveal.touches(layout.revealableSpans[$0], selection) }
                .map(String.init)
                .joined(separator: ",")
        }

        /// Runs whatever restyle was held back while the mouse was down.
        func trackingEnded(_ textView: NSTextView) {
            guard needsRevealRestyle else { return }
            needsRevealRestyle = false
            restyle(textView)
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
                // Coalesce AppKit's notifications from one edit without
                // postponing styling until the user stops typing. In
                // particular, fenced code should gain token colours as each
                // token is entered.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let textView else { return }
                self.restyle(textView)
            }
        }

        /// Brings the storage's attributes back in line with its text and the
        /// caret, touching as little as it can get away with.
        ///
        /// Every keystroke used to re-decorate, re-attribute and re-lay out the
        /// whole note — twice, since the edit and the caret move that came with
        /// it each asked for one. On a long note that was tens of milliseconds
        /// of main thread before the character could be drawn. Now the previous
        /// pass is kept and diffed against this one, and only where the two
        /// disagree is rewritten; the rest keeps its attributes, and with them
        /// its layout.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }

            // Dead keys and IMEs keep an in-progress composition as marked
            // text. Rewriting attributes or invalidating layout during that
            // session makes AppKit abandon the composition and can move the
            // caret to another line. Retry once the input method has committed.
            if textView.hasMarkedText() {
                restyleTask?.cancel()
                restyleTask = Task { @MainActor [weak textView] in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled, let textView else { return }
                    self.restyle(textView)
                }
                return
            }

            // Nothing may touch attributes or layout while a drag is tracking,
            // whatever asked for it: SwiftUI can call `updateNSView` at any
            // moment, including from inside the loop.
            if (textView as? HeftTextKit2View)?.isTrackingMouse == true {
                needsRevealRestyle = true
                return
            }

            let selection = textView.selectedRange()
            let source = textView.string as NSString
            reveal = revealsSelection ? Reveal(selection: selection, in: source) : .none

            let width = textView.textContainer?.size.width ?? Theme.contentMaxWidth
            // Formulae bake their colour into a bitmap, so the styler has to be
            // told which appearance the view is actually drawn in rather than
            // resolving `labelColor` against whatever is current.
            var context = parent.context
            context.appearance = textView.effectiveAppearance
            let key = Self.styleKey(context: context, width: width)

            // Cheapest exit of all, and the common one: the debounced restyle
            // arriving after the caret's has already styled this exact state.
            // Taken before decorating, because decorating is the expensive part.
            if let styled, styleKey == key, styled.reveal == reveal,
               styled.source.isEqual(to: source as String) {
                updateTypingAttributes(for: selection, in: textView)
                (textView as? HeftTextKit2View)?.updateFormatBar()
                return
            }

            // Moving the caret changes what is revealed, not what is there, so
            // the previous parse still describes the document exactly. Worth
            // the check on its own: decorating a long note costs more than
            // every other part of an arrow key put together.
            let decorations: [MarkdownDecoration]
            if let styled, styled.source.isEqual(to: source as String) {
                decorations = styled.decorations
            } else {
                decorations = LiveDecorator.decorations(in: source as String)
            }
            let snapshot = RestyleScope.Snapshot(
                source: source, decorations: decorations, reveal: reveal
            )
            // Anything the styler reads besides the document — colours, the
            // link index, the usable width — invalidates the lot when it moves,
            // and no part of the previous pass can be kept.
            let comparable = styleKey == key ? styled : nil
            let scope = comparable.map { RestyleScope.scope(from: $0, to: snapshot) }
            styleKey = key
            styled = snapshot

            if let scope, scope.isEmpty {
                // The decorations moved with the text but nothing about them
                // changed, so what is on screen is already right.
                revealedSpans = spanSignature(for: selection)
                updateTypingAttributes(for: selection, in: textView)
                (textView as? HeftTextKit2View)?.updateFormatBar()
                restyleTask?.cancel()
                return
            }

            let previous = layout.signature
            layout = LiveStyler.apply(
                to: storage,
                reveal: reveal,
                context: context,
                contentWidth: max(240, width - 8),
                decorations: decorations,
                incremental: scope.map {
                    LiveStyler.Incremental(dirty: $0.dirty, edit: $0.edit, previous: layout)
                }
            )
            // Recorded after styling: the span list is only known once the
            // decorator has run over the current text.
            revealedSpans = spanSignature(for: selection)
            updateTypingAttributes(for: selection, in: textView)

            if let scope {
                // A widget belongs to the first paragraph of the construct it
                // draws, and the rewritten attributes already invalidate those
                // paragraphs. Asking explicitly is what guarantees the layout
                // manager comes back for a fragment whose *widget* changed
                // while its text did not — a table gaining a row, say.
                for range in scope.dirty { invalidate(range, in: textView) }
            } else if layout.signature != previous,
                      let manager = textView.textLayoutManager,
                      let content = manager.textContentManager {
                // Editing inside a paragraph already invalidates it, so a full
                // relayout is only needed when widgets appear or disappear.
                manager.invalidateLayout(for: content.documentRange)
            }

            settleLayout(textView)
            textView.scrollRangeToVisible(selection)
            // Revealing or collapsing markup reflows the line, so overlays
            // calculated from TextKit geometry must be moved after layout has
            // settled. In particular, collapsed wikilink suffixes can report
            // a stale rectangle at the readable-width boundary.
            (textView as? HeftTextKit2View)?.updateFormatBar()
            (textView as? HeftTextKit2View)?.updateVimCursor()
            // This pass styled whatever is in the storage now, so a restyle
            // queued by the edit that led here has nothing left to do.
            restyleTask?.cancel()
        }

        /// Everything a restyle depends on that is not the document itself.
        /// When any of it moves, no part of the previous pass can be kept.
        private static func styleKey(context: RenderContext, width: CGFloat) -> String {
            "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")/"
                + "\(context.colorfulFormatting)/\(context.strictLineBreaks)/\(width)/"
                + "\(context.appearance?.name.rawValue ?? "")/"
                + "\(context.accentColor)/\(context.linkColor)/\(context.tagColor)/"
                + "\(context.codeColor)/\(context.boldColor)/\(context.italicColor)/"
                + "\(context.headingColors)"
        }

        private func updateTypingAttributes(for selection: NSRange, in textView: NSTextView) {
            guard selection.length == 0 else { return }
            let source = textView.string as NSString
            let location = min(selection.location, source.length)
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let contents = source.substring(with: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard contents.isEmpty else { return }

            // Code blocks deliberately reserve a taller fixed line box. Their
            // insertion point should follow that block geometry, not prose.
            if case .codeBlock? = layout.blocks[line.location] { return }

            textView.typingAttributes = [
                .font: Theme.liveFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: LiveStyler.bodyParagraphStyle(compactEmptyLine: true),
            ]
            // TextKit 2 derives the final zero-length paragraph from typing
            // attributes. Recompute its insertion fragment without restarting
            // the user's blink cadence.
            textView.updateInsertionPointStateAndRestartTimer(false)
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
        fragment.inlineTags = layout.inlineTags[start] ?? []
        return fragment
    }
}

private final class VimBlockCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct VimInsertionDelta {
    var relativeLocation: Int
    var removedLength: Int
    var replacement: String
    var caretOffset: Int
}

private struct VimRepeatRecipe {
    var keys: [VimKey]
    var insertion: VimInsertionDelta?
}

/// Text view with vault-aware paste and list continuation.
final class HeftTextKit2View: NSTextView {
    var onAttachment: ((NSPasteboard) -> String?)?
    var onVimSearch: ((VimHostAction) -> Void)?
    var onFirstResponderChange: ((Bool) -> Void)?
    var completionIndex = VaultIndex.empty
    /// Called when the usable width changes. Tables are measured against it, so
    /// a stale width leaves columns squeezed; the first layout in particular
    /// happens after the initial restyle, when the container is still zero.
    var onNeedsRestyle: (() -> Void)?
    private var lastWidth: CGFloat = 0
    private var completionPanel: WikiCompletionPanel?
    private var completionItems: [WikiCompletionItem] = []
    private var completionSelection = 0
    private var completionIsActive = false
    private var completionQuery = ""
    private var vimEngine = VimEngine()
    private var vimPreferredX: CGFloat?
    private var vimPendingRepeatKeys: [VimKey] = []
    private var vimInsertBaseline: (text: String, location: Int)?
    private var vimLastRepeat: VimRepeatRecipe?
    private var vimIsReplaying = false
    var vimContinuesMarkdownStructure = true
    var vimCaretColor = NSColor.controlAccentColor {
        didSet { updateVimCursor() }
    }
    private lazy var vimBlockCursor: VimBlockCursorView = {
        let cursor = VimBlockCursorView()
        cursor.wantsLayer = true
        cursor.layer?.cornerRadius = 1
        cursor.isHidden = true
        addSubview(cursor, positioned: .above, relativeTo: nil)
        return cursor
    }()
    var vimEnabled = false {
        didSet {
            guard vimEnabled != oldValue else { return }
            vimEngine.reset(mode: vimEnabled ? .normal : .insert)
            VimSettings.shared.report(mode: vimEnabled ? .normal : .insert)
            if vimEnabled { dismissLinkCompletion() }
            updateVimCursor()
        }
    }

    func resetVim() {
        vimEngine.reset(mode: vimEnabled ? .normal : .insert)
        vimPreferredX = nil
        vimPendingRepeatKeys = []
        vimInsertBaseline = nil
        VimSettings.shared.report(mode: vimEngine.mode)
        updateVimCursor()
    }

    override func keyDown(with event: NSEvent) {
        guard vimEnabled,
              event.modifierFlags.intersection([.command, .option]).isEmpty,
              let key = vimKey(for: event)
        else {
            super.keyDown(with: event)
            return
        }

        if key == .character("."), vimEngine.mode == .normal, vimLastRepeat != nil {
            replayLastVimChange()
            return
        }

        if !handleVimKey(key, recordRepeat: true) {
            super.keyDown(with: event)
        }
    }

    @discardableResult
    private func handleVimKey(_ key: VimKey, recordRepeat: Bool) -> Bool {
        let modeBeforeKey = vimEngine.mode
        let wasAwaiting = vimEngine.isAwaitingMoreKeys
        let selectionBeforeKey = selectedRange()

        if recordRepeat, !vimIsReplaying {
            if modeBeforeKey == .normal, !wasAwaiting {
                vimPendingRepeatKeys = [key]
            } else if modeBeforeKey != .insert {
                vimPendingRepeatKeys.append(key)
            }
        }

        let movesVertically = isVimVerticalMovement(key)
        if movesVertically, modeBeforeKey == .normal, vimPreferredX == nil {
            vimPreferredX = vimCursorRect(at: selectedRange().location)?.minX
        } else if !movesVertically {
            vimPreferredX = nil
        }

        var output = vimEngine.handle(
            key,
            in: VimSnapshot(text: string, selection: selectedRange())
        )
        if modeBeforeKey == .normal,
           vimContinuesMarkdownStructure,
           case let .character(command) = key,
           command == "o" || command == "O" {
            output = markdownAwareOpenLineOutput(
                output,
                below: command == "o",
                source: string,
                cursor: selectionBeforeKey.location
            )
        } else if vimContinuesMarkdownStructure, output.mode == .insert {
            output = markdownAwareLineChangeOutput(
                output,
                source: string,
                cursor: selectionBeforeKey.location
            )
        }
        if movesVertically, modeBeforeKey == .normal,
           let preferredX = vimPreferredX,
           let selection = output.selection,
           selection.length == 0 {
            output.selection = NSRange(
                location: vimLocation(
                    onLineContaining: selection.location,
                    renderedX: preferredX
                ),
                length: 0
            )
        }
        guard output.consumed else {
            return false
        }

        dismissLinkCompletion()
        applyVimOutput(output)

        guard recordRepeat, !vimIsReplaying else { return true }
        if modeBeforeKey == .insert, key == .escape {
            finishVimInsertRepeat(caretLocation: selectionBeforeKey.location)
        } else if (modeBeforeKey == .replace || modeBeforeKey == .blockInsert), key == .escape {
            vimLastRepeat = VimRepeatRecipe(keys: vimPendingRepeatKeys, insertion: nil)
            vimPendingRepeatKeys = []
        } else if output.mode == .insert, modeBeforeKey != .insert {
            vimInsertBaseline = (string, selectedRange().location)
        } else if !output.edits.isEmpty, output.mode == .normal {
            vimLastRepeat = VimRepeatRecipe(keys: vimPendingRepeatKeys, insertion: nil)
            vimPendingRepeatKeys = []
        } else if output.mode == .normal, !vimEngine.isAwaitingMoreKeys,
                  output.edits.isEmpty, output.hostAction == nil {
            // Motions, yanks, cancelled commands, and unknown keys do not
            // replace Vim's most recent repeatable change.
            vimPendingRepeatKeys = []
        }
        return true
    }

    private func markdownAwareOpenLineOutput(
        _ output: VimOutput,
        below: Bool,
        source: String,
        cursor: Int
    ) -> VimOutput {
        let text = source as NSString
        guard text.length > 0 else { return output }
        let safeCursor = min(cursor, text.length - 1)
        let lineRange = text.lineRange(for: NSRange(location: safeCursor, length: 0))
        let contentRange = Self.lineContentRange(lineRange, in: text)
        let line = text.substring(with: contentRange)
        guard let structure = Self.markdownContinuation(of: line) else { return output }

        let marker = below && structure.isList
            ? Self.nextListMarker(after: structure.marker)
            : structure.marker
        let insertion = below ? NSMaxRange(lineRange) : lineRange.location
        let hasTerminator = NSMaxRange(contentRange) < NSMaxRange(lineRange)
        let replacement = below
            ? (hasTerminator ? marker + "\n" : "\n" + marker)
            : marker + "\n"
        let caret = insertion + (below && !hasTerminator ? 1 : 0) + marker.utf16.count
        var adapted = output
        adapted.edits = [VimEdit(
            range: NSRange(location: insertion, length: 0),
            replacement: replacement
        )]
        adapted.selection = NSRange(location: caret, length: 0)
        return adapted
    }

    private func markdownAwareLineChangeOutput(
        _ output: VimOutput,
        source: String,
        cursor: Int
    ) -> VimOutput {
        let text = source as NSString
        guard text.length > 0, output.edits.count == 1 else { return output }
        let safeCursor = min(cursor, text.length - 1)
        let lineRange = text.lineRange(for: NSRange(location: safeCursor, length: 0))
        let edit = output.edits[0]
        guard edit.range.location == lineRange.location,
              edit.range.length >= lineRange.length
        else { return output }
        let contentRange = Self.lineContentRange(lineRange, in: text)
        let line = text.substring(with: contentRange)
        guard let structure = Self.markdownContinuation(of: line) else { return output }

        let hasTerminator = NSMaxRange(contentRange) < NSMaxRange(lineRange)
        let replacement = structure.marker + (hasTerminator ? "\n" : "")
        var adapted = output
        adapted.edits = [VimEdit(range: edit.range, replacement: replacement)]
        adapted.selection = NSRange(
            location: edit.range.location + structure.marker.utf16.count,
            length: 0
        )
        return adapted
    }

    private static func lineContentRange(_ line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let character = text.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private func applyVimOutput(_ output: VimOutput) {
        var changedText = false
        for edit in output.edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            changedText = true
        }
        if changedText { didChangeText() }
        if let selections = output.selections, !selections.isEmpty {
            let length = (string as NSString).length
            let safe = selections.map { selection -> NSValue in
                let location = min(selection.location, length)
                return NSValue(range: NSRange(
                    location: location,
                    length: min(selection.length, length - location)
                ))
            }
            setSelectedRanges(safe, affinity: .downstream, stillSelecting: false)
        } else if let selection = output.selection {
            let length = (string as NSString).length
            let location = min(selection.location, length)
            setSelectedRange(NSRange(
                location: location,
                length: min(selection.length, length - location)
            ))
        }
        if let action = output.hostAction { performVimHostAction(action) }
        VimSettings.shared.report(mode: output.mode, message: output.message)
        updateVimCursor()
    }

    private func finishVimInsertRepeat(caretLocation: Int) {
        defer {
            vimInsertBaseline = nil
            vimPendingRepeatKeys = []
        }
        guard let baseline = vimInsertBaseline,
              let delta = vimInsertionDelta(
                from: baseline.text,
                to: string,
                insertionLocation: baseline.location,
                caretLocation: caretLocation
              )
        else { return }
        vimLastRepeat = VimRepeatRecipe(keys: vimPendingRepeatKeys, insertion: delta)
    }

    private func vimInsertionDelta(
        from old: String,
        to new: String,
        insertionLocation: Int,
        caretLocation: Int
    ) -> VimInsertionDelta? {
        let before = old as NSString
        let after = new as NSString
        let prefixLimit = min(insertionLocation, before.length, after.length)
        var prefix = 0
        while prefix < prefixLimit, before.character(at: prefix) == after.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < before.length - prefix,
              suffix < after.length - prefix,
              before.character(at: before.length - suffix - 1)
                == after.character(at: after.length - suffix - 1) {
            suffix += 1
        }
        let removedLength = before.length - prefix - suffix
        let replacementRange = NSRange(
            location: prefix,
            length: after.length - prefix - suffix
        )
        guard removedLength > 0 || replacementRange.length > 0 else { return nil }
        return VimInsertionDelta(
            relativeLocation: prefix - insertionLocation,
            removedLength: removedLength,
            replacement: after.substring(with: replacementRange),
            caretOffset: caretLocation - insertionLocation
        )
    }

    private func replayLastVimChange() {
        guard let recipe = vimLastRepeat else { return }
        vimPreferredX = nil
        vimIsReplaying = true
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            vimIsReplaying = false
            updateVimCursor()
        }

        for key in recipe.keys {
            _ = handleVimKey(key, recordRepeat: false)
        }
        guard let insertion = recipe.insertion, vimEngine.mode == .insert else { return }
        let insertionStart = selectedRange().location
        var replayReplacement = insertion.replacement
        var replayCaretOffset = insertion.caretOffset
        if insertion.relativeLocation == 0, insertion.removedLength == 0,
           let redundantMarker = redundantReplayedMarkdownMarker(
            in: replayReplacement,
            at: insertionStart
           ) {
            replayReplacement.removeFirst(redundantMarker.count)
            replayCaretOffset -= redundantMarker.utf16.count
        }
        let length = (string as NSString).length
        let location = min(max(0, insertionStart + insertion.relativeLocation), length)
        let removedLength = min(insertion.removedLength, length - location)
        let range = NSRange(location: location, length: removedLength)
        if shouldChangeText(in: range, replacementString: replayReplacement) {
            textStorage?.replaceCharacters(in: range, with: replayReplacement)
            didChangeText()
        }
        let newLength = (string as NSString).length
        setSelectedRange(NSRange(
            location: min(max(0, insertionStart + replayCaretOffset), newLength),
            length: 0
        ))
        _ = handleVimKey(.escape, recordRepeat: false)
    }

    private func redundantReplayedMarkdownMarker(
        in replacement: String,
        at insertion: Int
    ) -> String? {
        guard vimContinuesMarkdownStructure else { return nil }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(
            location: min(insertion, text.length),
            length: 0
        ))
        guard insertion >= line.location else { return nil }
        let prefix = text.substring(with: NSRange(
            location: line.location,
            length: insertion - line.location
        ))
        guard let supplied = Self.markdownContinuation(of: prefix),
              supplied.marker == prefix,
              let captured = Self.markdownContinuation(of: replacement),
              captured.isList == supplied.isList
        else { return nil }
        return captured.marker
    }

    func updateVimCursor() {
        let showsBlock = vimEnabled
            && (vimEngine.mode == .normal || vimEngine.mode == .operatorPending)
            && selectedRange().length == 0
            && window?.firstResponder === self
        let nativeCaretColor = showsBlock ? NSColor.clear : vimCaretColor
        if !insertionPointColor.isEqual(nativeCaretColor) {
            insertionPointColor = nativeCaretColor
        }
        guard showsBlock else {
            vimBlockCursor.isHidden = true
            return
        }

        let source = string as NSString
        let location = min(selectedRange().location, source.length)
        let block = vimBlockCursorRect(at: location, in: source)
        guard var frame = block, !frame.isEmpty else {
            vimBlockCursor.isHidden = true
            return
        }
        frame.size.width = max(4, frame.width)
        vimBlockCursor.frame = frame.integral
        vimBlockCursor.layer?.backgroundColor = vimCaretColor.withAlphaComponent(0.52).cgColor
        vimBlockCursor.isHidden = false
    }

    private func vimBlockCursorRect(at location: Int, in source: NSString) -> NSRect? {
        if location < source.length {
            let character = source.character(at: location)
            if character != 10, character != 13 {
                let range = source.rangeOfComposedCharacterSequence(at: location)
                if !vimCharacterIsCollapsed(at: range.location) {
                    return rect(forSelection: range)
                }
                let line = source.lineRange(for: NSRange(location: location, length: 0))
                if let visible = vimLastVisibleCharacter(
                    before: range.location,
                    lineStart: line.location,
                    source: source
                ) {
                    return rect(forSelection: visible)
                }
            }
        }

        // AppKit selections are insertion positions, so clicking past the end
        // of a non-empty line lands on its newline. Normal-mode Vim cursors are
        // character positions: cover the final character instead of drawing a
        // phantom cell after it.
        var lineStart = 0
        var lineEnd = 0
        var contentEnd = 0
        var lineProbe = location
        if location < source.length {
            let character = source.character(at: location)
            if character == 10 || character == 13 {
                guard location > 0 else { return caretRect(at: location) }
                let previous = source.character(at: location - 1)
                guard previous != 10, previous != 13 else { return caretRect(at: location) }
                lineProbe = location - 1
            }
        } else if location > 0 {
            let previous = source.character(at: location - 1)
            if previous != 10, previous != 13 { lineProbe = location - 1 }
        }
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentEnd,
            for: NSRange(location: min(lineProbe, source.length), length: 0)
        )
        if contentEnd > lineStart {
            if let visible = vimLastVisibleCharacter(
                before: contentEnd,
                lineStart: lineStart,
                source: source
            ) {
                return rect(forSelection: visible)
            }
        }
        return caretRect(at: location)
    }

    private func vimLastVisibleCharacter(
        before end: Int,
        lineStart: Int,
        source: NSString
    ) -> NSRange? {
        var location = end
        while location > lineStart {
            let range = source.rangeOfComposedCharacterSequence(at: location - 1)
            if !vimCharacterIsCollapsed(at: range.location) { return range }
            location = range.location
        }
        return nil
    }

    private func vimCharacterIsCollapsed(at location: Int) -> Bool {
        guard let storage = textStorage, location >= 0, location < storage.length,
              let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        else { return false }
        return font.pointSize <= 0.1
    }

    private var vimCursorCellWidth: CGFloat {
        max(4, ("M" as NSString).size(withAttributes: [.font: Theme.liveFont]).width)
    }

    private func caretRect(at location: Int) -> NSRect? {
        let source = string as NSString
        if let lineFrame = vimTextLineFrame(at: location) {
            return NSRect(
                x: vimLineLeadingX(at: location),
                y: lineFrame.minY,
                width: vimCursorCellWidth,
                height: max(lineFrame.height, Theme.liveFont.boundingRectForFont.height)
            )
        }
        if source.length > 0 {
            let adjacent = max(0, min(location - 1, source.length - 1))
            if var frame = rect(forSelection: NSRange(location: adjacent, length: 1)) {
                if source.character(at: adjacent) == 10 || source.character(at: adjacent) == 13 {
                    // TextKit's selection segment for a newline can span the
                    // entire available line. Its maxX is therefore the
                    // readable-width boundary, not the insertion point of the
                    // following empty paragraph.
                    frame.origin.x = vimLineLeadingX(at: location)
                } else if location > adjacent {
                    frame.origin.x = frame.maxX
                }
                frame.size.width = vimCursorCellWidth
                return frame
            }
        }
        return NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: vimCursorCellWidth,
            height: Theme.liveFont.boundingRectForFont.height
        )
    }

    /// The TextKit 2 line fragment belonging to a source insertion position,
    /// in this view's coordinates. Unlike a newline selection segment, this
    /// describes the empty paragraph itself even beside a tall block widget.
    private func vimTextLineFrame(at sourceLocation: Int) -> NSRect? {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(
                content.documentRange.location,
                offsetBy: min(max(0, sourceLocation), string.utf16.count)
              ),
              let fragment = manager.textLayoutFragment(for: location),
              let line = fragment.textLineFragments.first
        else { return nil }
        var frame = line.typographicBounds
        frame.origin.x += fragment.layoutFragmentFrame.minX + textContainerInset.width
        frame.origin.y += fragment.layoutFragmentFrame.minY + textContainerInset.height
        return frame
    }

    private func vimLineLeadingX(at location: Int) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else {
            return textContainerInset.width
        }
        let attributeLocation = min(max(0, location), storage.length - 1)
        let style = storage.attribute(
            .paragraphStyle,
            at: attributeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        return textContainerInset.width + max(
            style?.firstLineHeadIndent ?? 0,
            style?.headIndent ?? 0
        )
    }

    private func vimKey(for event: NSEvent) -> VimKey? {
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 117: return .delete
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 48: return .tab
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        if event.modifierFlags.contains(.control), let character = characters.lowercased().first {
            return .control(character)
        }
        return .character(characters)
    }

    private func isVimVerticalMovement(_ key: VimKey) -> Bool {
        switch key {
        case .up, .down, .character("j"), .character("k"): true
        default: false
        }
    }

    private func vimCursorRect(at location: Int) -> NSRect? {
        let source = string as NSString
        guard source.length > 0 else { return caretRect(at: 0) }
        let character = min(location, source.length - 1)
        return rect(forSelection: NSRange(location: character, length: 1))
    }

    private func vimLocation(onLineContaining location: Int, renderedX: CGFloat) -> Int {
        let source = string as NSString
        guard source.length > 0 else { return 0 }
        let safeLocation = min(location, source.length - 1)
        let line = source.lineRange(for: NSRange(location: safeLocation, length: 0))
        guard let row = rect(forSelection: NSRange(location: safeLocation, length: 1)) else {
            return safeLocation
        }
        let insertion = characterIndexForInsertion(at: NSPoint(x: renderedX, y: row.midY))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location {
            let character = source.character(at: contentEnd - 1)
            guard character == 10 || character == 13 else { break }
            contentEnd -= 1
        }
        guard contentEnd > line.location else { return line.location }
        return min(max(insertion, line.location), contentEnd - 1)
    }

    private func performVimHostAction(_ action: VimHostAction) {
        switch action {
        case .undo: undoManager?.undo()
        case .redo: undoManager?.redo()
        case .scrollCenter: centerSelectionInVisibleArea(nil)
        case .scrollTop, .scrollBottom:
            guard let scrollView = enclosingScrollView,
                  let selectionRect = rect(forSelection: selectedRange())
            else {
                scrollRangeToVisible(selectedRange())
                return
            }
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.y = action == .scrollTop
                ? selectionRect.minY - textContainerInset.height
                : selectionRect.maxY - clip.bounds.height + textContainerInset.height
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        case .pageUp: pageUp(nil)
        case .pageDown: pageDown(nil)
        case .beginSearch, .nextSearch, .searchWord: onVimSearch?(action)
        case let .replayKeys(keys): replayVimKeys(keys)
        case let .moveToViewportLine(line): moveVimCaretToViewportLine(line)
        }
    }

    /// Macro playback. Each key has to see the document the one before it
    /// produced, so it goes back through the same path a typed key takes —
    /// and the dot-repeat recorder is muted, since `@a` is not itself the
    /// change that `.` should repeat.
    private func replayVimKeys(_ keys: [VimKey]) {
        guard !vimIsReplaying else { return }
        vimIsReplaying = true
        defer {
            vimIsReplaying = false
            updateVimCursor()
        }
        for key in keys {
            if vimEngine.mode == .insert, case let .character(value) = key {
                insertText(value, replacementRange: selectedRange())
                continue
            }
            _ = handleVimKey(key, recordRepeat: false)
        }
        if vimEngine.mode != .normal { _ = handleVimKey(.escape, recordRepeat: false) }
    }

    /// `H`, `M` and `L`: only the view knows which lines are on screen, so the
    /// engine asks rather than guesses.
    private func moveVimCaretToViewportLine(_ line: ViewportLine) {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.contentView.bounds
        let source = string as NSString
        var lineStarts: [Int] = []
        var location = 0
        while location <= source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            if let frame = vimTextLineFrame(at: range.location),
               frame.maxY > visible.minY, frame.minY < visible.maxY {
                lineStarts.append(range.location)
            }
            guard NSMaxRange(range) > location else { break }
            location = NSMaxRange(range)
        }
        guard !lineStarts.isEmpty else { return }
        let index: Int
        switch line {
        case let .top(count): index = min(max(0, count - 1), lineStarts.count - 1)
        case .middle: index = lineStarts.count / 2
        case let .bottom(count): index = max(0, lineStarts.count - max(1, count))
        }
        let target = lineStarts[index]
        var caret = target
        let content = source.lineRange(for: NSRange(location: target, length: 0))
        while caret < NSMaxRange(content) {
            let character = source.character(at: caret)
            if character != 32, character != 9, character != 10, character != 13 { break }
            caret += 1
        }
        setSelectedRange(NSRange(location: min(caret, source.length), length: 0))
        updateVimCursor()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFirstResponderChange?(true)
            DispatchQueue.main.async { [weak self] in self?.updateVimCursor() }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            dismissLinkCompletion()
            onFirstResponderChange?(false)
            updateVimCursor()
        }
        return accepted
    }

    /// Switching between light and dark changes colours that were flattened
    /// into images during the last restyle, so those have to be re-typeset.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.onNeedsRestyle?()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontalInset = max(28, (newSize.width - Theme.contentMaxWidth) / 2)
        if abs(textContainerInset.width - horizontalInset) > 0.5 {
            textContainerInset = NSSize(width: horizontalInset, height: 28)
        }
        guard abs(newSize.width - lastWidth) > 1 else { return }
        lastWidth = newSize.width
        // Restyling invalidates layout, which is not safe to do from inside a
        // layout pass; the guard above keeps this from repeating.
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            self?.onNeedsRestyle?()
        }
    }

    override func layout() {
        super.layout()
        updateVimCursor()
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

    override func resetCursorRects() {
        super.resetCursorRects()

        let text = string as NSString
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let source = text.substring(with: line)
            if let marker = Self.listMarker(of: source),
               marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil {
                let leading = marker.prefix { $0 == " " || $0 == "\t" }
                let depth = Self.listDepth(of: leading)
                let markerLength = marker.utf16.count
                if let lineRect = rect(forSelection: NSRange(
                    location: line.location,
                    length: min(max(1, markerLength), line.length)
                )) {
                    let horizontal = taskHitRange(for: marker, depth: depth)
                    addCursorRect(CGRect(
                        x: horizontal.lowerBound,
                        y: lineRect.minY,
                        width: horizontal.upperBound - horizontal.lowerBound,
                        height: max(lineRect.height, Theme.liveFont.boundingRectForFont.height)
                    ), cursor: .pointingHand)
                }
            }

            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
    }

    override func mouseDown(with event: NSEvent) {
        vimPreferredX = nil
        dismissLinkCompletion()
        if event.clickCount == 1, toggleTask(at: convert(event.locationInWindow, from: nil)) {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let usesVimSelection = vimEnabled
            && vimEngine.mode != .insert
            && vimEngine.mode != .replace
            && vimEngine.mode != .blockInsert
        let emptyLineLocation = usesVimSelection ? vimEmptyLineLocation(at: point) : nil
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        if usesVimSelection {
            if let emptyLineLocation {
                // AppKit double-clicks select the newline character as a word.
                // Vim represents an empty line as a Normal-mode cursor at that
                // newline, for both single and repeated clicks.
                setSelectedRange(NSRange(location: emptyLineLocation, length: 0))
            } else if event.clickCount == 2 {
                normalizeVimDoubleClickSelection(at: point)
            }
            if selectedRange().length > 0 {
                vimEngine.adoptVisualSelection(selectedRange(), in: string)
                VimSettings.shared.report(mode: .visual)
            } else {
                vimEngine.reset(mode: .normal)
                VimSettings.shared.report(mode: .normal)
            }
            updateVimCursor()
        }
        onTrackingEnded?()
    }

    /// Returns the source insertion position for an actually empty logical
    /// line under `point`. It is intentionally resolved before `super` handles
    /// a double click, because AppKit turns the line's newline into a one-byte
    /// word selection and loses the distinction afterwards.
    func vimEmptyLineLocation(at point: NSPoint) -> Int? {
        let source = string as NSString
        if source.length == 0 { return 0 }

        // Do not seed this from `characterIndexForInsertion(at:)`. Hidden
        // Markdown and custom block fragments can make TextKit attribute the
        // visible area of an empty paragraph to a source position several
        // lines away (notably around thematic breaks). The laid-out rectangles
        // are authoritative, and this work happens only on a mouse-down.
        var location = 0
        while location <= source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            if Self.lineContentRange(lineRange, in: source).length == 0,
               let frame = vimTextLineFrame(at: location) {
                if point.y >= frame.minY - 1, point.y <= frame.maxY + 1 {
                    return location
                }
                // Logical lines and layout fragments are vertically ordered.
                // Once the scan has passed the click there can be no match.
                if frame.minY > point.y + 1 { return nil }
            }
            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
        }
        return nil
    }

    /// AppKit treats the newline after a line as a selectable word. When a
    /// Normal-mode double click lands in the blank area after rendered text,
    /// match Vim editors by selecting the line's final token instead.
    func normalizeVimDoubleClickSelection(at point: NSPoint) {
        let source = string as NSString
        guard source.length > 0 else { return }
        let insertion = min(characterIndexForInsertion(at: point), source.length)
        var probe = insertion
        if probe == source.length {
            guard probe > 0 else { return }
            probe -= 1
        } else if source.character(at: probe) == 10 || source.character(at: probe) == 13 {
            guard probe > 0 else { return }
            probe -= 1
        }

        let content = source.lineRange(for: NSRange(location: probe, length: 0))
        var contentEnd = NSMaxRange(content)
        while contentEnd > content.location {
            let character = source.character(at: contentEnd - 1)
            guard character == 10 || character == 13 else { break }
            contentEnd -= 1
        }
        guard contentEnd > content.location else { return }
        let finalRange = source.rangeOfComposedCharacterSequence(at: contentEnd - 1)
        guard let finalRect = rect(forSelection: finalRange), point.x >= finalRect.maxX else {
            return
        }

        var end = contentEnd
        while end > content.location {
            let range = source.rangeOfComposedCharacterSequence(at: end - 1)
            let value = source.substring(with: range)
            guard value.rangeOfCharacter(from: .whitespaces) != nil else { break }
            end = range.location
        }
        guard end > content.location else { return }
        let lastTokenRange = source.rangeOfComposedCharacterSequence(at: end - 1)
        guard isVimWordCharacter(source.substring(with: lastTokenRange)) else {
            // CodeMirror/Obsidian treats trailing punctuation as the closest
            // token. In `breakfast)`, double-clicking past the line selects
            // only `)`, not the preceding word.
            setSelectedRange(lastTokenRange)
            return
        }
        var start = end
        while start > content.location {
            let range = source.rangeOfComposedCharacterSequence(at: start - 1)
            guard isVimWordCharacter(source.substring(with: range)) else { break }
            start = range.location
        }
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    private func isVimWordCharacter(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
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

        guard let fullMarker = Self.listMarker(of: source) else { return false }
        let leading = fullMarker.prefix { $0 == " " || $0 == "\t" }
        let depth = Self.listDepth(of: leading)
        guard taskHitRange(for: fullMarker, depth: depth).contains(point.x) else { return false }

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

    private static func listDepth<S: StringProtocol>(of leading: S) -> Int {
        leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
            + leading.filter { $0 == " " }.count / 2
    }

    /// Horizontal click/hover target around the exact checkbox position used
    /// by the layout fragment. The padding makes the 13pt box forgiving while
    /// keeping the surrounding text under the normal I-beam cursor.
    private func taskHitRange(for marker: String, depth: Int) -> ClosedRange<CGFloat> {
        let leading = marker.prefix { $0 == " " || $0 == "\t" }
        let visible = String(marker.dropFirst(leading.utf16.count))
        let centre = textContainerInset.width
            + LiveStyler.listIndent(depth: depth)
            + LiveStyler.listGlyphOffset(
                marker: visible, kind: .task(checked: false), font: Theme.liveFont
            )
        return (centre - 10)...(centre + 10)
    }

    override func paste(_ sender: Any?) {
        if let markdown = onAttachment?(NSPasteboard.general) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }

    /// Auto-pairs the second `[` so the caret remains inside `[[]]`, matching
    /// the completion flow in Obsidian. Existing closers are never duplicated.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        let selection = selectedRange()
        if inserted == "[", selection.length == 0, selection.location > 0 {
            let source = string as NSString
            let previous = source.substring(with: NSRange(location: selection.location - 1, length: 1))
            let remaining = NSRange(
                location: selection.location,
                length: min(2, source.length - selection.location)
            )
            let alreadyClosed = remaining.length == 2 && source.substring(with: remaining) == "]]"
            if previous == "[", !alreadyClosed {
                completionIsActive = true
                super.insertText("[]]", replacementRange: replacementRange)
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                updateLinkCompletion(allowStart: true)
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
        applySubstitution(after: inserted)
    }

    /// The substitution the caret is sitting just after, and what it replaced.
    ///
    /// Cleared by `didChangeText`, so every other edit in this class drops it
    /// without having to remember to, and by a selection change, so it only
    /// ever survives for as long as the caret stays put.
    private var pendingSubstitution: TextSubstitution?

    /// The open note's title, for `{{title}}` in a custom replacement.
    var noteTitle: String = ""

    func forgetSubstitution() { pendingSubstitution = nil }

    override func didChangeText() {
        pendingSubstitution = nil
        super.didChangeText()
    }

    /// Runs the smart-typography rules over the text now in front of the
    /// caret, replacing it when one matches.
    ///
    /// Only for text the user typed: a single character, into a collapsed
    /// selection. Paste, drag, and completion all arrive through this same
    /// method and must not be rewritten — a pasted `-->` is quoted material.
    private func applySubstitution(after inserted: String?) {
        guard let inserted, inserted.count == 1, !completionIsActive else { return }
        applySubstitution()
    }

    /// - Parameter endingWord: Return was pressed, which ends a word without
    ///   typing anything, so only "after a space" rules can still fire.
    @discardableResult
    private func applySubstitution(endingWord: Bool = false) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        guard let substitution = SmartTypography.substitution(
            in: string, caret: selection.location, config: TypingSettings.shared.config,
            expansion: SubstitutionExpansion(noteTitle: noteTitle), endingWord: endingWord
        ) else { return false }

        guard shouldChangeText(in: substitution.range, replacementString: substitution.replacement)
        else { return false }
        textStorage?.replaceCharacters(in: substitution.range, with: substitution.replacement)
        didChangeText()
        setSelectedRange(NSRange(location: substitution.caret, length: 0))
        // After both, since each of them clears it.
        pendingSubstitution = substitution
        return true
    }

    /// Backspace immediately after a substitution puts back what was typed,
    /// rather than deleting the character the substitution produced. It is the
    /// escape hatch for the one time in a hundred that `->` really did mean
    /// `->`, and it is what Obsidian's Smart Typography does.
    override func deleteBackward(_ sender: Any?) {
        guard let substitution = pendingSubstitution else {
            super.deleteBackward(sender)
            return
        }
        pendingSubstitution = nil

        let text = string as NSString
        let replaced = substitution.replacedRange
        let selection = selectedRange()
        guard selection.length == 0, selection.location == substitution.caret,
              NSMaxRange(replaced) <= text.length,
              text.substring(with: replaced) == substitution.replacement,
              shouldChangeText(in: replaced, replacementString: substitution.original)
        else {
            super.deleteBackward(sender)
            return
        }
        textStorage?.replaceCharacters(in: replaced, with: substitution.original)
        didChangeText()
        setSelectedRange(NSRange(
            location: replaced.location + (substitution.original as NSString).length, length: 0
        ))
    }

    override func moveUp(_ sender: Any?) {
        guard moveLinkCompletion(-1) else { super.moveUp(sender); return }
    }

    override func moveDown(_ sender: Any?) {
        guard moveLinkCompletion(1) else { super.moveDown(sender); return }
    }

    override func cancelOperation(_ sender: Any?) {
        guard completionIsActive else { super.cancelOperation(sender); return }
        dismissLinkCompletion()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let markdown = onAttachment?(sender.draggingPasteboard) {
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }

    /// The formatting bar, added lazily so a document that is never selected
    /// into never builds one.
    private(set) var formatBar: FormatBar?

    /// Shows or hides the formatting bar for the current selection.
    func updateFormatBar() {
        let selection = selectedRange()
        let vimVisual = vimEnabled && (
            vimEngine.mode == .visual
                || vimEngine.mode == .visualLine
                || vimEngine.mode == .visualBlock
                || vimEngine.mode == .blockInsert
        )
        guard selection.length > 0, !vimVisual, window?.firstResponder === self else {
            formatBar?.isHidden = true
            return
        }

        let bar: FormatBar
        if let existing = formatBar {
            bar = existing
        } else {
            bar = FormatBar()
            bar.onFormat = { [weak self] format in self?.applyFormat(format) }
            addSubview(bar)
            formatBar = bar
        }
        bar.update(
            for: rect(forSelection: selection),
            in: self,
            allowsSingleLineOnlyFormats: !MarkdownEditing.spansMultipleLines(
                in: string, range: selection
            )
        )
    }

    /// Bounding box of a selection in view coordinates.
    private func rect(forSelection range: NSRange) -> CGRect? {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }

        var union: CGRect?
        manager.enumerateTextSegments(
            in: textRange, type: .selection, options: []
        ) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        guard var rect = union else { return nil }
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    // Selector targets for the Format menu. They exist as distinct methods
    // because a menu item sends one selector and carries no payload.
    @objc func formatBold() { applyFormat(.bold) }
    @objc func formatItalic() { applyFormat(.italic) }
    @objc func formatStrikethrough() { applyFormat(.strikethrough) }
    @objc func formatHighlight() { applyFormat(.highlight) }
    @objc func formatCode() { applyFormat(.code) }
    @objc func formatLink() { applyFormat(nil) }

    func applyFormat(_ format: InlineFormat?) {
        let selection = selectedRange()
        let edit = format.map { MarkdownEditing.toggle($0, in: string, range: selection) }
            ?? MarkdownEditing.makeLink(in: string, range: selection)
        guard !edit.isEmpty else { return }

        // Only the affected span is replaced, so the rest of the document keeps
        // its layout and the undo stack gets one small step rather than the
        // whole file.
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        updateFormatBar()
    }

    /// Continues a list or a block quote on Enter, and ends it when the line is
    /// left empty — the behaviour every editor has and the block version never
    /// got right.
    override func insertNewline(_ sender: Any?) {
        if acceptLinkCompletion() { return }
        // Return ends a word, so an "after a space" replacement gets its turn
        // before the line does — and the newline still happens, exactly as it
        // does in macOS text replacement.
        applySubstitution(endingWord: true)
        let text = string as NSString
        let caret = selectedRange()
        let line = text.substring(with: text.lineRange(for: NSRange(location: caret.location, length: 0)))
            .trimmingCharacters(in: .newlines)

        guard let structure = Self.markdownContinuation(of: line) else {
            super.insertNewline(sender)
            return
        }
        let marker = structure.marker

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
        let continuation = structure.isList ? Self.nextListMarker(after: marker) : marker
        insertText(continuation, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if acceptLinkCompletion() { return }
        guard adjustListIndent(outdent: false) else {
            super.insertTab(sender)
            return
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard adjustListIndent(outdent: true) else {
            super.insertBacktab(sender)
            return
        }
    }

    func updateLinkCompletion(allowStart: Bool) {
        guard let context = WikiCompletionContext.detect(
            in: string, selection: selectedRange()
        ) else {
            dismissLinkCompletion()
            return
        }
        if !completionIsActive {
            guard allowStart, context.query.isEmpty else { return }
            completionIsActive = true
        }
        if completionQuery != context.query {
            completionQuery = context.query
            completionSelection = 0
        }

        let refs = completionIndex.linkSuggestions(
            matching: context.query, forEmbed: context.isEmbed
        )
        completionItems = refs.map {
            WikiCompletionItem(ref: $0, destination: completionIndex.linkDestination(for: $0))
        }
        completionSelection = min(completionSelection, max(0, completionItems.count - 1))
        guard !completionItems.isEmpty, let anchor = completionAnchor() else {
            completionPanel?.dismiss()
            return
        }

        let panel: WikiCompletionPanel
        if let existing = completionPanel {
            panel = existing
        } else {
            panel = WikiCompletionPanel()
            panel.onPick = { [weak self] index in self?.acceptLinkCompletion(at: index) }
            addSubview(panel)
            completionPanel = panel
        }
        panel.show(
            items: completionItems, selected: completionSelection,
            below: anchor, in: self
        )
    }

    private func moveLinkCompletion(_ delta: Int) -> Bool {
        guard completionIsActive, !completionItems.isEmpty else { return false }
        completionSelection = min(max(completionSelection + delta, 0), completionItems.count - 1)
        updateLinkCompletion(allowStart: false)
        return true
    }

    @discardableResult
    private func acceptLinkCompletion() -> Bool {
        acceptLinkCompletion(at: completionSelection)
    }

    @discardableResult
    private func acceptLinkCompletion(at index: Int) -> Bool {
        guard completionIsActive, completionItems.indices.contains(index),
              let context = WikiCompletionContext.detect(in: string, selection: selectedRange())
        else { return false }
        let edit = context.accepting(completionItems[index].destination)
        completionIsActive = false
        completionPanel?.dismiss()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        return true
    }

    private func dismissLinkCompletion() {
        completionIsActive = false
        completionItems = []
        completionSelection = 0
        completionQuery = ""
        completionPanel?.dismiss()
    }

    private func completionAnchor() -> NSRect? {
        let caret = selectedRange().location
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        // A zero-length range does not reliably produce a TextKit 2 selection
        // segment, and `firstRect(forCharacterRange:)` may return an empty
        // screen rect while SwiftUI is updating the window. Anchor to the glyph
        // immediately before the caret instead, then use its trailing edge as
        // the insertion point.
        let character = NSRange(location: max(0, min(caret - 1, length - 1)), length: 1)
        guard var anchor = rect(forSelection: character) else { return nil }
        anchor.origin.x = anchor.maxX
        anchor.size.width = 1
        return anchor
    }

    /// Adds or removes one CommonMark nesting level on the current list item,
    /// regardless of where the caret sits in that line.
    private func adjustListIndent(outdent: Bool) -> Bool {
        let source = string as NSString
        let selection = selectedRange()
        let location = min(selection.location, source.length)
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        let value = source.substring(with: line)
        guard value.range(
            of: #"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#,
            options: .regularExpression
        ) != nil else { return false }

        let leading = value.prefix { $0 == " " || $0 == "\t" }
        let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
            + leading.filter { $0 == " " }.count / 2
        let newDepth = outdent ? max(0, depth - 1) : depth + 1
        guard newDepth != depth else { return true }

        // Tabs are Heft's canonical list indentation. Replacing the complete
        // prefix also normalizes older space-indented and mixed-whitespace
        // items whenever the user explicitly changes their depth.
        let editRange = NSRange(location: line.location, length: leading.utf16.count)
        let replacement = String(repeating: "\t", count: newDepth)

        guard shouldChangeText(in: editRange, replacementString: replacement) else { return true }
        textStorage?.replaceCharacters(in: editRange, with: replacement)
        didChangeText()

        let delta = replacement.utf16.count - editRange.length
        setSelectedRange(NSRange(
            location: max(line.location, selection.location + delta),
            length: selection.length
        ))
        return true
    }

    /// `> `, `> > ` … with indentation, or nil when the line is not quoted.
    ///
    /// A callout's `[!kind]` header is deliberately not carried down: the next
    /// line continues the callout's body, and repeating the marker would
    /// declare a second callout inside the first.
    static func quoteMarker(of line: String) -> String? {
        guard let match = line.range(
            of: #"^[ \t]*(?:>[ \t]?)+"#, options: .regularExpression
        ) else { return nil }
        return String(line[match])
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

    /// The structural prefix Heft carries to a following Markdown line.
    /// Recognizes lists nested inside blockquotes in addition to standalone
    /// lists and quotes, so Return and Vim's optional o/O behavior agree.
    static func markdownContinuation(of line: String) -> (marker: String, isList: Bool)? {
        if let marker = listMarker(of: line) { return (marker, true) }
        guard let quote = quoteMarker(of: line) else { return nil }
        let remainder = String(line.dropFirst(quote.count))
        if let list = listMarker(of: remainder) { return (quote + list, true) }
        return (quote, false)
    }

    /// Marker for the following list item. Bullets and tasks repeat, while an
    /// ordered marker advances and retains its indentation, delimiter and
    /// whitespace (`9. ` becomes `10. ` and `9) ` becomes `10) `).
    static func nextListMarker(after marker: String) -> String {
        guard let number = marker.range(
            of: #"\d+(?=[.)][ \t]+$)"#, options: .regularExpression
        ), let value = Int(marker[number]), value < Int.max else { return marker }
        var result = marker
        result.replaceSubrange(number, with: String(value + 1))
        return result
    }
}
