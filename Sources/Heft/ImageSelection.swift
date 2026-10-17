import AppKit
import HeftCore

/// A picture in the note selected by a click, the way Obsidian selects one.
///
/// A picture is its source collapsed and painted over, so a click used to
/// land on that source and reveal it: the picture turned into a line of
/// Markdown under the pointer, and there was nothing to resize or open. Now
/// a click selects the picture itself. The caret stays where it was, off
/// the picture's line, so the line stays drawn, and the keys act on the
/// picture until something else is clicked or typed.
///
/// Every command is an edit to the link's written size through
/// `ImageEmbed`, so it is undone like typing and the file is all there is.
extension HeftTextKit2View {

    /// Where the picture on the line starting at `lineStart` is drawn, in
    /// this view's coordinates. The same origin the fragment paints from:
    /// its frame, which already includes a list's indent, then `blockInset`.
    func pictureFrame(lineStart: Int) -> CGRect? {
        guard case .image(_, let size, _)? = liveLayout.blocks[lineStart],
              let manager = textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(
                content.documentRange.location,
                offsetBy: min(max(0, lineStart), string.utf16.count)
              ),
              let fragment = manager.textLayoutFragment(for: location)
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        return CGRect(
            origin: CGPoint(
                x: frame.minX + textContainerInset.width,
                y: frame.minY + textContainerInset.height + HeftLayoutFragment.blockInset
            ),
            size: size
        )
    }

    /// The drawn picture under `point`, if any.
    func picture(at point: CGPoint) -> (range: NSRange, frame: CGRect)? {
        for (lineStart, range) in liveLayout.images {
            if let frame = pictureFrame(lineStart: lineStart), frame.contains(point) {
                return (range, frame)
            }
        }
        return nil
    }

    /// A click on a drawn picture selects it, and says so; any other click
    /// drops the selection and is left to the text.
    func takePictureClick(_ event: NSEvent) -> Bool {
        if event.clickCount == 1, let picture = picture(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            selectImage(picture.range)
            return true
        }
        if selectedImage != nil { selectImage(nil) }
        return false
    }

    func selectImage(_ range: NSRange?) {
        guard selectedImage != range else { return }
        selectedImage = range
        updateImageSelection()
        updateVimCursor()
    }

    /// Puts the ring around the selected picture, or takes it down. Run after
    /// every restyle, since a resize moves the picture's edges.
    func updateImageSelection() {
        guard let range = selectedImage else {
            imageSelectionOverlayIfLoaded?.isHidden = true
            return
        }
        guard let lineStart = liveLayout.images.first(where: { $0.value == range })?.key,
              let frame = pictureFrame(lineStart: lineStart)
        else {
            // No longer drawn as a picture, so there is nothing to select.
            selectedImage = nil
            imageSelectionOverlayIfLoaded?.isHidden = true
            updateVimCursor()
            return
        }
        let overlay = imageSelectionOverlay
        overlay.frame = frame.insetBy(dx: -ImageSelectionOverlay.margin, dy: -ImageSelectionOverlay.margin)
        overlay.isHidden = false
        overlay.needsDisplay = true
    }

    /// What a key does to the selected picture. True when it was used;
    /// anything else drops the selection and is typed as usual.
    func handleImageKey(characters: String, keyCode: UInt16) -> Bool {
        guard let range = selectedImage, let embed = ImageEmbed(string, range: range) else {
            selectImage(nil)
            return false
        }
        switch (characters, keyCode) {
        case ("+", _), ("=", _):
            resizeSelectedImage(embed, to: Self.step(currentWidth(of: embed), up: true))
        case ("-", _):
            resizeSelectedImage(embed, to: Self.step(currentWidth(of: embed), up: false))
        case ("0", _):
            resizeSelectedImage(embed, to: nil)
        case (_, 36), (_, 76):
            // Return: the source, to edit by hand.
            selectImage(nil)
            setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        case (_, 51), (_, 117):
            // Delete or forward delete: the picture goes, with its line.
            selectImage(nil)
            applyPictureEdit(embed.removing(in: string), reselect: false)
        case (_, 53):
            selectImage(nil)
        default:
            selectImage(nil)
            return false
        }
        return true
    }

    /// The width a picture is drawn at now: its written size, or else what
    /// the layout made of its own.
    private func currentWidth(of embed: ImageEmbed) -> Int {
        if let width = embed.width { return width }
        let drawn = liveLayout.images.first { $0.value == embed.range }
            .flatMap { pictureFrame(lineStart: $0.key) }
        return Int((drawn?.width ?? 100).rounded())
    }

    /// Ten percent a step, so a small picture is not jumped past and a large
    /// one does not take thirty presses.
    static func step(_ width: Int, up: Bool) -> Int {
        let next = up ? Double(width) * 1.1 : Double(width) / 1.1
        let rounded = Int(next.rounded())
        return max(1, rounded == width ? width + (up ? 1 : -1) : rounded)
    }

    // MARK: - Dragging the handle

    /// The selected picture's frame, while it is drawn.
    func selectedPictureFrame() -> CGRect? {
        guard let range = selectedImage,
              let lineStart = liveLayout.images.first(where: { $0.value == range })?.key
        else { return nil }
        return pictureFrame(lineStart: lineStart)
    }

    /// Whether `point` is on the selected picture's resize handle. Grown past
    /// the drawn dot, which is small so as not to cover the picture.
    func isOnResizeHandle(_ point: CGPoint) -> Bool {
        guard let frame = selectedPictureFrame() else { return false }
        let reach = ImageSelectionOverlay.handleRadius + 5
        return CGRect(x: frame.maxX - reach, y: frame.maxY - reach, width: reach * 2, height: reach * 2)
            .contains(point)
    }

    /// Starts a drag on the handle, if `point` is on it.
    func beginPictureResize(at point: CGPoint) -> Bool {
        guard isOnResizeHandle(point), let frame = selectedPictureFrame() else { return false }
        pictureResize = PictureResize(start: convert(point, to: nil), size: frame.size)
        return true
    }

    /// Redraws the picture at the width the pointer has dragged it to, by
    /// writing that width into its link: the picture on screen is always the
    /// file's, even mid-drag. The whole drag is one mouse-down event, so it
    /// undoes as one step.
    ///
    /// In window coordinates, not this view's. Shrinking a picture at the end
    /// of a note shortens the note and the scroll view pulls the text down
    /// under a pointer that has not moved; measured in the text's own
    /// coordinates that read as more drag, which shrank the picture again.
    func continuePictureResize(toWindowPoint point: CGPoint) {
        guard let drag = pictureResize, let range = selectedImage,
              let embed = ImageEmbed(string, range: range)
        else { return }
        let width = drag.width(at: point, limit: maximumPictureWidth())
        guard width != Int(selectedPictureFrame()?.width.rounded() ?? -1) else { return }
        resizeSelectedImage(embed, to: width)
    }

    func endPictureResize() {
        pictureResize = nil
    }

    /// The widest a picture can be dragged: the text column.
    private func maximumPictureWidth() -> Int {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let column = (textContainer?.size.width ?? 600) - 2 * padding
        // The picture's left edge already sits past the padding; only a
        // list's indent beyond it narrows the room.
        let start = selectedPictureFrame()?.minX ?? (textContainerInset.width + padding)
        let indent = start - textContainerInset.width - padding
        return max(16, Int(column - indent))
    }

    /// Runs the drag to the button's release. A tracking loop rather than
    /// `mouseDragged`, which `NSTextView` claims for selecting text.
    func trackPictureResize() {
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            continuePictureResize(toWindowPoint: event.locationInWindow)
            if event.type == .leftMouseUp { break }
        }
        endPictureResize()
    }

    func resizeSelectedImage(_ embed: ImageEmbed, to width: Int?) {
        applyPictureEdit(embed.resizing(toWidth: width), reselect: true)
    }

    /// One undoable edit, with the caret kept where it was relative to the
    /// text around it and, unless the picture went, the picture still
    /// selected under its new source.
    private func applyPictureEdit(_ edit: MarkdownEditing.Edit, reselect: Bool) {
        guard !edit.isEmpty, NSMaxRange(edit.range) <= (string as NSString).length,
              shouldChangeText(in: edit.range, replacementString: edit.replacement)
        else { return }
        let caret = selectedRange()
        let delta = (edit.replacement as NSString).length - edit.range.length
        isEditingSelectedImage = true
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        isEditingSelectedImage = false
        let moved = caret.location >= NSMaxRange(edit.range)
            ? caret.location + delta
            : min(caret.location, edit.range.location)
        setSelectedRange(NSRange(location: max(0, moved), length: 0))
        if reselect { selectedImage = edit.selection }
        restyleNow()
        updateImageSelection()
        updateVimCursor()
    }
}

/// Where a drag on the handle started, in window coordinates, and the
/// picture's size then.
struct PictureResize {
    let start: CGPoint
    let size: CGSize

    /// The width the drag has reached. Whichever way the pointer moved
    /// further counts, so a corner can be pulled along either edge, and the
    /// picture keeps its proportions either way. A window's y grows upwards,
    /// so pulling the corner down is a fall in y.
    func width(at point: CGPoint, limit: Int) -> Int {
        let dx = point.x - start.x
        let dy = (start.y - point.y) * (size.width / max(size.height, 1))
        let delta = abs(dx) >= abs(dy) ? dx : dy
        return min(limit, max(16, Int((size.width + delta).rounded())))
    }
}

/// The ring around a selected picture, and the handle on its corner.
///
/// A subview, like the table's caret, because selecting a picture changes
/// neither its attributes nor its layout, and a fragment only redraws for
/// one of those.
final class ImageSelectionOverlay: NSView {
    /// How far the ring sits outside the picture.
    static let outset: CGFloat = 3
    static let handleRadius: CGFloat = 5
    /// The view reaches past the ring by the handle's radius, so the handle
    /// on the corner is not clipped.
    static let margin: CGFloat = outset + handleRadius

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks belong to the text view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // The picture's own corner radius plus the gap, so the two curves run
        // parallel.
        let ringRect = bounds.insetBy(dx: Self.handleRadius + 1, dy: Self.handleRadius + 1)
        let ring = NSBezierPath(
            roundedRect: ringRect,
            xRadius: 8 + Self.outset, yRadius: 8 + Self.outset
        )
        ring.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        ring.stroke()

        // On the picture's own corner, which is where a drag measures from.
        let corner = CGPoint(x: bounds.maxX - Self.margin, y: bounds.maxY - Self.margin)
        let handle = NSBezierPath(ovalIn: CGRect(
            x: corner.x - Self.handleRadius, y: corner.y - Self.handleRadius,
            width: Self.handleRadius * 2, height: Self.handleRadius * 2
        ))
        NSColor.white.setFill()
        handle.fill()
        handle.lineWidth = 2
        handle.stroke()
    }
}
