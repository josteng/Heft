import AppKit
import SwiftMath

/// Typesets LaTeX to an image via SwiftMath.
///
/// Results are cached: the live editor re-renders on every keystroke and the
/// same expression would otherwise be typeset dozens of times a second. The
/// cache key includes the appearance because the glyph colour is baked in.
enum MathRenderer {

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    /// `nil` when the expression does not parse, which is the normal state
    /// while the user is still typing it. Callers fall back to showing source.
    static func image(
        latex: String,
        fontSize: CGFloat,
        color: NSColor,
        display: Bool
    ) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(display ? "D" : "I")|\(fontSize)|\(resolved.hexish)|\(trimmed)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let math = MTMathImage(
            latex: trimmed,
            fontSize: fontSize,
            textColor: resolved,
            labelMode: display ? .display : .text
        )
        let (error, image) = math.asImage()
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    static func clear() { cache.removeAllObjects() }
}

extension NSColor {
    /// Compact identity for cache keys; exact fidelity is not needed.
    ///
    /// Shared with the symbol cache in `LiveWidgets`, which keys on the tint
    /// for the same reason: two callout kinds differ only by colour.
    var hexish: String {
        guard let rgb = usingColorSpace(.sRGB) else { return description }
        return String(
            format: "%02X%02X%02X%02X",
            Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255)
        )
    }
}
