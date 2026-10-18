#if os(iOS)
import SwiftUI
import UIKit

// The live surface is written against AppKit, and on the Mac these names are
// AppKit's own. On iOS they stand for UIKit's equivalents, so the styler and
// the widgets compile unchanged for both, and the Mac's code, which is on the
// typing path, is not rewritten for a second platform. Only what has no
// UIKit counterpart of the same shape is branched where it is used.
typealias NSFont = UIFont
typealias NSColor = UIColor
typealias NSImage = UIImage
/// What a colour resolves against: the trait collection, on iOS.
typealias NSAppearance = UITraitCollection

extension UITraitCollection {
    func performAsCurrentDrawingAppearance(_ body: () -> Void) {
        performAsCurrent(body)
    }

    /// AppKit names an appearance; caches key on it.
    var name: (rawValue: String, Void) {
        (userInterfaceStyle == .dark ? "dark" : "light", ())
    }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

extension UIColor {
    static var labelColor: UIColor { .label }
    static var textColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var quaternaryLabelColor: UIColor { .quaternaryLabel }
    static var separatorColor: UIColor { .separator }
    static var textBackgroundColor: UIColor { .systemBackground }
    static var controlAccentColor: UIColor { .tintColor }

    /// UIKit colours carry no colour space to convert between; the components
    /// read below are sRGB already.
    func usingColorSpace(_ space: NSColorSpace) -> UIColor? { self }

    var redComponent: CGFloat { components.red }
    var greenComponent: CGFloat { components.green }
    var blueComponent: CGFloat { components.blue }
    var alphaComponent: CGFloat { components.alpha }

    private var components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }
}

/// Stands in for AppKit's colour spaces, which only `usingColorSpace` names.
struct NSColorSpace {
    static let sRGB = NSColorSpace()
}

extension UIImage {
    convenience init?(contentsOf url: URL) {
        self.init(contentsOfFile: url.path)
    }
}

extension NSAttributedString {
    func boundingRect(with size: CGSize, options: NSStringDrawingOptions) -> CGRect {
        boundingRect(with: size, options: options, context: nil)
    }

    func draw(with rect: CGRect, options: NSStringDrawingOptions) {
        draw(with: rect, options: options, context: nil)
    }
}

/// The one compositing mode the widgets draw images with.
enum NSCompositingOperation { case sourceOver }

extension UIImage {
    /// AppKit's full image draw. UIKit contexts are already flipped the way
    /// the text is, so `respectFlipped` has nothing to correct here.
    func draw(
        in rect: CGRect, from source: CGRect, operation: NSCompositingOperation,
        fraction: CGFloat, respectFlipped: Bool, hints: [AnyHashable: Any]?
    ) {
        draw(in: rect, blendMode: .normal, alpha: fraction)
    }
}

/// The two traits the styler adds, bold and italic, as AppKit spells them.
struct NSFontTraitMask: OptionSet {
    let rawValue: Int
    static let boldFontMask = NSFontTraitMask(rawValue: 1)
    static let italicFontMask = NSFontTraitMask(rawValue: 2)
}

/// AppKit's way to add a trait to a font, done with a descriptor.
final class NSFontManager {
    static let shared = NSFontManager()

    func convert(_ font: UIFont, toHaveTrait trait: NSFontTraitMask) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if trait.contains(.boldFontMask) { traits.insert(.traitBold) }
        if trait.contains(.italicFontMask) { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}
#endif
