import HeftCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The live surface on iOS: the Mac's styling and widget drawing, in a
/// `UITextView` on the same TextKit 2 stack.
///
/// Everything below the view is shared: `LiveDecorator` and `RestyleScope`
/// from HeftCore, `LiveRestyler`, `LiveStyler` and `HeftLayoutFragment` from
/// HeftTextKit.
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
    /// Room above the first line, more under the calendar's divider.
    var topInset: CGFloat = 12
    /// Saves a picture or file for this note and answers the embed to write.
    var attach: ((EditorAttachment) throws -> String)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MobileTextView {
        let view = MobileTextView(usingTextLayoutManager: true)
        view.topInset = topInset
        let coordinator = context.coordinator
        coordinator.textView = view
        view.delegate = coordinator
        view.textLayoutManager?.delegate = coordinator
        view.backgroundColor = .clear
        // A link takes the colour the styler gives it, as on the Mac; the
        // text view's own link style drew every link in the tint.
        view.linkTextAttributes = [:]
        view.font = Theme.liveFont
        view.alwaysBounceVertical = true
        // Under the phone's bar the note ends at a firmer edge, as its lists
        // do beneath theirs; the iPad's wider bar keeps the soft blur.
        view.topEdgeEffect.style = UIDevice.current.userInterfaceIdiom == .phone ? .hard : .soft
        view.keyboardDismissMode = .interactive
        // Markdown is typed literally: curled quotes and joined dashes would
        // change what the file says.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        coordinator.accessory = coordinator.keyboardBar()
        view.inputAccessoryView = coordinator.accessory
        view.isFindInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        view.ownTap = tap
        view.onFormat = { [weak coordinator] tool in coordinator?.applyTool(tool) }
        view.onAttach = { [weak coordinator] source in coordinator?.startAttach(source) }
        view.onWidthClass = { [weak coordinator] in coordinator?.updateAccessory() }
        view.onAcceptSuggestion = { [weak coordinator] position in coordinator?.acceptSuggestion(position) }
        coordinator.fillShortcutsBar(of: view)
        view.isOnPicture = { [weak coordinator, weak view] point in
            guard let coordinator, let view else { return false }
            return coordinator.pictureRange(at: point, in: view) != nil
        }
        view.addInteraction(UIScribbleInteraction(delegate: coordinator))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let pencil = UIPencilInteraction(delegate: coordinator)
            view.addInteraction(pencil)
            coordinator.pencil = pencil
            coordinator.updatePencilInteraction()
            NotificationCenter.default.addObserver(
                coordinator, selector: #selector(Coordinator.updatePencilInteraction),
                name: UIApplication.didBecomeActiveNotification, object: nil
            )
            #if DEBUG
            // `HEFT_IOS_PENCIL_PALETTE=x,y`: the palette as a squeeze with
            // the Pencil at that point would open it, for a screenshot.
            let palette = ProcessInfo.processInfo.environment["HEFT_IOS_PENCIL_PALETTE"]?
                .split(separator: ",").compactMap { Double($0) }
            if let palette, palette.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak coordinator, weak view] in
                    guard let view else { return }
                    coordinator?.togglePalette(near: CGPoint(
                        x: palette[0], y: palette[1] + view.contentOffset.y
                    ))
                }
            }
            #endif
        }
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
        /// Double-tap and squeeze, on an iPad.
        var pencil: UIPencilInteraction?
        /// The format palette a Pencil gesture opened, while it shows.
        weak var palette: UIViewController?
        private var renderContext: RenderContext?
        private var scrolledDown: ((Bool) -> Void)?
        private var follow: ((URL) -> Void)?
        private var attach: ((EditorAttachment) throws -> String)?
        /// Where the caret was when a picker took the keyboard away.
        private var attachAt: NSRange?

        private let restyler = LiveRestyler()
        private var layout: LiveLayout { restyler.layout }
        /// The text revision this view last took from the document, so a
        /// rescan that re-read the same text does not reset the caret.
        private var loadedRevision = -1
        private var focusRequest = 0
        private var wasScrolledDown = false
        /// Until when a fold just reported is still animating; the view is
        /// changing size under the scroll position meanwhile.
        private var settlingUntil = Date.distantPast
        /// Whether the text view had the keyboard when a tap began, so a
        /// checkbox tapped while reading does not leave the keyboard up.
        private var hadFocusAtTap = false

        func update(from editor: LiveNoteEditor) {
            document = editor.document
            editor.document.textView = textView
            scrolledDown = editor.scrolledDown
            follow = editor.follow
            attach = editor.attach
            let contextChanged = renderContext.map { !Self.sameSurface($0, editor.context) } ?? true
            renderContext = editor.context
            guard let textView else { return }
            // The accent is the note's: the caret and selection take it, and
            // the app's chrome keeps the system's, as on the Mac.
            let caret = editor.context.accentColor == StyleDefaults.accentColor ? nil : editor.context.accentColor
            if textView.tintColor != caret ?? textView.superview?.tintColor { textView.tintColor = caret }
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
                // In one go, as a paste arrives.
                if let pasted = environment["HEFT_IOS_PASTE"],
                   self.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: pasted) {
                    textView.insertText(pasted)
                }
                for action in (environment["HEFT_IOS_ACTIONS"] ?? "").split(separator: ",") {
                    switch action {
                    case "bullets": self.bullets()
                    case "checklist": self.checklist()
                    case "attach":
                        // A generated picture, through the same path a photo takes.
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 140)).image { context in
                            UIColor.systemTeal.setFill()
                            context.fill(CGRect(x: 0, y: 0, width: 240, height: 140))
                        }
                        self.attachAt = textView.selectedRange
                        if let data = image.jpegData(compressionQuality: 0.85) {
                            self.insertAttachment(.image(data, extension: "jpg"))
                        }
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
                && a.colorfulFormatting == b.colorfulFormatting
                && a.headingFont == b.headingFont && a.headingBars == b.headingBars
                && a.palette == b.palette
                && [a.accentColor, a.linkColor, a.tagColor, a.codeColor, a.boldColor, a.italicColor]
                    == [b.accentColor, b.linkColor, b.tagColor, b.codeColor, b.boldColor, b.italicColor]
                && a.headingColors == b.headingColors
        }

        /// Replaces the text, keeping the caret beside the text it was in:
        /// a capture merged in above the line being typed moves that line.
        private func load(_ text: String, into textView: MobileTextView) {
            let selection = textView.selectedRange
            let caret = NoteSync.caret(selection.location, from: textView.text, to: text)
            restyler.reset()
            textView.text = text
            textView.selectedRange = NSRange(location: caret, length: 0)
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
            // into shows its source. A range keeps the caret's reveal: one
            // that followed the selection showed each line's markup as a
            // handle was dragged over it, so the lines grew under the finger
            // and the text view scrolled to chase the handle. The Mac holds
            // its restyle for the whole mouse drag for the same reason.
            let reveal: Reveal
            if !textView.isFirstResponder {
                reveal = .none
            } else if selection.length > 0 {
                reveal = restyler.styled.flatMap { $0.source.isEqual(to: source as String) ? $0.reveal : nil }
                    ?? Reveal(selection: NSRange(location: selection.location, length: 0), in: source)
            } else {
                reveal = Reveal(selection: selection, in: source)
            }

            var context = renderContext
            context.appearance = textView.traitCollection
            switch restyler.restyle(
                storage, source: source, reveal: reveal, context: context,
                width: textView.textContainer.size.width, minimumContentWidth: 200
            ) {
            case .current:
                updateTypingAttributes(in: textView)
            case .unchanged(let exclusions):
                spellExclusions = exclusions
                updateTypingAttributes(in: textView)
            case .restyled(let exclusions, let relayout):
                spellExclusions = exclusions
                relayout.apply(to: textView.textLayoutManager)
                updateTypingAttributes(in: textView)
                refreshFormatState()
            }
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

        nonisolated func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            MainActor.assumeIsolated {
                restyler.fragment(for: location, in: textElement, manager: textLayoutManager)
            }
        }

        // MARK: Editing

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n", range.length == 0, let view = textView as? MobileTextView,
               continueStructure(at: range.location, in: view) {
                return false
            }
            // Return, a paste, a dictation: a break typed is the note's own,
            // so a Windows note does not end up mixed. Rewritten and put in
            // here, since the delegate cannot hand UIKit other text.
            if let view = textView as? MobileTextView, let adapted = inNoteLineEnding(text, in: view) {
                pendingPaste = (adapted as NSString).length > 1 ? (range.location, adapted) : nil
                replace(range, with: adapted, in: view)
                return false
            }
            noteEdit(range, replacedBy: text)
            // More than a character at once is a paste or a dictation, never
            // typing; a web address arriving that way is offered as a link.
            pendingPaste = (text as NSString).length > 1 ? (range.location, text) : nil
            return true
        }

        private var pendingPaste: (location: Int, text: String)?
        /// An address just pasted, and what it could read as a link: the
        /// site's name at once, the page's title and short versions of it
        /// once they arrive, as the Mac's menu offers them.
        /// Where the caret was left by a link just completed from `[[`,
        /// while it is still there: the strip then asks whether a heading or
        /// other text should follow the note's name.
        private var justLinked: Int?
        private var pastedLink: PastedLink?
        private var pastedTitles: [String] = []

        private func notePaste(in textView: UITextView) {
            guard let paste = pendingPaste else { return }
            pendingPaste = nil
            guard let link = PastedLink.after(pasting: paste.text, at: paste.location, in: textView.text),
                  let url = URL(string: link.address)
            else { return }
            pastedLink = link
            pastedTitles = []
            Task { [weak self] in
                guard let title = await LinkTitles.pageTitle(url) else { return }
                self?.offerTitles([title], for: link)
                let short = await LinkTitles.shortTitles(title, url)
                self?.offerTitles([title] + short, for: link)
            }
        }

        private func offerTitles(_ titles: [String], for link: PastedLink) {
            guard pastedLink == link else { return }
            var seen = Set<String>()
            pastedTitles = titles.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            updateSuggestions()
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

        /// `text` written in the note's own line ending, or nil when it
        /// already is. Only the inserted text: the note's lines are its own.
        private func inNoteLineEnding(_ text: String, in textView: MobileTextView) -> String? {
            guard text.utf16.contains(where: { $0 == 10 || $0 == 13 }) else { return nil }
            let ending = LineEnding(of: textView.text)
            return ending.differs(in: text) ? ending.applied(to: text) : nil
        }

        /// Through the text view, so undo and the delegate see it as typing.
        /// A break in `text` is written in the note's line ending.
        private func replace(_ range: NSRange, with text: String, in textView: MobileTextView) {
            let text = inNoteLineEnding(text, in: textView) ?? text
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }
            noteEdit(range, replacedBy: text)
            textView.replace(textRange, withText: text)
        }

        /// Each edit restyles before the next, so the shift is replaced
        /// rather than added to: should UIKit report an edit made through
        /// `replace` to the delegate as well, it is not counted twice.
        private func noteEdit(_ range: NSRange, replacedBy text: String) {
            restyler.discardShift()
            restyler.noteEdit(endingAt: NSMaxRange(range), delta: (text as NSString).length - range.length)
        }

        func apply(_ edit: MarkdownEditing.Edit) {
            guard let textView, !edit.isEmpty else { return }
            let edit = edit.adapted(to: LineEnding(of: textView.text))
            replace(edit.range, with: edit.replacement, in: textView)
            textView.selectedRange = edit.selection
            restyle(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? MobileTextView else { return }
            notePaste(in: view)
            restyle(view)
            document?.edited(view.text, at: loadedRevision)
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
                document?.readerMoved()
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
            document?.readerMoved()
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
            /// A drawn picture, whose source is hidden under it.
            case picture(NSRange)
        }

        /// The embed under a drawn picture at `point`, if there is one.
        func pictureRange(at point: CGPoint, in textView: MobileTextView) -> NSRange? {
            lineStart(at: point, in: textView).flatMap { layout.images[$0]?.range }
        }

        /// Where the line drawn at `point` starts, which is what widgets are
        /// keyed by.
        func lineStart(at point: CGPoint, in textView: MobileTextView) -> Int? {
            guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
            let inContainer = CGPoint(x: point.x - textView.textContainerInset.left,
                                      y: point.y - textView.textContainerInset.top)
            guard let fragment = manager.textLayoutFragment(for: inContainer) else { return nil }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let text = textView.text as NSString
            guard start >= 0, start <= text.length else { return nil }
            return text.lineRange(for: NSRange(location: start, length: 0)).location
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
            if let picture = layout.images[line.location] {
                return .picture(picture.range)
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
            // A tag carries no link; its pill is where the styler drew one,
            // and it opens the notes carrying it, as the note's `follow`
            // answers a tag.
            for probe in [offset, offset - 1] {
                guard let pill = layout.inlineTags[line.location]?
                        .first(where: { NSLocationInRange(probe, $0.range) }),
                      Self.contains(point, pill.range, in: textView) else { continue }
                let name = text.substring(with: pill.range).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                var components = URLComponents()
                components.scheme = HeftURL.scheme
                components.host = HeftURL.Host.follow.rawValue
                components.queryItems = [URLQueryItem(name: "tag", value: name)]
                if !name.isEmpty, let url = components.url { return .link(url) }
            }
            return nil
        }

        /// Whether `point` is on the drawn text of `range`: past the end of
        /// a line ending in a tag, the nearest character is still the tag's.
        private static func contains(_ point: CGPoint, _ range: NSRange, in textView: UITextView) -> Bool {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return false }
            return textView.selectionRects(for: textRange).contains {
                $0.rect.insetBy(dx: -6, dy: -4).contains(point)
            }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView else { return false }
            hadFocusAtTap = textView.isFirstResponder
            guard let found = target(at: touch.location(in: textView), in: textView) else { return false }
            if !hadFocusAtTap {
                if case .picture = found {} else {
                    textView.refusesFocus = true
                    // Back once the tap is over, or a moment later if it
                    // became a scroll instead.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak textView] in
                        textView?.refusesFocus = false
                    }
                }
            }
            return true
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
            case .picture(let range):
                // The whole embed, selected, as the Mac selects a picture: a
                // selection keeps the line as it is drawn, where a caret in
                // the source revealed it and moved everything under the
                // finger. Typing or Delete then acts on the picture.
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
                textView.selectedRange = range
                return
            }
            // The text view refused the keyboard for this tap; a box ticked
            // or a link followed while reading is not a request for it.
            DispatchQueue.main.async { textView.refusesFocus = false }
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
                ("photo.on.rectangle", "Add Photo or File", #selector(noAction)),
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
                if tool.0 == "photo.on.rectangle" {
                    button.menu = attachMenu()
                    button.showsMenuAsPrimaryAction = true
                } else {
                    button.addTarget(self, action: tool.2, for: .touchUpInside)
                }
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
            evenSuggestions = row.widthAnchor.constraint(
                equalTo: suggestions.frameLayoutGuide.widthAnchor, constant: -20
            )
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
        /// The strip above the keyboard: tools and suggestions on a phone,
        /// only suggestions on a wide iPad, whose tools are in the bar.
        var accessory: UIView?

        /// On a wide iPad the tools are in the note's toolbar and the
        /// suggestions above the keyboard in the note's own pane: a strip as
        /// the keyboard's accessory spans the whole window, sidebar too, and
        /// shows even with a hardware keyboard.
        func updateAccessory() {
            guard let textView else { return }
            let toolsInBar = textView.traitCollection.userInterfaceIdiom == .pad
                && textView.traitCollection.horizontalSizeClass == .regular
            let chips = toolsInBar
                ? suggestions.map { SuggestionChip(title: $0.title, detail: $0.detail, symbol: $0.symbol, tint: $0.tint) }
                : []
            if document?.suggestionChips != chips { document?.suggestionChips = chips }
            let wanted = toolsInBar ? nil : accessory
            guard textView.inputAccessoryView !== wanted else { return }
            textView.inputAccessoryView = wanted
            if textView.isFirstResponder { textView.reloadInputViews() }
        }
        private weak var barScroll: UIScrollView?
        private weak var suggestionScroll: UIScrollView?
        private weak var suggestionRow: UIStackView?
        /// A few suggestions share the strip's width; more scroll.
        private var evenSuggestions: NSLayoutConstraint?

        /// A completion offered in the strip: what it shows, and what
        /// accepting it writes for the link or tag being typed.
        private struct Suggestion: Equatable {
            enum Kind { case link, linkFollowUp, linkPart, pastedTitle, tag, callout, color }
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
            if let pasted = pastedLink, !pasted.isCurrent(in: text, caret: selection) { pastedLink = nil }
            if let linked = justLinked, selection != NSRange(location: linked, length: 0) { justLinked = nil }
            if justLinked != nil {
                found = [
                    Suggestion(title: "Heading", detail: "#", destination: "#", kind: .linkFollowUp,
                               symbol: "number"),
                    Suggestion(title: "Link Text", detail: "|", destination: "|", kind: .linkFollowUp,
                               symbol: "textformat"),
                ]
            } else if let pasted = pastedLink {
                found = (pastedTitles + [pasted.siteName]).map {
                    Suggestion(title: $0, detail: $0 == pasted.siteName ? "Site" : "Title",
                               destination: $0, kind: .pastedTitle, symbol: "link")
                }
            } else if let wiki = WikiCompletionContext.detect(in: text, selection: selection) {
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
            } else if let part = LinkPartContext.detect(in: text, selection: selection) {
                found = linkPartSuggestions(part, in: text, index: index)
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

        /// After `|`, the note's aliases; after `#`, its headings, read from
        /// the note itself, or from this one in `[[#`. An embed's `|` takes a
        /// size, which nothing here suggests.
        private func linkPartSuggestions(_ part: LinkPartContext, in text: String, index: VaultIndex) -> [Suggestion] {
            let ref = part.target.isEmpty ? nil : index.resolve(WikiLink(target: part.target), from: nil)
            switch part.part {
            case .text:
                guard let ref, !part.isEmbed else { return [] }
                let aliases = index.aliases(of: ref)
                requestLinkTexts(for: part, note: ref, in: text)
                let key = Self.linkTextKey(part)
                let suggested = (linkTexts?.key == key ? linkTexts?.texts ?? [] : [])
                    .filter { text in !aliases.contains { $0.lowercased() == text.lowercased() } }
                return part.matching(aliases).map {
                    Suggestion(title: $0, detail: "Alias", destination: $0, kind: .linkPart,
                               symbol: "arrow.turn.down.right")
                } + part.matching(suggested).map {
                    Suggestion(title: $0, detail: "Suggested", destination: $0, kind: .linkPart,
                               symbol: "sparkles")
                }
            case .heading:
                let source: String
                if let ref {
                    guard ref.isMarkdown, let read = try? MobileVault.read(ref.url) else { return [] }
                    source = read
                } else if part.target.isEmpty {
                    source = text
                } else {
                    return []
                }
                let headings = NoteText.headings(in: source)
                return part.matching(headings.map(\.text)).prefix(20).map { name in
                    let level = headings.first { $0.text == name }?.level ?? 1
                    return Suggestion(title: name, detail: "H\(level)",
                                      destination: LinkPartContext.linkable(heading: name),
                                      kind: .linkPart, symbol: "number")
                }
            }
        }

        /// Text after `|` that fits the sentence, asked of the on-device
        /// model once per link, as the Mac asks it.
        private var linkTexts: (key: String, texts: [String])?
        private var linkTextPending: String?

        private static func linkTextKey(_ part: LinkPartContext) -> String {
            "\(part.linkStart)|\(part.target.lowercased())"
        }

        private func requestLinkTexts(for part: LinkPartContext, note: NoteRef, in text: String) {
            let key = Self.linkTextKey(part)
            guard note.isMarkdown, linkTextPending != key, linkTexts?.key != key else { return }
            linkTextPending = key
            let sentence = part.sentence(in: text)
            let url = note.url, name = note.name
            Task { [weak self] in
                let opening = await Task.detached {
                    (try? MobileVault.read(url)).map { NoteText.splitFrontmatter($0).body } ?? ""
                }.value
                let texts = await LinkTitles.linkTexts(sentence: sentence, note: name, opening: opening)
                guard let self, self.linkTextPending == key else { return }
                self.linkTextPending = nil
                self.linkTexts = (key, texts)
                self.updateSuggestions()
            }
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
                // Each as wide as its own text when the row scrolls: the row's
                // width is not fixed then, and a button free to stretch took
                // the slack, leaving a wide empty gap beside a short title.
                button.setContentHuggingPriority(suggestions.count <= 3 ? .defaultLow : .required,
                                                 for: .horizontal)
                suggestionRow.addArrangedSubview(button)
            }
            let few = suggestions.count <= 3
            suggestionRow.distribution = few ? .fillEqually : .fill
            evenSuggestions?.isActive = few
            updateAccessory()
            let showing = !suggestions.isEmpty
            suggestionScroll.isHidden = !showing
            barScroll.isHidden = showing
            suggestionScroll.setContentOffset(CGPoint(x: -suggestionScroll.contentInset.left, y: 0), animated: false)
        }

        func acceptSuggestion(_ position: Int) { accept(position) }

        /// The iPad's shortcuts bar, which UIKit fills with bold, italic and
        /// underline: Markdown has no underline, so Heft's own instead.
        func fillShortcutsBar(of textView: MobileTextView) {
            let items: [(String, String, FormatTool)] = [
                ("bold", "Bold", .bold), ("italic", "Italic", .italic),
                ("strikethrough", "Strikethrough", .strikethrough), ("highlighter", "Highlight", .highlight),
            ]
            let buttons = items.map { symbol, title, tool in
                let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
                    self?.perform(tool)
                })
                item.accessibilityLabel = title
                return item
            }
            textView.inputAssistantItem.leadingBarButtonGroups = []
            textView.inputAssistantItem.trailingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: buttons, representativeItem: nil),
            ]
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
                // Not for a link that already says which text it shows.
                let caret = textView.selectedRange
                let now = textView.text as NSString
                if caret.length == 0, caret.location >= 2, !suggestion.destination.contains("|"),
                   now.substring(with: NSRange(location: caret.location - 2, length: 2)) == "]]" {
                    justLinked = caret.location
                }
            case .linkFollowUp:
                // Inside the link, before its `]]`, where the heading or text
                // suggestions then take over.
                guard let linked = justLinked, linked >= 2 else { return }
                justLinked = nil
                let at = linked - 2
                apply(MarkdownEditing.Edit(
                    range: NSRange(location: at, length: 0), replacement: suggestion.destination,
                    selection: NSRange(location: at + 1, length: 0)
                ))
            case .linkPart:
                guard let context = LinkPartContext.detect(in: text, selection: selection) else { return }
                apply(context.accepting(suggestion.destination))
            case .pastedTitle:
                guard let pasted = pastedLink, pasted.isCurrent(in: text, caret: selection) else { return }
                pastedLink = nil
                apply(pasted.linking(suggestion.destination))
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

        /// A hardware keyboard's shortcut, through the same path as the panel.
        func applyTool(_ tool: FormatTool) { perform(tool) }

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
            case .link: wikiLink()
            }
            refreshFormatState()
        }

        /// What the panel shows filled in: the caret line's heading, list and
        /// quote from its prefix, the inline styles from the decorations the
        /// last restyle produced around the caret.
        func refreshFormatState() {
            guard let textView else { return }
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
            for decoration in restyler.styled?.decorations ?? []
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
            formatPanel?.show(state)
            if document?.formatState != state { document?.formatState = state }
            if document?.highlightColor != highlightColor { document?.highlightColor = highlightColor }
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
            return restyler.styled?.decorations.first { decoration in
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

        // MARK: Photos and files

        @objc private func noAction() {}

        /// The photo library, the camera, or any file; each is copied into
        /// the vault where the Mac would put it, and embedded at the caret.
        private func attachMenu() -> UIMenu {
            UIMenu(children: AttachSource.available.map { source in
                UIAction(title: source.title, image: UIImage(systemName: source.symbol)) { [weak self] _ in
                    self?.startAttach(source)
                }
            })
        }

        /// The picker for `source`, from the strip's menu or the iPad's bar.
        func startAttach(_ source: AttachSource) {
            switch source {
            case .library:
                var configuration = PHPickerConfiguration()
                configuration.filter = .images
                configuration.selectionLimit = 0
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                presentPicker(picker)
            case .camera:
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.delegate = self
                presentPicker(picker)
            case .file:
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                picker.allowsMultipleSelection = true
                picker.delegate = self
                presentPicker(picker)
            }
        }

        private func presentPicker(_ picker: UIViewController) {
            guard let textView, var top = textView.window?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            attachAt = textView.selectedRange
            top.present(picker, animated: true)
        }

        /// The embed on a line of its own, and the keyboard back after it.
        /// Where that line goes is `MarkdownEditing.onOwnLine`'s.
        private func insertAttachment(_ attachment: EditorAttachment) {
            guard let textView, let attach else { return }
            do {
                let link = try attach(attachment)
                let edit = MarkdownEditing.onOwnLine(
                    link, at: attachAt ?? textView.selectedRange, in: textView.text
                )
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
                replace(edit.range, with: edit.replacement, in: textView)
                textView.selectedRange = edit.selection
                attachAt = edit.selection
                restyle(textView)
            } catch {
                document?.saveError = error.localizedDescription
            }
        }

        /// `> ` in front of every selected line, or off them all when every
        /// one already has it.
        @objc private func quote() {
            guard let textView else { return }
            apply(MarkdownEditing.toggleQuote(in: textView.text, range: textView.selectedRange))
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
            apply(MarkdownEditing.shiftLines(
                in: textView.text, range: textView.selectedRange, outdent: outdent
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
    var topInset: CGFloat = 12
    /// The editor's own tap, which handles a picture itself.
    weak var ownTap: UIGestureRecognizer?
    /// Set for a tap that ticks a box or follows a link while reading. The
    /// text view took such a tap as a request for the keyboard too, and in
    /// taking it scrolled to its old caret, often the top of the note,
    /// before the keyboard was handed back.
    var refusesFocus = false

    override var canBecomeFirstResponder: Bool {
        !refusesFocus && super.canBecomeFirstResponder
    }
    /// ⌘B and ⌘I from a hardware keyboard, written as Markdown rather than
    /// as the attributes UIKit would set on rich text.
    var onFormat: ((FormatTool) -> Void)?
    var onAttach: ((AttachSource) -> Void)?
    var onAcceptSuggestion: ((Int) -> Void)?
    /// Called when the window's width class changes, as entering Split View.
    var onWidthClass: (() -> Void)?
    private var watchingWidth = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !watchingWidth else { return }
        watchingWidth = true
        watchKeyboard()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (view: MobileTextView, _: UITraitCollection) in
            view.onWidthClass?()
        }
        onWidthClass?()
    }

    override func toggleBoldface(_ sender: Any?) { onFormat?(.bold) }
    override func toggleItalics(_ sender: Any?) { onFormat?(.italic) }
    @objc func highlightSelection(_ sender: Any?) { onFormat?(.highlight) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:))
            || action == #selector(highlightSelection(_:)) {
            return isEditable && isFirstResponder
        }
        return super.canPerformAction(action, withSender: sender)
    }
    var isOnPicture: (CGPoint) -> Bool = { _ in false }

    /// UIKit's own taps and presses would put a caret into the source a
    /// picture hides, revealing it and moving the picture away from the
    /// finger; on a picture only the editor's tap, and scrolling, begin.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer !== ownTap, !(recognizer is UIPanGestureRecognizer),
           isOnPicture(recognizer.location(in: self)) {
            return false
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    /// The editor runs on under the keyboard and whatever floats on it,
    /// as the iPad's shortcuts bar does with a hardware keyboard, and is
    /// padded by what covers it instead: shrunk to stop above them, it left
    /// that strip as empty window, black behind the bar's glass.
    ///
    /// Optional, and so nil until set: this view is made through UIKit's
    /// `init(usingTextLayoutManager:)`, which skips Swift's initial values,
    /// and an array left as zeroed memory crashed when read.
    private var keyboardWatch: [NSObjectProtocol]?

    private func watchKeyboard() {
        guard keyboardWatch == nil else { return }
        keyboardWatch = []
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardWatch?.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated { self?.keyboardMoved(to: name == UIResponder.keyboardWillHideNotification ? nil : frame) }
            })
        }
    }

    private func keyboardMoved(to frame: CGRect?) {
        var covered: CGFloat = 0
        if let frame, let window {
            let mine = convert(bounds, to: window)
            let keyboard = window.convert(frame, from: window.screen.coordinateSpace)
            covered = max(0, mine.maxY - keyboard.minY)
        }
        guard contentInset.bottom != covered else { return }
        contentInset.bottom = covered
        verticalScrollIndicatorInsets.bottom = covered
        if isFirstResponder { scrollRangeToVisible(selectedRange) }
    }

    override func layoutSubviews() {
        // 24 at the least on a phone, 20 elsewhere: a heading's bar is drawn
        // to the left of the text, and on a phone's narrow margin it sat
        // against the screen's edge.
        let least: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 24 : 20
        let side = max(least, (bounds.width - 720) / 2)
        let insets = UIEdgeInsets(top: topInset, left: side, bottom: 160, right: side)
        if textContainerInset != insets { textContainerInset = insets }
        super.layoutSubviews()
    }
}

/// What the keyboard strip hands over to be saved into the vault.
enum EditorAttachment {
    case image(Data, extension: String)
    case file(URL)
}

extension LiveNoteEditor.Coordinator: PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate, UIDocumentPickerDelegate
{
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            // A screenshot stays a PNG; a photo becomes a JPEG, which every
            // device and Obsidian can show, where HEIC is not certain to be.
            let png = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    if png {
                        self?.insertAttachment(.image(data, extension: "png"))
                    } else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                        self?.insertAttachment(.image(jpeg, extension: "jpg"))
                    }
                }
            }
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.85) {
            insertAttachment(.image(jpeg, extension: "jpg"))
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls { insertAttachment(.file(url)) }
    }
}

/// Where a picture or file to attach comes from.
enum AttachSource: CaseIterable {
    case library, camera, file

    /// The camera only where there is one.
    static var available: [AttachSource] {
        allCases.filter { $0 != .camera || UIImagePickerController.isSourceTypeAvailable(.camera) }
    }

    var title: String {
        switch self {
        case .library: "Photo Library"
        case .camera: "Take Photo"
        case .file: "Choose File"
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.on.rectangle"
        case .camera: "camera"
        case .file: "doc"
        }
    }
}

/// A suggestion as the iPad's note pane shows it, above the keyboard.
struct SuggestionChip: Equatable {
    var title: String
    var detail: String
    var symbol: String?
    var tint: UIColor?
}

// MARK: - Apple Pencil

extension LiveNoteEditor.Coordinator: UIPencilInteractionDelegate, UIScribbleInteractionDelegate {
    /// On only while Settings sends a double-tap or a squeeze to the app's
    /// palette. An interaction that is on takes squeeze from the system, so
    /// with any other choice it stays off and the system does what was asked.
    @objc func updatePencilInteraction() {
        pencil?.isEnabled = UIPencilInteraction.preferredTapAction == .showContextualPalette
            || UIPencilInteraction.preferredSqueezeAction == .showContextualPalette
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction == .showContextualPalette else { return }
        togglePalette(near: tap.hoverPose?.location)
    }

    func pencilInteraction(
        _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        // Once per squeeze, when it ends, as Apple asks.
        guard squeeze.phase == .ended,
              UIPencilInteraction.preferredSqueezeAction == .showContextualPalette
        else { return }
        togglePalette(near: squeeze.hoverPose?.location)
    }

    /// The format palette at the Pencil's tip, or at the caret when the
    /// Pencil is away from the screen; the same gesture again puts it away.
    /// Presented on the text view itself, so the tip's point needs no
    /// converting: the note view's space starts below the bar the text runs
    /// under.
    func togglePalette(near tip: CGPoint?) {
        guard let textView, let document else { return }
        if let palette, palette.presentingViewController != nil {
            palette.dismiss(animated: true)
            return
        }
        var point = tip
        if point == nil, let caret = textView.selectedTextRange?.end {
            let rect = textView.caretRect(for: caret)
            point = CGPoint(x: rect.midX, y: rect.maxY)
        }
        guard let point, var top = textView.window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let host = UIHostingController(rootView: FormatPopover(document: document))
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        host.popoverPresentationController?.sourceView = textView
        host.popoverPresentationController?.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        palette = host
        top.present(host, animated: true)
    }

    /// Not where the text under the Pencil is drawn rather than shown: a
    /// picture, a table, display maths, an embedded note, the properties or
    /// a rule. Writing there went into the hidden source.
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        guard let textView, let line = lineStart(at: location, in: textView),
              let block = layout.blocks[line]
        else { return true }
        switch block {
        case .image, .table, .blockMath, .embed, .properties, .thematicBreak, .agentGuide: return false
        default: return true
        }
    }

    /// A touch on a link while reading holds focus back, so that following
    /// it does not raise the keyboard; writing that starts there waits for
    /// the pause after a word instead of failing to focus.
    func scribbleInteractionShouldDelayFocus(_ interaction: UIScribbleInteraction) -> Bool {
        textView?.refusesFocus ?? false
    }

    func scribbleInteractionWillBeginWriting(_ interaction: UIScribbleInteraction) {
        textView?.refusesFocus = false
    }
}
