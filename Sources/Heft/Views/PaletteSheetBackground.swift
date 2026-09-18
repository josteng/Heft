import AppKit
import SwiftUI

/// The blurred backdrop behind Quick Open, the command palette and workspace
/// search, through which the note underneath shows.
///
/// A sheet is a window of its own, so anything drawn *inside* it has nothing
/// to sample: `.regularMaterial`, `presentationBackground` and `glassEffect`
/// all render opaque there, whatever is behind the window. Only
/// `.behindWindow` blending reaches the note, and only once the sheet's window
/// stops being opaque.
///
/// The material is the HUD window's. The semantic one for this surface is
/// `.sheet`, which is deliberately opaque, so this trades the semantic match
/// for the translucency a palette wants. A panel would earn the HUD material
/// honestly, but it would also give up the sheet's drop-down animation.
/// How big each palette is.
///
/// Quick Open and the command palette are the same control wearing two icons:
/// a filter field over one-line rows, dismissed by picking one. They are
/// opened in turn often enough that a frame changing size between them reads
/// as the window jumping, so they share a size and it lives here rather than
/// as a number in each view, which is how the two drifted apart.
///
/// Workspace search keeps its own, larger size on purpose: its rows are two
/// lines and carry the matched line, which needs the width to be worth
/// showing.
enum PaletteMetrics {
    static let pickerWidth: CGFloat = 560
    static let pickerListHeight: CGFloat = 320

    static let searchWidth: CGFloat = 680
    static let searchListHeight: CGFloat = 420
}

struct PaletteSheetBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Once per presentation: the sheet arrives opaque, and its corners are
        // rounded by AppKit, which only shows through a clear background.
        guard let window = view.window, window.isOpaque else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
