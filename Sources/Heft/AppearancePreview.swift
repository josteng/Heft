import AppKit
import HeftCore
import SwiftUI

/// A few lines drawn by the editor itself in the chosen colours, at the top
/// of Settings ▸ Appearance, so a colour is judged where it will be used.
///
/// The same off-screen view the PDF export prints from, kept on screen; a
/// SwiftUI imitation would have shown neither the heading bars nor the
/// checkbox, and would drift from the editor as the editor changed.
struct AppearancePreview: NSViewRepresentable {
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme

    /// Invented content, and a web link rather than a wikilink: with no vault
    /// to resolve against, a wikilink would draw as a broken one.
    static let sample = """
        # Weekend plans
        Buy **fresh bread** and *maybe flowers* at the [market](https://example.com).
        - [ ] Water the garden #home
        ## Later
        Check `todo.md` before leaving.
        """

    func makeNSView(context: Context) -> PreviewHost { PreviewHost() }

    func updateNSView(_ host: PreviewHost, context: Context) {
        host.show(renderContext, in: RenderContext.appearance(for: colorScheme))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: PreviewHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 420
        return CGSize(width: width, height: host.height(for: width))
    }

    private var renderContext: RenderContext {
        RenderContext(
            index: .empty, current: nil, vaultRoot: nil,
            colorfulFormatting: appearance.colorfulFormattingEnabled,
            accentColor: appearance.accentColor,
            linkColor: appearance.linkColor,
            tagColor: appearance.tagColor,
            codeColor: appearance.codeColor,
            boldColor: appearance.boldColor,
            italicColor: appearance.italicColor,
            headingColors: (1...6).map(appearance.headingColor)
        )
    }

    /// Holds the rendered view, and renders again for a new width or a new
    /// set of colours: the text is five lines, so a fresh view is cheaper
    /// than keeping one in step.
    final class PreviewHost: NSView {
        private var context: RenderContext?
        private var drawnIn: NSAppearance?
        private var rendered: (width: CGFloat, view: NSTextView)?

        override var isFlipped: Bool { true }

        /// Some of the editor's page gutter, which the settings row already
        /// pads: the view is shifted this much under a clip. Less at the side,
        /// where a heading draws its colour bar in the gutter; none at the
        /// bottom, which the rendered view already ends at the text.
        private static let side: CGFloat = 12
        private static let top = PDFExport.viewInset - 6

        func show(_ context: RenderContext, in appearance: NSAppearance?) {
            self.context = context
            drawnIn = appearance
            rendered = nil
            needsLayout = true
            invalidateIntrinsicContentSize()
        }

        func height(for width: CGFloat) -> CGFloat {
            max(0, (view(for: width)?.frame.height ?? 0) - Self.top + 6)
        }

        override func layout() {
            super.layout()
            guard let view = view(for: bounds.width) else { return }
            if view.superview !== self {
                subviews.forEach { $0.removeFromSuperview() }
                addSubview(view)
            }
            view.frame.origin = NSPoint(x: -Self.side, y: -Self.top)
            clipsToBounds = true
        }

        private func view(for width: CGFloat) -> NSTextView? {
            guard let context, width > 0 else { return nil }
            if let rendered, rendered.width == width { return rendered.view }
            let view = PDFExport.renderView(
                text: AppearancePreview.sample, context: context, width: width + Self.side * 2,
                onScreen: drawnIn
            )
            rendered = (width, view)
            return view
        }
    }
}
