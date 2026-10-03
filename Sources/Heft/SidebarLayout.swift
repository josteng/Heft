import Foundation
import HeftCore

/// Which of the sidebar's views are shown, in what order, and which one a
/// window opens on.
///
/// A list like the attachment rules: each view switched on or off and
/// dragged into place, so a reader who never uses Tags can put it away and
/// one who lives in Recent can put it first. ⌘1 to ⌘3 follow the views
/// shown, in this order, and the switch above the list hides when one view
/// is all there is.
struct SidebarLayout: Equatable {
    struct Entry: Equatable, Identifiable {
        var mode: SidebarMode
        var isShown: Bool
        var id: SidebarMode { mode }
    }

    enum Start: Hashable, Identifiable {
        /// The first view shown, whatever was last used.
        case first
        /// The view last switched to, in any window, so a relaunch comes
        /// back where the reader was.
        case lastUsed
        /// Always this one, wherever it stands in the order.
        case view(SidebarMode)

        static var allCases: [Start] { [.first, .lastUsed] + SidebarMode.allCases.map(Start.view) }

        var id: String { rawValue }

        var title: String {
            switch self {
            case .first: "First view"
            case .lastUsed: "Last used"
            case .view(let mode): mode.title
            }
        }

        var rawValue: String {
            switch self {
            case .first: "first"
            case .lastUsed: "lastUsed"
            case .view(let mode): "view:\(mode.rawValue)"
            }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "first": self = .first
            case "lastUsed": self = .lastUsed
            default:
                guard rawValue.hasPrefix("view:"),
                      let mode = SidebarMode(rawValue: String(rawValue.dropFirst(5)))
                else { return nil }
                self = .view(mode)
            }
        }
    }

    var entries: [Entry]
    var start: Start

    static let standard = SidebarLayout(
        entries: SidebarMode.allCases.map { Entry(mode: $0, isShown: true) },
        start: .first
    )

    /// The views shown, in order; Files when everything was switched off,
    /// since a sidebar needs something in it.
    var visible: [SidebarMode] {
        let shown = entries.filter(\.isShown).map(\.mode)
        return shown.isEmpty ? [.files] : shown
    }

    /// Whether `mode` may be switched off: not the last view still shown,
    /// since a sidebar needs something in it.
    func canHide(_ mode: SidebarMode) -> Bool {
        entries.filter(\.isShown).contains { $0.mode != mode }
    }

    /// The view a window opens on.
    /// A view chosen or last used that is no longer shown gives way to the
    /// first that is.
    func initialMode(lastUsed: SidebarMode?) -> SidebarMode {
        switch start {
        case .first: return visible[0]
        case .lastUsed: return lastUsed.map(shown) ?? visible[0]
        case .view(let mode): return shown(mode)
        }
    }

    /// The view ⌘`number` goes to: the `number`th shown. None with one view
    /// shown, as there is nothing to switch to.
    func mode(forShortcut number: Int) -> SidebarMode? {
        guard visible.count > 1 else { return nil }
        return visible.indices.contains(number - 1) ? visible[number - 1] : nil
    }

    /// `mode` if it is shown, otherwise the first view that is: a view
    /// switched off while showing gives way.
    func shown(_ mode: SidebarMode) -> SidebarMode {
        visible.contains(mode) ? mode : visible[0]
    }

    // MARK: - Storage

    private static let orderKey = "dev.stenglein.Heft.sidebar.order"
    private static let hiddenKey = "dev.stenglein.Heft.sidebar.hidden"
    private static let startKey = "dev.stenglein.Heft.sidebar.start"
    static let lastUsedKey = "dev.stenglein.Heft.sidebar.lastUsed"

    static func current(in defaults: UserDefaults = HeftDefaults.shared) -> SidebarLayout {
        let stored = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(SidebarMode.init(rawValue:))
        var seen = Set<SidebarMode>()
        // A view added in a later version, unknown to the stored order, goes
        // at the end rather than missing.
        let order = (stored + SidebarMode.allCases).filter { seen.insert($0).inserted }
        let hidden = Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(SidebarMode.init(rawValue:)))
        return SidebarLayout(
            entries: order.map { Entry(mode: $0, isShown: !hidden.contains($0)) },
            start: defaults.string(forKey: startKey).flatMap(Start.init(rawValue:)) ?? .first
        )
    }

    func save(in defaults: UserDefaults = HeftDefaults.shared) {
        defaults.set(entries.map(\.mode.rawValue), forKey: Self.orderKey)
        defaults.set(entries.filter { !$0.isShown }.map(\.mode.rawValue), forKey: Self.hiddenKey)
        defaults.set(start.rawValue, forKey: Self.startKey)
    }

    static func lastUsed(in defaults: UserDefaults = HeftDefaults.shared) -> SidebarMode? {
        defaults.string(forKey: lastUsedKey).flatMap(SidebarMode.init(rawValue:))
    }

    static func recordLastUsed(_ mode: SidebarMode, in defaults: UserDefaults = HeftDefaults.shared) {
        defaults.set(mode.rawValue, forKey: lastUsedKey)
    }
}
