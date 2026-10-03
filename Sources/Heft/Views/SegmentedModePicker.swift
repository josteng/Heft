import AppKit
import SwiftUI

/// A side's switch between its views, Files / Recent / Tags on the left and
/// Backlinks / Chats on the right, as AppKit draws it.
///
/// Wrapping `NSSegmentedControl` rather than styling a `Picker`: the picker
/// styles draw either an icon or a label per segment, never both, and the
/// labels are load-bearing because "Recent" and "Tags" are not guessable from
/// a clock and a hash. Everything else here is AppKit's, including the one
/// thing no reimplementation had: the selection follows a drag across the
/// segments, the way it does in Calendar.
struct SegmentedModePicker<Mode: PanelMode>: NSViewRepresentable {
    @Binding var mode: Mode
    /// The field under the left side's switch, cleared on a switch.
    var filter: Binding<String>? = nil
    /// The views shown, in the reader's order.
    var modes: [Mode]
    /// Every segment as wide as the widest, as Calendar's are, rather than
    /// each as wide as its label. The right side's two fit even at its
    /// narrowest (200pt of 200); the left's three would need 254 of 240,
    /// and look near enough equal as they are.
    var hasEqualSegments = false

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.controlSize = .small
        // The Tahoe appearance, not the old bezel: `.automatic` and
        // `.valueSelection` both rule a divider between the segments and
        // square the ends, which is what made this read as a control from
        // an older system. `.tabs` in a capsule is what Calendar's
        // Day/Week/Month/Year is.
        control.borderShape = .capsule
        if #available(macOS 27.0, *) {
            control.role = .tabs
        } else {
            // 26 has no tabs role, and there a `selectOne` control fills the
            // selected segment with the accent colour: a blue pill, brighter
            // than anything else in the sidebar. Naming the bezel colour is
            // what turns it neutral, which is the one thing 26 and 27 then
            // agree on. Checked in a 26.6 VM, since the SDK here only draws
            // the 27 appearance.
            control.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        }
        Self.configure(control, for: modes)
        context.coordinator.modes = modes
        // AppKit draws the track for a toolbar, where the surface behind it is
        // lighter than this sidebar, so at full strength it is the brightest
        // thing here and louder than the filter field below it. There is no
        // API for the track's fill, and the vibrant appearances leave it
        // alone, so the only lever is the whole control's opacity.
        control.alphaValue = 0.85
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        // The sidebar gives it the width; without this it keeps its fitting
        // size and the segments stop short of the field below.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if hasEqualSegments { control.segmentDistribution = .fillEqually }
        return control
    }

    /// One segment per view shown, rebuilt when the reader changes which.
    private static func configure(_ control: NSSegmentedControl, for modes: [Mode]) {
        control.segmentCount = modes.count
        for (index, option) in modes.enumerated() {
            control.setLabel(option.title, forSegment: index)
            control.setImage(
                NSImage(systemSymbolName: option.symbol, accessibilityDescription: option.title),
                forSegment: index
            )
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.modes != modes {
            context.coordinator.modes = modes
            Self.configure(control, for: modes)
        }
        // None selected when the view showing is one switched off, as the
        // file tree is while a note created with ⌘N is named in it.
        let index = modes.firstIndex(of: mode) ?? -1
        // Only when it differs: assigning during a drag would fight AppKit
        // for the selection it is animating.
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SegmentedModePicker
        var modes: [Mode] = []

        init(_ parent: SegmentedModePicker) { self.parent = parent }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let options = modes
            guard options.indices.contains(sender.selectedSegment) else { return }
            let chosen = options[sender.selectedSegment]
            guard chosen != parent.mode else { return }
            // Cleared for the same reason the old picker cleared it: the field
            // below filters whatever list is showing, and carrying a query
            // across a switch hides most of the new list for no stated reason.
            parent.filter?.wrappedValue = ""
            parent.mode = chosen
        }
    }
}

