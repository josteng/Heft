import AppKit
import HeftCore

/// The open note, offered to the reader's other devices: the phone shows it
/// in its app switcher, and a note opened there shows in the Dock here.
///
/// The activity is kept and made current by hand rather than handed to the
/// window as its `userActivity`. Siri's pointer uses that slot for the row
/// under the pointer, and a responder-managed activity is the system's to
/// refresh, which would mean filling its `userInfo` in again on request.
@MainActor
enum MacHandoff {
    private static let offered = NSMapTable<NSWindow, NSUserActivity>.weakToStrongObjects()
    private static var watching = false

    /// What `window` shows now, or nothing.
    static func offer(_ note: NoteRef?, in vaultRoot: URL?, on window: NSWindow) {
        watchKeyWindows()
        offered.object(forKey: window)?.invalidate()
        offered.removeObject(forKey: window)
        guard let note, let vaultRoot else { return }
        let activity = NSUserActivity(activityType: HandoffNote.activityType)
        activity.title = note.name
        activity.isEligibleForHandoff = true
        activity.addUserInfoEntries(from: HandoffNote(
            path: note.relativePath, vault: vaultRoot.lastPathComponent
        ).userInfo)
        offered.setObject(activity, forKey: window)
        if window.isKeyWindow { activity.becomeCurrent() }
    }

    /// Makes the window's note current again, after Siri's pointer let go.
    static func resume(on window: NSWindow) {
        guard window.isKeyWindow else { return }
        offered.object(forKey: window)?.becomeCurrent()
    }

    /// Only one activity is current at a time, so the key window's wins.
    private static func watchKeyWindows() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { offered.object(forKey: window)?.becomeCurrent() }
        }
    }
}
