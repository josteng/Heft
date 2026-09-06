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
