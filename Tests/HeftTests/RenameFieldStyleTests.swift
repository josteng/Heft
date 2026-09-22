import AppKit
import SwiftUI
import Testing
@testable import Heft

/// A name being renamed on a selected row has a field of its own, or its
/// caret and selection, both drawn in the accent colour, vanish into the
/// accent fill beneath them.
@MainActor
@Suite("The rename field", .serialized)
struct RenameFieldStyleTests {

    static let accent = NSColor.systemRed

    static func render(styled: Bool) -> NSBitmapImageRep {
        let name = Text("Example").font(.system(size: 12))
        let row = HStack(spacing: 0) {
            if styled { name.modifier(RenameFieldStyle()) } else { name }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 40)
        .background(Color(nsColor: accent))
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @Test("The name sits on the text background, not on the accent fill")
    func fieldCoversTheAccent() throws {
        let bitmap = Self.render(styled: true)
        let scale = CGFloat(bitmap.pixelsWide) / 200
        // Just inside the field's leading edge, beside the first letter.
        let color = try #require(bitmap.colorAt(x: Int(7 * scale), y: Int(20 * scale)))
            .usingColorSpace(.sRGB)!
        let accent = Self.accent.usingColorSpace(.sRGB)!
        #expect(
            abs(color.redComponent - accent.redComponent) + abs(color.greenComponent - accent.greenComponent) > 0.3,
            "the field is the accent colour: \(color)"
        )
    }

    @Test("Starting a rename does not move the name")
    func nameDoesNotMove() {
        func width(_ view: some View) -> CGFloat {
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let name = Text("Example").font(.system(size: 12))
        #expect(
            width(name.modifier(RenameFieldStyle())) == width(name),
            "the field's padding pushes the name sideways"
        )
    }
}
