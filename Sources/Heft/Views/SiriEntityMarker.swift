import AppIntents
import AppKit
import SwiftUI

/// Names the note or folder a row is showing, on a real `NSView`.
///
/// SwiftUI has an `appEntityIdentifier` modifier of its own, and it keeps the
/// entity inside SwiftUI's tree: a hosted view was measured reporting no
/// `appEntityIdentifier` and no `appEntityUIElementProvider` to AppKit at
/// all, while a plain `NSView` takes one and keeps it. The Ask Siri item
/// macOS adds to a context menu is AppKit's, so with only the SwiftUI
/// annotation there was nothing for it to find, and every question asked
/// from a row was answered about whatever note was open instead.
///
/// Used as a background, so the view has the row's own bounds: what the
/// system is told is both which entity and where it is.
struct SiriEntityMarker: NSViewRepresentable {
    let identifier: EntityIdentifier?

    func makeNSView(context: Context) -> SiriMarkerView {
        let view = SiriMarkerView()
        view.entity = identifier
        SiriPointer.shared.register(view)
        return view
    }

    func updateNSView(_ view: SiriMarkerView, context: Context) {
        guard view.entity != identifier else { return }
        view.entity = identifier
        SiriPointer.shared.refresh(view)
    }
}

/// Knows the row's entity apart from what it is telling the system, which
/// is the entity or nothing while a right-click points elsewhere.
final class SiriMarkerView: NSView {
    var entity: EntityIdentifier?
}

extension View {
    /// The row carries its note on the AppKit view alone. SwiftUI's own
    /// annotation reaches the system too, measured as a second copy of
    /// every row, and a second copy is one the pointer cannot take away.
    @ViewBuilder
    func namesForSiri(_ identifier: EntityIdentifier?) -> some View {
        if let identifier {
            background { SiriEntityMarker(identifier: identifier) }
        } else {
            self
        }
    }
}

/// The row the pointer was on when a context menu was asked for.
///
/// Measured on macOS 27: the Ask Siri item in a context menu does not take
/// the entity of the view the menu was opened on. A question asked from an
/// annotated row, from the editor with nothing annotated under the pointer,
/// and from a window with no annotated view at all each reached Siri with
/// the same single identifier, which is not a note; what it answers about
/// is whichever of the annotated views it prefers, with the whole screen in
/// front of it. So while a question could follow a right-click, the row
/// under the pointer is the only annotated view there is, and the window's
/// user activity, the one channel that names a single primary item, names
/// it too. A left-click anywhere, or a minute, gives every row its name
/// back.
@MainActor
final class SiriPointer {
    static let shared = SiriPointer()

    private struct Marker { weak var view: SiriMarkerView? }
    private var markers: [Marker] = []
    private var monitor: Any?
    private(set) var pointed: EntityIdentifier?
    private weak var pointedWindow: NSWindow?
    private var activity: NSUserActivity?
    private var expiry: Task<Void, Never>?

    func register(_ view: SiriMarkerView) {
        markers.removeAll { $0.view == nil }
        markers.append(Marker(view: view))
        refresh(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            self?.noticed(event)
            return event
        }
    }

    /// What the view tells the system: its entity, or nothing while the
    /// pointer is on another row.
    func refresh(_ view: SiriMarkerView) {
        let told = pointed == nil || pointed == view.entity ? view.entity : nil
        if view.appEntityIdentifier != told { view.appEntityIdentifier = told }
    }

    private func noticed(_ event: NSEvent) {
        guard let window = event.window else { return }
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else {
            // A left-click in the window the pointer was set in, not the
            // click on the menu's own Ask Siri item, which arrives from the
            // menu's window.
            if pointed != nil, window === pointedWindow { point(at: nil, in: window) }
            return
        }
        let location = event.locationInWindow
        let hit = markers.compactMap(\.view)
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .filter { $0.convert($0.bounds, to: nil).contains(location) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        point(at: hit?.entity, in: window)
    }

    func point(at identifier: EntityIdentifier?, in window: NSWindow) {
        expiry?.cancel()
        activity?.resignCurrent()
        activity = nil
        window.userActivity = nil
        pointed = identifier
        pointedWindow = identifier == nil ? nil : window
        for view in markers.compactMap(\.view) { refresh(view) }
        guard let identifier else { return }
        let activity = NSUserActivity(activityType: "dev.stenglein.Heft.openNote")
        activity.appEntityIdentifier = identifier
        activity.becomeCurrent()
        window.userActivity = activity
        self.activity = activity
        expiry = Task { [weak self, weak window] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let window else { return }
            self?.point(at: nil, in: window)
        }
    }
}
