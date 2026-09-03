import AppKit
import Foundation

/// Keeps a capture from disturbing what the user is actually doing.
///
/// Filing a line into the inbox from Spotlight is meant to be invisible: you
/// are in another app, you type a thought, it lands in the vault, nothing
/// moves. `CaptureToInboxIntent` and `AddToTodaysNoteIntent` are declared
/// `.background` for exactly that reason, and it is not enough — a background
/// App Intent still runs *inside the app process*, and macOS brings that
/// process forward to run it. A minimized Heft therefore jumped out of the
/// Dock every time something was filed into it.
///
/// The honest fix is an App Intents extension, so the capture never enters
/// this process at all. That is a separate build target and a bigger change;
/// until then this puts back what the activation disturbed.
///
/// The state cannot be read when the intent starts, because by then the app
/// has already been brought forward and every window looks restored. So it is
/// recorded the last time the user themselves left: at `didResignActive`, the
/// windows that are miniaturized are the ones they chose to leave miniaturized.
@MainActor
final class IntentPresentation {
    static let shared = IntentPresentation()

    /// Windows the user had minimized when they last left the app.
    private var miniaturized: Set<ObjectIdentifier> = []
    /// Whether the app was in the background when they last left it. Always
    /// true once `didResignActive` has fired; false only before it ever has.
    private var wasInBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.shared.record() }
            }
        )
    }

    private func record() {
        miniaturized = Set(
            NSApp.windows.filter(\.isMiniaturized).map(ObjectIdentifier.init)
        )
        wasInBackground = true
    }

    /// Runs a capture and then puts the app back the way the user left it.
    ///
    /// The restore is deferred rather than immediate: the system's own
    /// activation can land after the intent's work finishes, and re-minimizing
    /// before it would simply be undone.
    static func preservingVisibility<T>(_ body: () throws -> T) rethrows -> T {
        let result = try body()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            shared.restore()
        }
        return result
    }

    private func restore() {
        // Never on first run: with no `didResignActive` yet there is nothing
        // the user has expressed a preference about, and minimizing a window
        // they just opened would be worse than the problem.
        guard wasInBackground else { return }

        // Deliberately only the minimized case. A Heft sitting unminimized
        // behind another app already stays put when something is captured
        // into it, so there is nothing to correct and no reason to risk
        // pushing a window the user is looking at behind another one.
        var restored = false
        for window in NSApp.windows
        where miniaturized.contains(ObjectIdentifier(window)) && !window.isMiniaturized {
            window.miniaturize(nil)
            restored = true
        }
        if restored, NSApp.isActive { NSApp.deactivate() }
    }

    /// Starts watching. Called at launch, because the state this records is
    /// gone by the time an intent could ask for it.
    static func begin() { _ = shared }
}
