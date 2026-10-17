import AppKit
import Foundation
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
            #expect(overlay.frame == hit.frame.insetBy(dx: -3, dy: -3))
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
            #expect(view.imageSelectionOverlayIfLoaded?.frame.width == CGFloat(44 + 6))
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

    @Test("A resize step always moves")
    func stepAlwaysMoves() {
        #expect(HeftTextKit2View.step(5, up: true) == 6)
        #expect(HeftTextKit2View.step(5, up: false) == 4)
        #expect(HeftTextKit2View.step(1, up: false) == 1)
        #expect(HeftTextKit2View.step(300, up: true) == 330)
    }
}
