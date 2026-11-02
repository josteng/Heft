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

    /// Where Capture starts: wherever the last line went, or always one.
    enum CaptureStart: String, CaseIterable, Identifiable {
        case lastUsed, inbox, today
        var id: Self { self }
        var title: String {
            switch self {
            case .lastUsed: "Last Used"
            // The vault's own name for it is shown in Settings; this is the
            // name when there is no vault to ask.
            case .inbox: (InboxNotePreference.defaultPath as NSString).deletingPathExtension
            case .today: "Today's Note"
            }
        }
    }

    /// The lists that pulling down past the top can act on.
    enum PullPage: String, CaseIterable, Identifiable {
        case recent, files, search
        var id: Self { self }
        var title: String {
            switch self {
            case .recent: "Recent"
            case .files: "Files"
            case .search: "Search"
            }
        }
        /// What a list does when pulled, until chosen otherwise.
        var standard: String {
            switch self {
            case .recent: "capture"
            case .files: "newNote"
            case .search: PullChoice.off
            }
        }
        /// The command that would show the page it is pulled on, which as
        /// a pull would do nothing.
        var ownCommand: String? {
            switch self {
            case .recent: "showRecent"
            case .files: "showFiles"
            case .search: nil
            }
        }
    }

    /// The choices that are not commands.
    enum PullChoice {
        static let off = "off"
        static let search = "search"
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
    /// Whether going to the phone's Search tab brings the keyboard up. Off
    /// unless asked for: the list before typing is there to be tapped, and
    /// a tap on the tab while already there brings the keyboard anyway.
    /// What pulling each list down does: a command's id, "search", or
    /// "off". Stored per page.
    var pulls: [PullPage: String] {
        didSet {
            for page in PullPage.allCases {
                HeftDefaults.shared.set(pulls[page], forKey: Self.pullKey(page))
            }
        }
    }

    func pull(on page: PullPage) -> String { pulls[page] ?? page.standard }

    var captureStart: CaptureStart {
        didSet { HeftDefaults.shared.set(captureStart.rawValue, forKey: Self.captureStartKey) }
    }
    var searchShowsKeyboard: Bool {
        didSet { HeftDefaults.shared.set(searchShowsKeyboard, forKey: Self.searchKeyboardKey) }
    }

    private static let orderKey = "dev.stenglein.Heft.iOS.recentOrder"
    private static let layoutKey = "dev.stenglein.Heft.iOS.recentLayout"
    private static let startKey = "dev.stenglein.Heft.iOS.start"
    private static let panelShownKey = "dev.stenglein.Heft.iOS.notePanelShown"
    private static let panelKey = "dev.stenglein.Heft.iOS.notePanel"
    private static func pullKey(_ page: PullPage) -> String { "dev.stenglein.Heft.iOS.pull.\(page.rawValue)" }
    private static let captureStartKey = "dev.stenglein.Heft.iOS.captureStart"
    private static let searchKeyboardKey = "dev.stenglein.Heft.iOS.searchShowsKeyboard"

    private init() {
        let defaults = HeftDefaults.shared
        recentOrder = RecentOrder(rawValue: defaults.string(forKey: Self.orderKey) ?? "") ?? .edited
        recentLayout = RecentLayout(rawValue: defaults.string(forKey: Self.layoutKey) ?? "") ?? .preview
        start = Start(rawValue: defaults.string(forKey: Self.startKey) ?? "") ?? .recent
        showsNotePanel = defaults.bool(forKey: Self.panelShownKey)
        notePanel = NotePanel(rawValue: defaults.string(forKey: Self.panelKey) ?? "") ?? .outline
        pulls = Dictionary(uniqueKeysWithValues: PullPage.allCases.map {
            ($0, defaults.string(forKey: Self.pullKey($0)) ?? $0.standard)
        })
        captureStart = CaptureStart(rawValue: defaults.string(forKey: Self.captureStartKey) ?? "") ?? .lastUsed
        searchShowsKeyboard = defaults.object(forKey: Self.searchKeyboardKey) as? Bool ?? false
    }
}
