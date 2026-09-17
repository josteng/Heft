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
