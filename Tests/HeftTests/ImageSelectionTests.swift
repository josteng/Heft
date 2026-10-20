import AppKit
import Foundation
import Quartz
import HeftCore
import Testing
@testable import Heft

/// A click on a drawn picture selects it, and the keys then act on the
/// picture's written size instead of typing.
@MainActor
@Suite("Selecting a picture")
struct ImageSelectionTests {

    /// An editor over a vault holding one real 40 by 30 picture, styled and
    /// laid out the way the window would have it before a click.
    private func withEditor(
        _ text: String, caret: Int = 0,
        _ body: (HeftTextKit2View) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        try png.write(to: root.appendingPathComponent("shot.png"))
        try text.write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        let context = RenderContext(index: index, current: nil, vaultRoot: root)
        let editor = LiveTextEditor(
            text: .constant(text), documentIdentity: "note.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.restyleNow()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try withExtendedLifetime(coordinator) { try body(view) }
    }

    private func centre(of view: HeftTextKit2View) throws -> CGPoint {
        let lineStart = try #require(view.liveLayout.images.keys.first)
        let frame = try #require(view.pictureFrame(lineStart: lineStart))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func press(_ view: HeftTextKit2View, _ characters: String, keyCode: UInt16 = 0) -> Bool {
        view.handleImageKey(characters: characters, keyCode: keyCode)
    }

    @Test("The picture is found where it is drawn, and nowhere else")
    func hitTest() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            let frame = try #require(view.pictureFrame(lineStart: 7))
            #expect(frame.size == CGSize(width: 40, height: 30))
            #expect(view.picture(at: CGPoint(x: frame.midX, y: frame.midY))?.range == NSRange(location: 7, length: 13))
            #expect(view.picture(at: CGPoint(x: frame.maxX + 5, y: frame.midY)) == nil)
            #expect(view.picture(at: CGPoint(x: frame.midX, y: frame.minY - 5)) == nil)
        }
    }

    @Test("Selecting rings the picture and hides the caret")
    func ringAndCaret() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            let hit = try #require(view.picture(at: try centre(of: view)))
            view.selectImage(hit.range)
            let overlay = try #require(view.imageSelectionOverlayIfLoaded)
            #expect(!overlay.isHidden)
            #expect(overlay.frame == hit.frame.insetBy(dx: -8, dy: -8))
            #expect(view.insertionPointColor == .clear)
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))

            #expect(press(view, "\u{1b}", keyCode: 53))
            #expect(view.selectedImage == nil)
            #expect(overlay.isHidden)
            #expect(view.insertionPointColor != .clear)
        }
    }

    @Test("Plus and minus resize by a tenth, zero resets")
    func resizeKeys() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(press(view, "+"))
            #expect(view.string == "intro\n\n![[shot.png|44]]\n\nafter")
            #expect(view.selectedImage == NSRange(location: 7, length: 16))
            // The ring follows the new size.
            #expect(view.imageSelectionOverlayIfLoaded?.frame.width == CGFloat(44 + 16))
            #expect(press(view, "-"))
            #expect(view.string == "intro\n\n![[shot.png|40]]\n\nafter")
            #expect(press(view, "0"))
            #expect(view.string == "intro\n\n![[shot.png]]\n\nafter")
            #expect(view.selectedImage == NSRange(location: 7, length: 13))
            // The caret before the picture stays put through all of it.
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        }
    }

    @Test("A caret after the picture moves with the text it is in")
    func caretAfterPictureShifts() throws {
        try withEditor("![[shot.png]]\n\nafter", caret: 17) { view in
            view.selectImage(NSRange(location: 0, length: 13))
            #expect(press(view, "+"))
            #expect(view.string == "![[shot.png|44]]\n\nafter")
            #expect(view.selectedRange() == NSRange(location: 20, length: 0))
        }
    }

    @Test("Return opens the source, Delete removes the picture")
    func returnAndDelete() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(press(view, "\r", keyCode: 36))
            #expect(view.selectedImage == nil)
            #expect(view.selectedRange() == NSRange(location: 20, length: 0))
        }
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(press(view, "\u{7f}", keyCode: 51))
            #expect(view.string == "intro\n\n\nafter")
            #expect(view.selectedImage == nil)
        }
    }

    @Test("Any other key drops the selection and is typed")
    func otherKeysType() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(!press(view, "a"))
            #expect(view.selectedImage == nil)
        }
    }

    @Test("Text changed from elsewhere drops the selection")
    func externalEditDeselects() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            // After the picture, so its source does not move and only the
            // edit itself can be what drops the selection.
            let end = (view.string as NSString).length
            view.insertText("x", replacementRange: NSRange(location: end, length: 0))
            #expect(view.selectedImage == nil)
        }
    }

    /// Daily notes made from one template start with the same picture at
    /// the same offset, and the selection is a range: kept across a swap,
    /// it rang the other note's picture and the next `-` shrank it.
    @Test("Opening another note drops the selection")
    func noteSwapDeselects() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            let coordinator = try #require(view.delegate as? LiveTextEditor.Coordinator)
            coordinator.load("intro\n\n![[shot.png]]\n\nanother day", into: view)
            view.restyleNow()
            #expect(view.selectedImage == nil)
            #expect(!press(view, "-"))
            #expect(view.string == "intro\n\n![[shot.png]]\n\nanother day")
        }
    }

    /// A restyle after typing redoes only the lines that changed and
    /// carries the rest over, so the pictures it did not redraw must come
    /// along, moved by the edit, or a click on one reveals its source.
    @Test("A picture stays clickable after typing elsewhere in the note")
    func clickableAfterTyping() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            let end = (view.string as NSString).length
            view.insertText("x", replacementRange: NSRange(location: end, length: 0))
            view.restyleNow()
            let below = try centre(of: view)
            #expect(view.picture(at: below)?.range == NSRange(location: 7, length: 13))

            view.insertText("y", replacementRange: NSRange(location: 0, length: 0))
            view.restyleNow()
            let above = try centre(of: view)
            #expect(view.picture(at: above)?.range == NSRange(location: 8, length: 13))
        }
    }

    /// The frame the view hit-tests and rings is checked against what the
    /// fragment actually paints: the picture is solid blue, so its pixels
    /// are found in a bitmap of the fragment.
    @Test("The picture's frame is where the fragment paints it")
    func frameMatchesDrawing() throws {
        try withEditor("intro\n\n- ![[shot.png]]\n\nafter") { view in
            let lineStart = try #require(view.liveLayout.images.keys.first)
            let frame = try #require(view.pictureFrame(lineStart: lineStart))
            let manager = try #require(view.textLayoutManager)
            let content = try #require(manager.textContentManager)
            let location = try #require(content.location(content.documentRange.location, offsetBy: lineStart))
            let fragment = try #require(manager.textLayoutFragment(for: location))
            let origin = fragment.layoutFragmentFrame.origin
            // The frame is hairline-wide, since its text is collapsed; the
            // picture is painted past it, across the container.
            let width = Int(try #require(view.textContainer).size.width)
            let height = Int(fragment.layoutFragmentFrame.height.rounded(.up))
            let space = CGColorSpaceCreateDeviceRGB()
            let bitmap = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // Flipped, as the text view draws.
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            fragment.draw(at: .zero, in: bitmap)
            NSGraphicsContext.restoreGraphicsState()

            let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let p = pixels + (y * width + x) * 4
                    // Blue and opaque: the picture, not the bullet beside it.
                    if p[2] > 150, p[0] < 120, p[3] > 200 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            #expect(maxX >= 0, "nothing blue was painted")
            // Row 0 of the bitmap's memory is the top of the flipped drawing.
            let painted = CGRect(
                x: CGFloat(minX) + origin.x + view.textContainerInset.width,
                y: CGFloat(minY) + origin.y + view.textContainerInset.height,
                width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)
            )
            #expect(abs(painted.minX - frame.minX) <= 1)
            #expect(abs(painted.minY - frame.minY) <= 1)
            #expect(abs(painted.width - frame.width) <= 1)
            #expect(abs(painted.height - frame.height) <= 1)
        }
    }

    @Test("A real click selects the picture and a real key resizes it")
    func eventsReachTheView() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let point = view.convert(try centre(of: view), to: nil)
            let click = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            // Not `mouseDown`: a click it fails to take goes on to
            // NSTextView's tracking loop, which waits for a release that never
            // comes headless, so a regression would hang the suite.
            #expect(view.takePictureClick(click))
            #expect(view.selectedImage == NSRange(location: 7, length: 13))

            let plus = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "+",
                charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 0
            ))
            view.keyDown(with: plus)
            #expect(view.string == "intro\n\n![[shot.png|44]]\n\nafter")
        }
    }

    @Test("Dragging the handle resizes the picture as it goes")
    func dragResizes() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            let frame = try #require(view.pictureFrame(lineStart: 7))
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            // Not selected yet: there is no handle to grab.
            #expect(!view.beginPictureResize(at: corner))
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(!view.beginPictureResize(at: CGPoint(x: frame.midX, y: frame.midY)))
            #expect(view.beginPictureResize(at: corner))

            view.continuePictureResize(toWindowPoint: view.convert(CGPoint(x: corner.x + 20, y: corner.y), to: nil))
            #expect(view.string == "intro\n\n![[shot.png|60]]\n\nafter")
            // Drawn at the new size already, and still selected and ringed.
            #expect(view.pictureFrame(lineStart: 7)?.size == CGSize(width: 60, height: 45))
            #expect(view.selectedImage == NSRange(location: 7, length: 16))
            #expect(view.imageSelectionOverlayIfLoaded?.frame.width == CGFloat(60 + 16))

            // Down by 30 is 40 across, at three by four.
            view.continuePictureResize(toWindowPoint: view.convert(CGPoint(x: corner.x, y: corner.y + 30), to: nil))
            #expect(view.string == "intro\n\n![[shot.png|80]]\n\nafter")
            view.endPictureResize()
            #expect(view.pictureResize == nil)
        }
    }

    @Test("A drag stops at the column and at a usable minimum")
    func dragLimits() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            let frame = try #require(view.pictureFrame(lineStart: 7))
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            #expect(view.beginPictureResize(at: corner))
            view.continuePictureResize(toWindowPoint: view.convert(CGPoint(x: corner.x + 5000, y: corner.y), to: nil))
            let padding = try #require(view.textContainer).lineFragmentPadding
            let column = Int(try #require(view.textContainer).size.width - 2 * padding)
            #expect(view.string == "intro\n\n![[shot.png|\(column)]]\n\nafter")
            view.continuePictureResize(toWindowPoint: view.convert(CGPoint(x: corner.x - 5000, y: corner.y), to: nil))
            #expect(view.string == "intro\n\n![[shot.png|16]]\n\nafter")
        }
    }

    @Test("The handle takes the resize pointer")
    func handleCursor() throws {
        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            let frame = try #require(view.pictureFrame(lineStart: 7))
            let cursor = view.cursorOverride(at: CGPoint(x: frame.maxX, y: frame.maxY), among: [])
            #expect(cursor != nil && cursor != .pointingHand && cursor != .arrow)
            #expect(view.cursorOverride(at: CGPoint(x: frame.midX, y: frame.midY), among: []) == nil)
        }
    }

    @Test("Space or a double-click opens the picture's file full size")
    func opensFullSize() throws {
        var shown: [URL] = []
        let previous = HeftTextKit2View.showPicture
        HeftTextKit2View.showPicture = { _, url in shown.append(url) }
        defer { HeftTextKit2View.showPicture = previous }

        try withEditor("intro\n\n![[shot.png]]\n\nafter") { view in
            view.selectImage(NSRange(location: 7, length: 13))
            #expect(press(view, " ", keyCode: 49))
            #expect(shown.last?.lastPathComponent == "shot.png")
            // Still selected, so Space again or the arrow keys keep working.
            #expect(view.selectedImage == NSRange(location: 7, length: 13))

            // What Quick Look is handed while it is up.
            let panel = try #require(QLPreviewPanel.shared())
            #expect(view.acceptsPreviewPanelControl(panel))
            #expect(view.numberOfPreviewItems(in: panel) == 1)
            #expect((view.previewPanel(panel, previewItemAt: 0) as? URL)?.lastPathComponent == "shot.png")

            view.selectImage(nil)
            #expect(!view.acceptsPreviewPanelControl(panel))
            #expect(view.numberOfPreviewItems(in: panel) == 0)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let point = view.convert(try centre(of: view), to: nil)
            let double = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
            ))
            shown = []
            #expect(view.takePictureClick(double))
            #expect(shown.count == 1)
        }
    }

    /// Shrinking a picture at the end of a note shortens the note, the
    /// scroll view pulls the text down to stay in range, and the picture's
    /// corner moves under a pointer that did not. Measured in the text
    /// view's own coordinates, that read as more drag, which shrank the
    /// picture again, which scrolled again.
    @Test("A picture at the end of a scrolled note shrinks once for one drag")
    func dragDoesNotFeedOnScrolling() throws {
        let filler = String(repeating: "line\n", count: 60)
        try withEditor(filler + "![[shot.png|200]]") { view in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
            scroll.hasVerticalScroller = true
            view.minSize = NSSize(width: 0, height: 0)
            view.maxSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
            view.autoresizingMask = [.width]
            scroll.documentView = view
            window.contentView = scroll
            view.restyleNow()
            view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
            view.sizeToFit()
            view.scrollToEndOfDocument(nil)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()

            let lineStart = try #require(view.liveLayout.images.keys.first)
            view.selectImage(view.liveLayout.images[lineStart]?.range)
            let frame = try #require(view.pictureFrame(lineStart: lineStart))
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            #expect(view.beginPictureResize(at: corner))
            let scrolledBefore = scroll.contentView.bounds.minY

            // The pointer moves once, then is held still while events keep
            // arriving, as they do mid-drag.
            let held = view.convert(CGPoint(x: corner.x - 40, y: corner.y), to: nil)
            view.continuePictureResize(toWindowPoint: held)
            #expect(view.string.hasSuffix("![[shot.png|160]]"))

            // The shorter note pulls the text down under the still pointer,
            // as the scroll view does when the document shrinks beneath it.
            for step in 1...3 {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scrolledBefore - CGFloat(30 * step)))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.continuePictureResize(toWindowPoint: held)
            }
            #expect(scroll.contentView.bounds.minY == scrolledBefore - 90)
            #expect(view.string.hasSuffix("![[shot.png|160]]"))
        }
    }

    @Test("A resize step always moves")
    func stepAlwaysMoves() {
        #expect(HeftTextKit2View.step(5, up: true) == 6)
        #expect(HeftTextKit2View.step(5, up: false) == 4)
        #expect(HeftTextKit2View.step(1, up: false) == 1)
        #expect(HeftTextKit2View.step(300, up: true) == 330)
    }
}
