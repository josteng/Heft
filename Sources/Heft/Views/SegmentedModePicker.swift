import AppKit
import SwiftUI

/// The sidebar's Files / Recent / Tags switch, as AppKit draws it.
///
/// Wrapping `NSSegmentedControl` rather than styling a `Picker`: the picker
/// styles draw either an icon or a label per segment, never both, and the
/// labels are load-bearing because "Recent" and "Tags" are not guessable from
/// a clock and a hash. Everything else here is AppKit's, including the one
/// thing no reimplementation had: the selection follows a drag across the
/// segments, the way it does in Calendar.
struct SegmentedModePicker: NSViewRepresentable {
    @Binding var mode: SidebarMode
    @Binding var filter: String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = SidebarMode.allCases.count
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.controlSize = .small
        for (index, option) in SidebarMode.allCases.enumerated() {
            control.setLabel(option.title, forSegment: index)
            control.setImage(
                NSImage(systemSymbolName: option.symbol, accessibilityDescription: option.title),
                forSegment: index
            )
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        // The sidebar gives it the width; without this it keeps its fitting
        // size and the segments stop short of the field below.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let index = SidebarMode.allCases.firstIndex(of: mode) ?? 0
        // Only when it differs: assigning during a drag would fight AppKit
        // for the selection it is animating.
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SegmentedModePicker

        init(_ parent: SegmentedModePicker) { self.parent = parent }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let options = SidebarMode.allCases
            guard options.indices.contains(sender.selectedSegment) else { return }
            let chosen = options[sender.selectedSegment]
            guard chosen != parent.mode else { return }
            // Cleared for the same reason the old picker cleared it: the field
            // below filters whatever list is showing, and carrying a query
            // across a switch hides most of the new list for no stated reason.
            parent.filter = ""
            parent.mode = chosen
        }
    }
}
