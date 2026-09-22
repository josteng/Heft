import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import Heft

/// A figure too small to read from the back of the room is clicked and
/// shown across the screen, and the next key puts it away.
@MainActor
@Suite("Zooming a picture in a presentation")
struct PresentationZoomTests {

    @Test("A zoomed picture takes the next key, whichever it is")
    func zoomTakesTheKey() {
        for key in [SlideKey.previous, .next, .end] {
            #expect(key.action(zoomed: true) == .closeZoom, "\(key) went past the zoom")
        }
        #expect(SlideKey.previous.action(zoomed: false) == .previous)
        #expect(SlideKey.next.action(zoomed: false) == .next)
        #expect(SlideKey.end.action(zoomed: false) == .end)
    }

    @Test("The picture is scaled up to fill the screen, over a dark backdrop")
    func pictureFillsTheScreen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-zoom-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // Written through Core Graphics: a PNG built by hand from an
        // NSBitmapImageRep loads and reports its size, and then draws as
        // nothing at all.
        let context = CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        let renderer = ImageRenderer(
            content: ZoomedImage(url: url) {}.frame(width: 400, height: 300)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return color.redComponent > 0.8 && color.greenComponent < 0.3
        }
        // Fitted inside the 32pt margin: 336 wide, so it reaches x = 50.
        #expect(isRed(50, 150), "the picture was left at its own small size")
        // Opaque and dark, not merely "not the picture": a backdrop left out
        // altogether leaves the slide showing through.
        let corner = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
        #expect(corner.alphaComponent > 0.8, "the slide shows through around the picture")
        #expect(corner.brightnessComponent < 0.3, "the backdrop is too light to darken the slide")
    }
}
