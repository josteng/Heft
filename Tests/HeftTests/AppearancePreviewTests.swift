import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// The Appearance preview is the editor's own drawing, so a colour chosen in
/// Settings has to come out of it.
@Suite("Appearance preview")
@MainActor
struct AppearancePreviewTests {

    private func pixels(colorful: Bool, appearance: NSAppearance?) -> NSBitmapImageRep {
        let host = AppearancePreview.PreviewHost()
        host.show(RenderContext(
            index: .empty, current: nil, vaultRoot: nil,
            colorfulFormatting: colorful,
            boldColor: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        ), in: appearance)
        let width: CGFloat = 420
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.height(for: width))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        if colorful, let out = ProcessInfo.processInfo.environment["HEFT_PREVIEW_PNG"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        return rep
    }

    private func greenPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent > 0.8, color.redComponent < 0.3, color.blueComponent < 0.3,
                   color.alphaComponent > 0.5 { count += 1 }
            }
        }
        return count
    }

    @Test("Bold text is drawn in the bold colour, and only when colourful")
    func boldColour() {
        let light = NSAppearance(named: .aqua)
        let colorful = pixels(colorful: true, appearance: light)
        #expect(colorful.pixelsHigh > 60)
        #expect(greenPixels(colorful) > 20)
        #expect(greenPixels(pixels(colorful: false, appearance: light)) == 0)
    }
}
