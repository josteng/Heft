import HeftCore
import SwiftUI
import UIKit

/// The live surface on iOS: the Mac's styling and widget drawing, in a
/// `UITextView` on the same TextKit 2 stack.
///
/// Everything below the view is shared: `LiveDecorator` and `RestyleScope`
/// from HeftCore, `LiveStyler` and `HeftLayoutFragment` from HeftTextKit.
/// What lives here is what touch needs instead of a mouse and a menu bar:
/// reading with every mark hidden until the text is tapped into, a keyboard
/// bar, checkboxes and links that answer a tap, and saving as it goes.
struct LiveNoteEditor: UIViewRepresentable {
    let document: NoteDocument
    let context: RenderContext
    /// Whether the reader has scrolled down from the top, for the calendar
    /// that folds away above a daily note.
    var scrolledDown: ((Bool) -> Void)?
    /// A link tapped while reading.
    var follow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MobileTextView {
        let view = MobileTextView(usingTextLayoutManager: true)
        let coordinator = context.coordinator
        coordinator.textView = view
        view.delegate = coordinator
        view.textLayoutManager?.delegate = coordinator
        view.backgroundColor = .clear
        view.font = Theme.liveFont
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        // Markdown is typed literally: curled quotes and joined dashes would
        // change what the file says.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inputAccessoryView = coordinator.keyboardBar()
        view.isFindInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        coordinator.update(from: self)
        return view
    }

    func updateUIView(_ view: MobileTextView, context: Context) {
        context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate,
        UIGestureRecognizerDelegate
    {
        weak var textView: MobileTextView?
        private var document: NoteDocument?
        private var renderContext: RenderContext?
        private var scrolledDown: ((Bool) -> Void)?
        private var follow: ((URL) -> Void)?

        private var layout = LiveLayout()
        private var styled: RestyleScope.Snapshot?
        private var styleKey = ""
        /// The text revision this view last took from the document, so a
        /// rescan that re-read the same text does not reset the caret.
        private var loadedRevision = -1
        private var focusRequest = 0
        private var wasScrolledDown = false
        /// Until when a fold just reported is still animating; the view is
        /// changing size under the scroll position meanwhile.
        private var settlingUntil = Date.distantPast
        /// How far the text has moved since the widgets were computed: an
        /// edit lands before the restyle that follows it, and a fragment laid
        /// out in between looks its widget up by an offset that has moved.
        private var pendingShift: (fromOldOffset: Int, delta: Int)?
        /// Whether the text view had the keyboard when a tap began, so a
        /// checkbox tapped while reading does not leave the keyboard up.
        private var hadFocusAtTap = false

        func update(from editor: LiveNoteEditor) {
            document = editor.document
            editor.document.textView = textView
            scrolledDown = editor.scrolledDown
            follow = editor.follow
            let contextChanged = renderContext.map { !Self.sameSurface($0, editor.context) } ?? true
            renderContext = editor.context
            guard let textView else { return }
            if loadedRevision != editor.document.revision {
                load(editor.document.source ?? "", into: textView)
                loadedRevision = editor.document.revision
            } else if contextChanged {
                restyle(textView)
            }
            if focusRequest != editor.document.focusRequest {
                focusRequest = editor.document.focusRequest
                textView.becomeFirstResponder()
            }
            if !editor.document.editing, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            #if DEBUG
            applyLaunchRequest(to: textView)
            #endif
        }

        #if DEBUG
        private var launchRequestApplied = false

        /// Screenshot hooks for a simulator run, where nothing can tap:
        /// `HEFT_IOS_CARET` puts the keyboard in at an offset, and
        /// `HEFT_IOS_TYPE` then types through the real input path, `⏎` for
        /// Return.
        private func applyLaunchRequest(to textView: MobileTextView) {
            let environment = ProcessInfo.processInfo.environment
            guard !launchRequestApplied, let caret = environment["HEFT_IOS_CARET"].flatMap(Int.init),
                  !textView.text.isEmpty
            else { return }
            launchRequestApplied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                textView.becomeFirstResponder()
                let length = environment["HEFT_IOS_SELECT"].flatMap(Int.init) ?? 0
                textView.selectedRange = NSRange(location: min(caret, (textView.text as NSString).length),
                                                 length: length)
                // As the keyboard does: the delegate is asked first, which is
                // where Return continues a list.
                for character in environment["HEFT_IOS_TYPE"] ?? "" {
                    let typed = character == "⏎" ? "\n" : String(character)
                    if self.textView(textView, shouldChangeTextIn: textView.selectedRange,
                                     replacementText: typed) {
                        textView.insertText(typed)
                    }
                }
                for action in (environment["HEFT_IOS_ACTIONS"] ?? "").split(separator: ",") {
                    switch action {
                    case "bullets": self.bullets()
                    case "checklist": self.checklist()
                    case "indent": self.indent()
                    case "outdent": self.outdent()
                    case "format": self.toggleFormatPanel()
                    case "h2": self.heading2()
                    case "quote": self.quote()
                    case "numbered": self.numbered()
                    case "hl": self.restyle(textView); self.highlight()
                    case "accept": self.updateSuggestions(); self.accept(0)
                    case "find": self.document?.find()
                    case "undo": self.document?.undo()
                    case let name where name.hasPrefix("color:"):
                        self.restyle(textView)
                        self.choose(HighlightColor.allCases.first { $0.rawValue.isEmpty == false && $0.title.lowercased() == name.dropFirst(6) })
                    case "callout": self.startCallout()
                    case "tag": self.startTag()
                    default: break
                    }
                }
            }
        }
        #endif

        private static func sameSurface(_ a: RenderContext, _ b: RenderContext) -> Bool {
            a.index.allFiles.count == b.index.allFiles.count
                && a.current?.relativePath == b.current?.relativePath
                && a.strictLineBreaks == b.strictLineBreaks
        }

        /// Replaces the text, keeping the caret where it was when it still fits.
        private func load(_ text: String, into textView: MobileTextView) {
            let selection = textView.selectedRange
            layout = LiveLayout()
            styled = nil
            pendingShift = nil
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            restyle(textView)
        }

        // MARK: Styling

        /// The Mac editor's pass, without what touch has no use for: reveal
        /// what the caret is in, reuse the last parse where the edit could
        /// not have changed it, and rewrite only the lines that differ.
        func restyle(_ textView: MobileTextView) {
            guard let renderContext else { return }
            // An input method's composition is abandoned if its attributes
            // are rewritten; the commit arrives as an edit and restyles then.
            if textView.markedTextRange != nil { return }
            let storage = textView.textStorage
            let source = textView.text as NSString
            let selection = textView.selectedRange
            // Reading shows every mark hidden; only the line being written
            // into shows its source.
            let reveal = textView.isFirstResponder ? Reveal(selection: selection, in: source) : .none

            var context = renderContext
            context.appearance = textView.traitCollection
            let width = textView.textContainer.size.width
            let key = "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")/"
                + "\(context.strictLineBreaks)/\(width)/\(textView.traitCollection.userInterfaceStyle.rawValue)"

            if let styled, styleKey == key, styled.reveal == reveal,
               styled.source.isEqual(to: source as String) {
                updateTypingAttributes(in: textView)
                return
            }
            let decorations: [MarkdownDecoration]
            if let styled, styled.source.isEqual(to: source as String) {
                decorations = styled.decorations
            } else {
                decorations = LiveDecorator.decorations(
                    in: source,
                    reusing: styled.map {
                        LiveDecorator.DecorationCache(source: $0.source, decorations: $0.decorations)
                    }
                )
            }
            spellExclusions = SpellCheckScope.exclusions(for: decorations, in: source)
            let snapshot = RestyleScope.Snapshot(source: source, decorations: decorations, reveal: reveal)
            let comparable = styleKey == key ? styled : nil
            let scope = comparable.map { RestyleScope.scope(from: $0, to: snapshot) }
            styleKey = key
            styled = snapshot
            if let scope, scope.isEmpty {
                pendingShift = nil
                updateTypingAttributes(in: textView)
                return
            }

            let previous = layout.signature
            layout = LiveStyler.apply(
                to: storage,
                reveal: reveal,
                context: context,
                contentWidth: max(200, width - 8),
                decorations: decorations,
                incremental: scope.map {
                    LiveStyler.Incremental(dirty: $0.dirty, edit: $0.edit, previous: layout)
                }
            )
            pendingShift = nil
            if let scope {
                for range in scope.dirty { invalidate(range, in: textView) }
            } else if layout.signature != previous || styled == nil,
                      let manager = textView.textLayoutManager,
                      let content = manager.textContentManager {
                manager.invalidateLayout(for: content.documentRange)
            }
            updateTypingAttributes(in: textView)
            refreshFormatState()
        }

        private func invalidate(_ range: NSRange, in textView: MobileTextView) {
            guard range.location != NSNotFound, range.length > 0,
                  let manager = textView.textLayoutManager,
                  let content = manager.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }
            manager.invalidateLayout(for: textRange)
        }

        /// A blank line takes plain body text, as on the Mac; anywhere else
        /// the next pass styles what was typed.
        private func updateTypingAttributes(in textView: MobileTextView) {
            let selection = textView.selectedRange
            guard selection.length == 0 else { return }
            let source = textView.text as NSString
            let line = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0))
            guard source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            textView.typingAttributes = [
                .font: Theme.liveFont,
                .foregroundColor: UIColor.label,
                .paragraphStyle: LiveStyler.bodyParagraphStyle(compactEmptyLine: true),
            ]
        }

        private func layoutKey(for start: Int) -> Int {
            guard let shift = pendingShift, shift.delta != 0 else { return start }
            return start >= shift.fromOldOffset + shift.delta ? start - shift.delta : start
        }

        nonisolated func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            MainActor.assumeIsolated {
                let fragment = HeftLayoutFragment(textElement: textElement, range: textElement.elementRange)
                guard let content = textLayoutManager.textContentManager else { return fragment }
                let start = content.offset(from: content.documentRange.location, to: location)
                fragment.elementStart = start
                let key = layoutKey(for: start)
                fragment.widget = layout.blocks[key]
                fragment.inlineMath = layout.inlineMath[key] ?? []
                fragment.inlineTags = layout.inlineTags[key] ?? []
                return fragment
            }
        }

        // MARK: Editing

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n", range.length == 0, let view = textView as? MobileTextView,
               continueStructure(at: range.location, in: view) {
                return false
            }
            let delta = (text as NSString).length - range.length
            pendingShift = (NSMaxRange(range), delta)
            return true
        }

        /// Return in a list or a quote: the next line gets the marker, an
        /// empty item steps out a level, and an empty outermost item ends
        /// the list. The rules are `ListContinuation`'s, the Mac's own.
        private func continueStructure(at location: Int, in textView: MobileTextView) -> Bool {
            let text = textView.text as NSString
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            guard let structure = ListContinuation.markdownContinuation(of: line) else { return false }
            let marker = structure.marker
            let lineEnd = lineRange.location + (line as NSString).length
            if line.count <= marker.count {
                if structure.isList, ListContinuation.listDepth(of: line) > 0 {
                    let unit = line.hasPrefix("\t") ? 1 : min(2, line.prefix { $0 == " " }.count)
                    replace(NSRange(location: lineRange.location, length: unit), with: "", in: textView)
                    // The replacement leaves the caret where the indent was;
                    // it belongs after the marker, where it stood.
                    textView.selectedRange = NSRange(location: location - unit, length: 0)
                } else {
                    replace(NSRange(location: lineRange.location, length: lineEnd - lineRange.location),
                            with: "", in: textView)
                    replace(textView.selectedRange, with: "\n", in: textView)
                }
                return true
            }
            let continuation = structure.isList ? ListContinuation.nextListMarker(after: marker) : marker
            replace(NSRange(location: location, length: 0), with: "\n" + continuation, in: textView)
            return true
        }

        /// Through the text view, so undo and the delegate see it as typing.
        private func replace(_ range: NSRange, with text: String, in textView: MobileTextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }
            pendingShift = (NSMaxRange(range), (text as NSString).length - range.length)
            textView.replace(textRange, withText: text)
        }

        func apply(_ edit: MarkdownEditing.Edit) {
            guard let textView, !edit.isEmpty else { return }
            replace(edit.range, with: edit.replacement, in: textView)
            textView.selectedRange = edit.selection
            restyle(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? MobileTextView else { return }
            restyle(view)
            document?.edited(view.text)
            document?.updateUndo()
        }

        /// Selection moves and focus restyle on the next pass, not inside
        /// the callback: rewriting attributes while UIKit is still placing a
        /// tap's caret made it drop the tap, and the first tap into a note
        /// left the caret at the end of the document.
        func textViewDidChangeSelection(_ textView: UITextView) {
            restyleSoon()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            document?.editing = true
            restyleSoon()
        }

        private var restyleQueued = false
        /// Code, URLs, tags, link targets and maths: where the keyboard must
        /// neither correct nor mark words, as on the Mac.
        private var spellExclusions: [NSRange] = []
        private var checkingOff = false

        /// UIKit takes no per-range veto, so the keyboard's checking follows
        /// the caret instead: off inside an excluded span, which is what
        /// stops it "correcting" a URL or a tag being typed, on again
        /// outside. Changed only on the way in or out, since applying it
        /// reloads the keyboard.
        private func updateTextChecking() {
            guard let textView, textView.isFirstResponder else { return }
            let caret = textView.selectedRange.location
            let probe = NSRange(location: max(0, caret - 1), length: caret > 0 ? 1 : 0)
            let inside = probe.length > 0 && SpellCheckScope.excludes(probe, in: spellExclusions)
            guard inside != checkingOff else { return }
            checkingOff = inside
            textView.autocorrectionType = inside ? .no : .default
            textView.spellCheckingType = inside ? .no : .default
            textView.reloadInputViews()
        }

        private func restyleSoon() {
            guard !restyleQueued else { return }
            restyleQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                restyleQueued = false
                if let textView { restyle(textView) }
                refreshFormatState()
                updateBarForSelection()
                updateSuggestions()
                updateTextChecking()
                document?.updateUndo()
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            document?.editing = false
            if let view = textView as? MobileTextView { restyle(view) }
            document?.saveSoon(immediately: true)
        }

        /// Folding the calendar resizes this view, which moves the scroll
        /// position by itself; reacting to that made the two flicker against
        /// each other. So only the reader's own scrolling counts, and the
        /// fold waits out its animation before anything changes again.
        ///
        /// A drag into the note folds, however short the note: a daily note
        /// is usually shorter than the screen, and the rubber band is the
        /// only way into it. Opening again is where the loop was. A short
        /// note springs back to its top after every stretch, and that return
        /// is not the reader asking for the calendar, so it opens only on a
        /// pull past the top. A note long enough to scroll opens on reaching
        /// the top, by finger or by a flick coasting there.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrolledDown != nil, scrollView.isDragging || scrollView.isDecelerating,
                  Date() >= settlingUntil
            else { return }
            let inset = scrollView.adjustedContentInset
            let offset = scrollView.contentOffset.y + inset.top
            let room = scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height
            let pulled = offset < -12 && scrollView.isDragging
            let down: Bool
            if pulled {
                down = false
            } else if !wasScrolledDown {
                down = offset > 40
            } else {
                down = room > 1 ? offset > 0 : true
            }
            // A pull always reports: a note opened under an already folded
            // calendar never saw it fold.
            guard down != wasScrolledDown || pulled else { return }
            wasScrolledDown = down
            settlingUntil = Date().addingTimeInterval(0.45)
            scrolledDown?(down)
        }

        // MARK: Taps

        /// What a tap lands on that the text view itself would not act on: a
        /// task's box in the gutter, or a link while reading.
        private enum Target {
            case checkbox(line: NSRange)
            case link(URL)
        }

        private func target(at point: CGPoint, in textView: MobileTextView) -> Target? {
            guard let manager = textView.textLayoutManager,
                  let content = manager.textContentManager
            else { return nil }
            let inContainer = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            guard let fragment = manager.textLayoutFragment(for: inContainer) else { return nil }
            let text = textView.text as NSString
            let start = content.offset(from: content.documentRange.location,
                                       to: fragment.rangeInElement.location)
            guard start >= 0, start <= text.length else { return nil }
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            let lineText = text.substring(with: line)

            // The box is drawn left of where the item's text starts, so a tap
            // that far left on a task line is a tap on the box.
            if lineText.range(of: #"^[ \t]*(?:>[ \t]?)*[-*+] \[[ xX]\]"#, options: .regularExpression) != nil {
                let depth = ListContinuation.listDepth(of: lineText)
                if inContainer.x <= LiveStyler.listIndent(depth: depth) + 6 {
                    return .checkbox(line: line)
                }
            }
            // A link answers while reading. Once the text has the keyboard, a
            // tap on a link is a tap to place the caret in it, as on the Mac.
            guard !hadFocusAtTap,
                  let position = textView.closestPosition(to: point)
            else { return nil }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            for probe in [offset, offset - 1] where probe >= 0 && probe < text.length {
                if let url = textView.textStorage.attribute(.link, at: probe, effectiveRange: nil) as? URL {
                    return .link(url)
                }
            }
            return nil
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView else { return false }
            hadFocusAtTap = textView.isFirstResponder
            return target(at: touch.location(in: textView), in: textView) != nil
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let textView, recognizer.state == .ended,
                  let target = target(at: recognizer.location(in: textView), in: textView)
            else { return }
            switch target {
            case .checkbox(let line):
                toggleCheckbox(on: line, in: textView)
            case .link(let url):
                follow?(url)
            }
            // The text view takes the same tap as a request for the keyboard;
            // a box ticked or a link followed while reading is not one.
            if !hadFocusAtTap {
                DispatchQueue.main.async { textView.resignFirstResponder() }
            }
        }

        private func toggleCheckbox(on line: NSRange, in textView: MobileTextView) {
            let text = textView.text as NSString
            let lineText = text.substring(with: line) as NSString
            let box = lineText.range(of: #"\[[ xX]\]"#, options: .regularExpression)
            guard box.location != NSNotFound else { return }
            let mark = NSRange(location: line.location + box.location + 1, length: 1)
            let checked = text.substring(with: mark) != " "
            let selection = textView.selectedRange
            replace(mark, with: checked ? " " : "x", in: textView)
            textView.selectedRange = selection
            restyle(textView)
        }

        // MARK: Keyboard bar

        /// The tools on the keyboard, as Notes has them: a glass strip at a
        /// roomy spacing that scrolls sideways, the next tool peeking in at
        /// the edge, with Aa first for everything else.
        ///
        /// Nine icons squeezed into one bar fitted and read as a wall; a
        /// toolbar instead hid the overflow in a nearly empty "…" menu.
        func keyboardBar() -> UIView {
            let gap = UIEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
            let height: CGFloat = 48
            let holder = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: height + gap.top + gap.bottom))
            holder.autoresizingMask = .flexibleWidth
            holder.backgroundColor = .clear

            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.frame = holder.bounds.inset(by: gap)
            glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            glass.cornerConfiguration = .capsule()
            glass.clipsToBounds = true
            holder.addSubview(glass)

            let scroll = UIScrollView(frame: glass.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.showsHorizontalScrollIndicator = false
            scroll.alwaysBounceHorizontal = true
            scroll.contentInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            glass.contentView.addSubview(scroll)

            // The writing tools, then the text tools. Selecting text scrolls
            // the strip to the second half, as Notes does, and a bare caret
            // brings it back; link is in both because it means "link here"
            // at a caret and "link this" over a selection.
            let tools: [(String, String, Selector)] = [
                ("textformat", "Format", #selector(toggleFormatPanel)),
                ("checklist", "Task", #selector(checklist)),
                ("list.bullet", "Bulleted List", #selector(bullets)),
                ("link", "Link to Note", #selector(wikiLink)),
                // A tag rather than indent: `#` is two keyboards deep on a
                // phone, and indent is in Aa beside outdent.
                ("number", "Tag", #selector(startTag)),
                ("text.quote", "Quote", #selector(quote)),
                ("bold", "Bold", #selector(bold)),
                ("italic", "Italic", #selector(italic)),
                ("strikethrough", "Strikethrough", #selector(strikethrough)),
                ("highlighter", "Highlight", #selector(highlightTapped)),
                ("chevron.left.forwardslash.chevron.right", "Code", #selector(code)),
                ("link", "Link Selection", #selector(wikiLink)),
            ]
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            for (index, tool) in tools.enumerated() {
                let button = Self.toolButton(symbol: tool.0, label: tool.1, size: 19)
                button.addTarget(self, action: tool.2, for: .touchUpInside)
                // Five and a bit across a phone, so the sixth shows there is more.
                button.widthAnchor.constraint(equalToConstant: 74).isActive = true
                if index == 0 { formatButton = button }
                if tool.0 == "bold" { textTools = button }
                stack.addArrangedSubview(button)
            }
            scroll.addSubview(stack)
            barScroll = scroll

            // Suggestions for `[[` and `#` take the tools' place in the same
            // glass while there are any.
            let suggestions = UIScrollView(frame: glass.bounds)
            suggestions.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            suggestions.showsHorizontalScrollIndicator = false
            suggestions.alwaysBounceHorizontal = true
            suggestions.contentInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            suggestions.isHidden = true
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            suggestions.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: suggestions.contentLayoutGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: suggestions.contentLayoutGuide.trailingAnchor),
                row.topAnchor.constraint(equalTo: suggestions.contentLayoutGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: suggestions.contentLayoutGuide.bottomAnchor),
                row.heightAnchor.constraint(equalTo: suggestions.frameLayoutGuide.heightAnchor),
            ])
            glass.contentView.addSubview(suggestions)
            suggestionScroll = suggestions
            suggestionRow = row
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            return holder
        }

        private weak var formatButton: UIButton?
        private var formatPanel: FormatPanel?
        private weak var barScroll: UIScrollView?
        private weak var suggestionScroll: UIScrollView?
        private weak var suggestionRow: UIStackView?

        /// A completion offered in the strip: what it shows, and what
        /// accepting it writes for the link or tag being typed.
        private struct Suggestion: Equatable {
            enum Kind { case link, tag, callout, color }
            var title: String
            var detail: String
            var destination: String
            var kind: Kind
            var symbol: String?
            var tint: UIColor?
        }

        /// Which callout kinds were used, so the strip offers the usual ones
        /// first.
        private static let calloutUse = FrecencyStore(key: "dev.stenglein.Heft.iOS.calloutUse")

        private var suggestions: [Suggestion] = []

        /// `[[` offers notes, as the Mac's menu does: by name and by alias,
        /// best first, and the most recently edited before anything is
        /// typed. `#` offers the vault's tags, most used first.
        private func updateSuggestions() {
            guard let textView, let index = renderContext?.index else { return }
            let text = textView.text ?? ""
            let selection = textView.selectedRange
            var found: [Suggestion] = []
            if let wiki = WikiCompletionContext.detect(in: text, selection: selection) {
                let pipe = WikiCompletionContext.pipe(at: wiki.queryRange.location, in: text)
                if wiki.query.isEmpty {
                    found = index.notesByLastEdit.prefix(12).map {
                        Suggestion(title: $0.name, detail: $0.folder,
                                   destination: index.linkDestination(for: $0), kind: .link)
                    }
                } else {
                    found = index.linkMatches(matching: wiki.query, forEmbed: wiki.isEmbed)
                        .prefix(20).map { match in
                            let destination = index.linkDestination(for: match.ref)
                            guard let alias = match.alias else {
                                return Suggestion(title: match.ref.name, detail: match.ref.folder,
                                                  destination: destination, kind: .link)
                            }
                            return Suggestion(title: alias, detail: "\u{2192} \(match.ref.name)",
                                              destination: destination + pipe + alias, kind: .link)
                        }
                }
            } else if let callout = CalloutCompletionContext.detect(in: text, selection: selection) {
                let use = Self.calloutUse
                let ranked = callout.suggestions().enumerated().sorted {
                    let left = use.score($0.element.kind.rawValue), right = use.score($1.element.kind.rawValue)
                    return left != right ? left > right : $0.offset < $1.offset
                }.map(\.element)
                found = ranked.map {
                    Suggestion(title: $0.kind.rawValue.capitalized, detail: $0.matchedAlias ?? "",
                               destination: $0.insertion, kind: .callout, symbol: $0.kind.symbol)
                }
            } else if HighlightCompletionContext.detect(in: text, selection: selection) != nil {
                // The colour the pencil uses first, then the rest in order.
                let current = highlightColor
                let choices: [HighlightColor?] = [current] + ([nil] + HighlightColor.allCases.map(Optional.some))
                    .filter { $0 != current }
                found = choices.map {
                    Suggestion(title: $0?.title ?? "Default", detail: "", destination: $0?.rawValue ?? "",
                               kind: .color, symbol: "circle.fill",
                               tint: Theme.highlightSwatch($0 ?? .yellow))
                }
            } else if let tag = TagCompletionContext.detect(in: text, selection: selection) {
                // The index lists tags most used first.
                found = tag.suggestions(from: index.allTags).prefix(20).map {
                    let count = index.noteCount(forTag: $0)
                    return Suggestion(title: "#\($0)", detail: count == 1 ? "1 note" : "\(count) notes",
                                      destination: $0, kind: .tag)
                }
            }
            guard found != suggestions else { return }
            suggestions = found
            showSuggestions()
        }

        private func showSuggestions() {
            guard let suggestionRow, let suggestionScroll, let barScroll else { return }
            suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (position, suggestion) in suggestions.enumerated() {
                var configuration = UIButton.Configuration.plain()
                configuration.title = suggestion.title
                configuration.subtitle = suggestion.detail.isEmpty ? nil : suggestion.detail
                configuration.titleLineBreakMode = .byTruncatingTail
                configuration.baseForegroundColor = .label
                configuration.titleAlignment = .center
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
                if let symbol = suggestion.symbol {
                    configuration.image = UIImage(systemName: symbol)
                    configuration.imagePadding = 6
                    configuration.preferredSymbolConfigurationForImage =
                        UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                    if let tint = suggestion.tint {
                        configuration.image = configuration.image?.withTintColor(tint, renderingMode: .alwaysOriginal)
                    }
                }
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                    var attributes = $0
                    attributes.font = .preferredFont(forTextStyle: .subheadline)
                    return attributes
                }
                configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                    var attributes = $0
                    attributes.font = .preferredFont(forTextStyle: .caption2)
                    attributes.foregroundColor = .secondaryLabel
                    return attributes
                }
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                    self?.accept(position)
                })
                button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
                suggestionRow.addArrangedSubview(button)
            }
            let showing = !suggestions.isEmpty
            suggestionScroll.isHidden = !showing
            barScroll.isHidden = showing
            suggestionScroll.setContentOffset(CGPoint(x: -suggestionScroll.contentInset.left, y: 0), animated: false)
        }

        private func accept(_ position: Int) {
            guard let textView, suggestions.indices.contains(position) else { return }
            let suggestion = suggestions[position]
            let text = textView.text ?? ""
            let selection = textView.selectedRange
            switch suggestion.kind {
            case .tag:
                guard let context = TagCompletionContext.detect(in: text, selection: selection) else { return }
                apply(context.accepting(suggestion.destination, in: text))
            case .link:
                guard let context = WikiCompletionContext.detect(in: text, selection: selection) else { return }
                apply(context.accepting(suggestion.destination))
            case .callout:
                guard let context = CalloutCompletionContext.detect(in: text, selection: selection) else { return }
                Self.calloutUse.record(suggestion.destination)
                apply(context.accepting(suggestion.destination))
                // Started from Aa: the title is typed next, on the keyboard.
                if textView.inputView != nil { toggleFormatPanel() }
            case .color:
                guard let context = HighlightCompletionContext.detect(in: text, selection: selection) else { return }
                apply(context.accepting(HighlightColor(rawValue: suggestion.destination)))
            }
            updateSuggestions()
        }
        /// The first of the text tools, which a selection scrolls to.
        private weak var textTools: UIButton?
        private var barShowsTextTools = false

        /// Moves the strip only when the selection turns into a range or back
        /// into a caret, so it never fights a thumb scrolling it.
        private func updateBarForSelection() {
            guard let textView, let barScroll, let textTools else { return }
            let wantsText = textView.selectedRange.length > 0
            guard wantsText != barShowsTextTools else { return }
            // A selection made as the keyboard comes up arrives before the
            // strip has a width; measured then, it scrolled nowhere.
            barScroll.layoutIfNeeded()
            guard barScroll.contentSize.width > 0, barScroll.window != nil else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.updateBarForSelection()
                }
                return
            }
            barShowsTextTools = wantsText
            let inset = barScroll.contentInset
            let furthest = max(-inset.left, barScroll.contentSize.width + inset.right - barScroll.bounds.width)
            let x = wantsText ? min(textTools.frame.minX - inset.left, furthest) : -inset.left
            barScroll.setContentOffset(CGPoint(x: x, y: 0), animated: true)
        }

        @objc private func highlightTapped() { highlight() }

        private static func toolButton(symbol: String, label: String, size: CGFloat) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            configuration.baseForegroundColor = .label
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = label
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }

        // MARK: Format panel

        /// Aa: the panel in the keyboard's place, or the keyboard back.
        @objc private func toggleFormatPanel() {
            guard let textView else { return }
            if textView.inputView == nil {
                let panel = FormatPanel()
                panel.highlightColor = highlightColor
                panel.onTool = { [weak self] tool in self?.perform(tool) }
                panel.onClose = { [weak self] in self?.toggleFormatPanel() }
                formatPanel = panel
                textView.inputView = panel
                refreshFormatState()
            } else {
                textView.inputView = nil
                formatPanel = nil
            }
            textView.reloadInputViews()
            var configuration = formatButton?.configuration
            configuration?.baseForegroundColor = textView.inputView == nil ? .label : .tintColor
            formatButton?.configuration = configuration
        }

        private func perform(_ tool: FormatTool) {
            switch tool {
            case .title: setHeading(1)
            case .heading: setHeading(2)
            case .subheading: setHeading(3)
            case .body: setHeading(0)
            case .bold: format(.bold)
            case .italic: format(.italic)
            case .strikethrough: format(.strikethrough)
            case .code: format(.code)
            case .highlight: highlight()
            case .color(let color): choose(color)
            case .callout: startCallout()
            case .task: checklist()
            case .bullets: bullets()
            case .numbers: numbered()
            case .outdent: outdent()
            case .indent: indent()
            case .quote: quote()
            }
            refreshFormatState()
        }

        /// What the panel shows filled in: the caret line's heading, list and
        /// quote from its prefix, the inline styles from the decorations the
        /// last restyle produced around the caret.
        func refreshFormatState() {
            guard let formatPanel, let textView else { return }
            let text = textView.text as NSString
            let caret = textView.selectedRange.location
            let line = text.substring(with: text.lineRange(for: NSRange(location: caret, length: 0)))
                .trimmingCharacters(in: .newlines)
            var state = FormatState()
            if let hashes = line.range(of: #"^#{1,6}(?=[ \t])"#, options: .regularExpression) {
                state.headingLevel = line[hashes].count
            }
            state.quoted = line.hasPrefix(">")
            let item = line.replacingOccurrences(of: #"^[ \t]*(?:>[ \t]?)*"#, with: "", options: .regularExpression)
            if item.range(of: #"^[-*+] \[[ xX]\]"#, options: .regularExpression) != nil {
                state.list = .task
            } else if item.range(of: #"^[-*+][ \t]"#, options: .regularExpression) != nil {
                state.list = .bullets
            } else if item.range(of: #"^\d+[.)][ \t]"#, options: .regularExpression) != nil {
                state.list = .numbers
            }
            for decoration in styled?.decorations ?? []
            where decoration.range.location <= caret && caret <= NSMaxRange(decoration.range) {
                switch decoration.style {
                case .bold: state.inline.insert(.bold)
                case .italic: state.inline.insert(.italic)
                case .strikethrough: state.inline.insert(.strikethrough)
                case .inlineCode: state.inline.insert(.code)
                case .highlight: state.inline.insert(.highlight)
                default: break
                }
            }
            formatPanel.show(state)
        }

        static let highlightColorKey = "dev.stenglein.Heft.iOS.highlightColor"

        /// The colour the pencil highlights in, remembered between notes.
        private var highlightColor: HighlightColor? {
            get { HeftDefaults.shared.string(forKey: Self.highlightColorKey).flatMap(HighlightColor.init) }
            set { HeftDefaults.shared.set(newValue?.rawValue, forKey: Self.highlightColorKey) }
        }

        /// The highlight under the caret, as the last restyle found it.
        private func highlightAtCaret() -> NSRange? {
            guard let textView else { return nil }
            let selection = textView.selectedRange
            return styled?.decorations.first { decoration in
                guard case .highlight = decoration.style else { return false }
                return decoration.range.location <= selection.location
                    && NSMaxRange(selection) <= NSMaxRange(decoration.range)
            }?.range
        }

        /// The text a highlight marks, without its `==` or its colour.
        private func highlightedText(in range: NSRange, of text: NSString) -> String {
            let inner = text.substring(with: NSRange(location: range.location + 2, length: range.length - 4))
            return HighlightColor.split(inner).text
        }

        /// The pencil: off again inside a highlight, otherwise the selection
        /// highlighted in the current colour, or an empty highlight to type
        /// into.
        private func highlight() {
            guard let textView else { return }
            let text = textView.text as NSString
            if let existing = highlightAtCaret() {
                let plain = highlightedText(in: existing, of: text)
                apply(MarkdownEditing.Edit(
                    range: existing, replacement: plain,
                    selection: NSRange(location: existing.location, length: (plain as NSString).length)
                ))
                return
            }
            let selection = textView.selectedRange
            let selected = text.substring(with: selection)
            let opener = "==" + (highlightColor?.emoji ?? "")
            apply(MarkdownEditing.Edit(
                range: selection, replacement: opener + selected + "==",
                selection: NSRange(location: selection.location + (opener as NSString).length,
                                   length: (selected as NSString).length)
            ))
        }

        /// The dot: the colour from now on, and the highlight under the caret
        /// recoloured, as Notes does. It highlights nothing by itself.
        private func choose(_ color: HighlightColor?) {
            highlightColor = color
            formatPanel?.highlightColor = color
            guard let textView, let existing = highlightAtCaret() else { return }
            let text = textView.text as NSString
            let plain = highlightedText(in: existing, of: text)
            let opener = "==" + (color?.emoji ?? "")
            let selection = textView.selectedRange
            let replacement = opener + plain + "=="
            let shift = (replacement as NSString).length - existing.length
            apply(MarkdownEditing.Edit(
                range: existing, replacement: replacement,
                selection: NSRange(location: max(existing.location, selection.location + shift),
                                   length: selection.length)
            ))
        }

        /// Aa's callout: `> [!]` in front of the line with the caret between
        /// the brackets, so the strip offers the kinds as it does for a
        /// callout typed by hand; on a callout already, its kind is selected
        /// for the same choice.
        private func startCallout() {
            guard let textView else { return }
            let text = textView.text as NSString
            let selection = textView.selectedRange
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .newlines) as NSString
            let kind = content.range(of: #"(?<=^>[ \t]?\[!)[^\]]*(?=\])"#, options: .regularExpression)
            if kind.location != NSNotFound {
                textView.selectedRange = NSRange(location: line.location + NSMaxRange(kind), length: 0)
                restyle(textView)
                updateSuggestions()
                return
            }
            let quote = content.range(of: #"^>[ \t]?"#, options: .regularExpression)
            let existing = quote.location == NSNotFound ? 0 : quote.length
            apply(MarkdownEditing.Edit(
                range: NSRange(location: line.location, length: existing), replacement: "> [!] ",
                selection: NSRange(location: line.location + 4, length: 0)
            ))
            updateSuggestions()
        }

        /// `#` at the caret, after a space when it would otherwise join the
        /// word before, so the strip offers the vault's tags.
        @objc private func startTag() {
            guard let textView else { return }
            let text = textView.text as NSString
            let caret = textView.selectedRange.location
            let joins = caret > 0 && !CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar(text.character(at: caret - 1)) ?? " ")
            let marker = joins ? " #" : "#"
            apply(MarkdownEditing.Edit(
                range: textView.selectedRange, replacement: marker,
                selection: NSRange(location: caret + (marker as NSString).length, length: 0)
            ))
            updateSuggestions()
        }

        @objc private func code() { format(.code) }
        @objc private func heading1() { setHeading(1) }
        @objc private func heading2() { setHeading(2) }
        @objc private func heading3() { setHeading(3) }

        /// The line becomes a heading of `level`, or plain text when it
        /// already is one, so the same tap undoes it; level 0 is Body.
        private func setHeading(_ level: Int) {
            guard let textView else { return }
            let text = textView.text as NSString
            let selection = textView.selectedRange
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .newlines) as NSString
            let existing = content.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression)
            let current = existing.location == NSNotFound ? 0 : existing.length
            let currentLevel = existing.location == NSNotFound
                ? 0 : content.substring(with: existing).filter { $0 == "#" }.count
            let marker = level == 0 || currentLevel == level ? "" : String(repeating: "#", count: level) + " "
            let caret = max(line.location, selection.location - current + (marker as NSString).length)
            apply(MarkdownEditing.Edit(
                range: NSRange(location: line.location, length: current), replacement: marker,
                selection: NSRange(location: caret, length: selection.length)
            ))
        }

        /// `> ` in front of every selected line, or off them all when every
        /// one already has it.
        @objc private func quote() {
            guard let textView else { return }
            let text = textView.text as NSString
            let selection = textView.selectedRange
            let block = text.lineRange(for: selection)
            var lines = text.substring(with: block).components(separatedBy: "\n")
            let trailing = lines.last == "" ? lines.removeLast() : nil
            let quoted = lines.allSatisfy { $0.hasPrefix(">") || $0.isEmpty }
                && lines.contains { $0.hasPrefix(">") }
            var shift = 0
            for index in lines.indices where !(lines[index].isEmpty && lines.count > 1) {
                if quoted {
                    let drop = lines[index].hasPrefix("> ") ? 2 : (lines[index].hasPrefix(">") ? 1 : 0)
                    lines[index].removeFirst(drop)
                    if index == 0 { shift = -drop }
                } else {
                    lines[index] = "> " + lines[index]
                    if index == 0 { shift = 2 }
                }
            }
            if trailing != nil { lines.append("") }
            apply(MarkdownEditing.Edit(
                range: block, replacement: lines.joined(separator: "\n"),
                selection: NSRange(location: max(block.location, selection.location + shift),
                                   length: selection.length)
            ))
        }

        @objc private func numbered() {
            guard let textView else { return }
            if startItem("1. ", in: textView) { return }
            apply(MarkdownEditing.toggleList(.numbered, in: textView.text, range: textView.selectedRange))
        }

        @objc private func bold() { format(.bold) }
        @objc private func italic() { format(.italic) }
        @objc private func strikethrough() { format(.strikethrough) }

        private func format(_ format: InlineFormat) {
            guard let textView else { return }
            apply(MarkdownEditing.toggle(format, in: textView.text, range: textView.selectedRange))
        }

        @objc private func checklist() {
            guard let textView else { return }
            if startItem("- [ ] ", in: textView) { return }
            apply(MarkdownEditing.toggleChecklist(in: textView.text, range: textView.selectedRange))
        }

        @objc private func bullets() {
            guard let textView else { return }
            if startItem("- ", in: textView) { return }
            apply(MarkdownEditing.toggleList(.bullet, in: textView.text, range: textView.selectedRange))
        }

        /// The list toggles skip blank lines, which is right for a selection
        /// spanning paragraphs and wrong for the line just made with Return:
        /// there the button did nothing. A blank line under the caret gets
        /// the marker, keeping whatever indent it has.
        private func startItem(_ marker: String, in textView: MobileTextView) -> Bool {
            let selection = textView.selectedRange
            guard selection.length == 0 else { return false }
            let text = textView.text as NSString
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .newlines)
            guard content.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let end = line.location + (content as NSString).length
            apply(MarkdownEditing.Edit(
                range: NSRange(location: end, length: 0), replacement: marker,
                selection: NSRange(location: end + (marker as NSString).length, length: 0)
            ))
            return true
        }

        @objc private func indent() { shiftLines(outdent: false) }
        @objc private func outdent() { shiftLines(outdent: true) }

        /// A tab more or less at the start of every selected line, which is
        /// how Obsidian nests a list item.
        private func shiftLines(outdent: Bool) {
            guard let textView else { return }
            let text = textView.text as NSString
            let selection = textView.selectedRange
            let block = text.lineRange(for: selection)
            var lines = text.substring(with: block).components(separatedBy: "\n")
            let trailing = lines.last == "" ? lines.removeLast() : nil
            var removedBeforeCaret = 0
            var addedBeforeCaret = 0
            // A blank line takes its tab at the caret, so a list can be
            // nested from the line Return just made; the caret only moves by
            // what was actually put in front of it.
            if !outdent, selection.length == 0, lines.count <= 1,
               (lines.first ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                apply(MarkdownEditing.Edit(
                    range: NSRange(location: selection.location, length: 0), replacement: "\t",
                    selection: NSRange(location: selection.location + 1, length: 0)
                ))
                return
            }
            for index in lines.indices {
                if outdent {
                    if lines[index].hasPrefix("\t") {
                        lines[index].removeFirst()
                        if index == 0 { removedBeforeCaret = 1 }
                    } else if lines[index].hasPrefix("  ") {
                        lines[index].removeFirst(2)
                        if index == 0 { removedBeforeCaret = 2 }
                    }
                } else if !lines[index].isEmpty {
                    lines[index] = "\t" + lines[index]
                    if index == 0 { addedBeforeCaret = 1 }
                }
            }
            if trailing != nil { lines.append("") }
            let replacement = lines.joined(separator: "\n")
            let shift = outdent ? -removedBeforeCaret : addedBeforeCaret
            let caret = max(block.location, selection.location + shift)
            apply(MarkdownEditing.Edit(
                range: block, replacement: replacement,
                selection: NSRange(location: caret, length: selection.length)
            ))
        }

        /// `[[` with the caret inside, or the selection wrapped into a link.
        @objc private func wikiLink() {
            guard let textView else { return }
            let selection = textView.selectedRange
            let selected = (textView.text as NSString).substring(with: selection)
            apply(MarkdownEditing.Edit(
                range: selection, replacement: "[[\(selected)]]",
                selection: NSRange(location: selection.location + 2 + (selected as NSString).length, length: 0)
            ))
        }
    }
}

/// Keeps a phone's text at a readable measure on an iPad: past 720 points
/// the side margins grow rather than the lines.
final class MobileTextView: UITextView {
    override func layoutSubviews() {
        let side = max(16, (bounds.width - 720) / 2)
        let insets = UIEdgeInsets(top: 12, left: side, bottom: 160, right: side)
        if textContainerInset != insets { textContainerInset = insets }
        super.layoutSubviews()
    }
}
