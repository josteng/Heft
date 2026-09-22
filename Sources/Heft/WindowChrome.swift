import SwiftUI

/// What the window's frame shows around the note: which columns are open and
/// whether the navigation buttons are live.
///
/// Its own object rather than properties on `AppModel`, and observed by
/// `WorkspaceSplit` alone. The split view's two toolbars are rebuilt whenever
/// the view that declares them re-renders, and rebuilding them leaks: every
/// pass left AppKit key-value dependencies behind, so a window grew slower
/// and larger with each publish on the model for as long as it stayed open.
/// Keeping the toolbars on a view that observes only this keeps those
/// rebuilds to the handful of times the chrome actually changes.
@MainActor
final class WindowChrome: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var isInspectorVisible = false
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canNavigateForward = false

    func updateNavigation(back: Bool, forward: Bool) {
        if back != canNavigateBack { canNavigateBack = back }
        if forward != canNavigateForward { canNavigateForward = forward }
    }
}

/// How wide the sidebar column is, for the scope picker above it.
///
/// A toolbar item is laid out at its ideal width and never squeezed: one
/// wider than the room between the traffic lights and the sidebar toggle is
/// moved to the overflow menu at the far end of the window, and the toggle
/// slides left into the gap. So the picker is capped to what is left and
/// truncates its name instead. Observed by the picker alone; `WorkspaceSplit`
/// writes it without observing it, or a drag would rebuild the toolbars.
@MainActor
final class SidebarColumn: ObservableObject {
    /// Wide enough for "All Notes" in full beside the window controls.
    static let minWidth: CGFloat = 260
    /// The traffic lights, the sidebar toggle and the margins around them,
    /// measured from the toolbar's accessibility frames.
    static let windowControlsWidth: CGFloat = 162

    @Published private(set) var width: CGFloat = 270

    var scopePickerWidth: CGFloat { max(0, width - Self.windowControlsWidth) }

    func update(width new: CGFloat) {
        if abs(new - width) > 0.5 { width = new }
    }
}
