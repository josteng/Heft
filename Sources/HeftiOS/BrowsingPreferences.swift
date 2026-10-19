import HeftCore
import Observation
import SwiftUI

/// How the library reads: Recent's order and rows, and where the app starts.
/// The first two are the Mac's own Appearance choices; this device's, as the
/// opening history behind "Last Opened" is.
@MainActor @Observable
final class BrowsingPreferences {
    static let shared = BrowsingPreferences()

    enum RecentOrder: String, CaseIterable, Identifiable {
        case edited, opened
        var id: Self { self }
        var title: String { self == .edited ? "Last Edited" : "Last Opened" }
    }

    enum RecentLayout: String, CaseIterable, Identifiable {
        case preview, compact
        var id: Self { self }
        var title: String { self == .preview ? "Preview" : "Compact" }
    }

    /// What the app shows when it opens: the Recent list, the files, or
    /// today's note, on the phone as its first tab, on the iPad beside the
    /// sidebar.
    enum Start: String, CaseIterable, Identifiable {
        case recent, files, today
        var id: Self { self }
        var title: String {
            switch self {
            case .recent: "Recent"
            case .files: "Files"
            case .today: "Today's Note"
            }
        }
    }

    /// What the iPad's panel beside a note shows, as the Mac's right sidebar.
    enum NotePanel: String, CaseIterable, Identifiable {
        case outline, backlinks
        var id: Self { self }
        var title: String { self == .outline ? "Outline" : "Linked From" }
        var symbol: String { self == .outline ? "list.bullet.indent" : "arrow.uturn.left" }
    }

    var recentOrder: RecentOrder {
        didSet { HeftDefaults.shared.set(recentOrder.rawValue, forKey: Self.orderKey) }
    }
    var recentLayout: RecentLayout {
        didSet { HeftDefaults.shared.set(recentLayout.rawValue, forKey: Self.layoutKey) }
    }
    var start: Start {
        didSet { HeftDefaults.shared.set(start.rawValue, forKey: Self.startKey) }
    }
    /// Whether the iPad shows the panel beside a note; it stays from note
    /// to note, and across launches, as the Mac's does in a window.
    var showsNotePanel: Bool {
        didSet { HeftDefaults.shared.set(showsNotePanel, forKey: Self.panelShownKey) }
    }
    var notePanel: NotePanel {
        didSet { HeftDefaults.shared.set(notePanel.rawValue, forKey: Self.panelKey) }
    }

    private static let orderKey = "dev.stenglein.Heft.iOS.recentOrder"
    private static let layoutKey = "dev.stenglein.Heft.iOS.recentLayout"
    private static let startKey = "dev.stenglein.Heft.iOS.start"
    private static let panelShownKey = "dev.stenglein.Heft.iOS.notePanelShown"
    private static let panelKey = "dev.stenglein.Heft.iOS.notePanel"

    private init() {
        let defaults = HeftDefaults.shared
        recentOrder = RecentOrder(rawValue: defaults.string(forKey: Self.orderKey) ?? "") ?? .edited
        recentLayout = RecentLayout(rawValue: defaults.string(forKey: Self.layoutKey) ?? "") ?? .preview
        start = Start(rawValue: defaults.string(forKey: Self.startKey) ?? "") ?? .recent
        showsNotePanel = defaults.bool(forKey: Self.panelShownKey)
        notePanel = NotePanel(rawValue: defaults.string(forKey: Self.panelKey) ?? "") ?? .outline
    }
}
