import Foundation
import HeftCore

/// One of the views a side of the window switches between.
protocol PanelMode: Hashable, CaseIterable, Identifiable, RawRepresentable<String> {
    var title: String { get }
    var symbol: String { get }
    /// Which side's preferences these are, in their keys: `sidebar` for the
    /// left, whose keys are older than there being a right.
    static var storageName: String { get }
}

/// The left side's views: where things are.
typealias SidebarLayout = PanelLayout<SidebarMode>
/// The right side's views: about the open note.
typealias InspectorLayout = PanelLayout<InspectorMode>

/// Which of a side's views are shown, in what order, and which one a window
/// opens on.
///
/// A list like the attachment rules: each view switched on or off and
/// dragged into place, so a reader who never uses Tags can put it away and
/// one who lives in Recent can put it first. ⌘1 to ⌘3 follow the left
/// side's views shown, in this order, ⌥⌘1 and ⌥⌘2 the right side's, and the
/// switch above either hides when one view is all there is.
struct PanelLayout<Mode: PanelMode>: Equatable {
    struct Entry: Equatable, Identifiable {
        var mode: Mode
        var isShown: Bool
        var id: Mode { mode }
    }

    enum Start: Hashable, Identifiable {
        /// The first view shown, whatever was last used.
        case first
        /// The view last switched to, in any window, so a relaunch comes
        /// back where the reader was.
        case lastUsed
        /// Always this one, wherever it stands in the order.
        case view(Mode)

        static var allCases: [Start] { [.first, .lastUsed] + Mode.allCases.map(Start.view) }

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
                      let mode = Mode(rawValue: String(rawValue.dropFirst(5)))
                else { return nil }
                self = .view(mode)
            }
        }
    }

    var entries: [Entry]
    var start: Start

    static var standard: Self {
        Self(entries: Mode.allCases.map { Entry(mode: $0, isShown: true) }, start: .first)
    }

    /// The views shown, in order; the first there is when everything was
    /// switched off, since a side needs something in it.
    var visible: [Mode] {
        let shown = entries.filter(\.isShown).map(\.mode)
        return shown.isEmpty ? [Mode.allCases.first!] : shown
    }

    /// Whether `mode` may be switched off: not the last view still shown,
    /// since a side needs something in it.
    func canHide(_ mode: Mode) -> Bool {
        entries.filter(\.isShown).contains { $0.mode != mode }
    }

    /// The view a window opens on.
    /// A view chosen or last used that is no longer shown gives way to the
    /// first that is.
    func initialMode(lastUsed: Mode?) -> Mode {
        switch start {
        case .first: return visible[0]
        case .lastUsed: return lastUsed.map(shown) ?? visible[0]
        case .view(let mode): return shown(mode)
        }
    }

    /// The view the `number`th shortcut goes to: the `number`th shown. None
    /// with one view shown, as there is nothing to switch to.
    func mode(forShortcut number: Int) -> Mode? {
        guard visible.count > 1 else { return nil }
        return visible.indices.contains(number - 1) ? visible[number - 1] : nil
    }

    /// `mode` if it is shown, otherwise the first view that is: a view
    /// switched off while showing gives way.
    func shown(_ mode: Mode) -> Mode {
        visible.contains(mode) ? mode : visible[0]
    }

    // MARK: - Storage

    private static var orderKey: String { "dev.stenglein.Heft.\(Mode.storageName).order" }
    private static var hiddenKey: String { "dev.stenglein.Heft.\(Mode.storageName).hidden" }
    private static var startKey: String { "dev.stenglein.Heft.\(Mode.storageName).start" }
    static var lastUsedKey: String { "dev.stenglein.Heft.\(Mode.storageName).lastUsed" }

    static func current(in defaults: UserDefaults = HeftDefaults.shared) -> Self {
        let stored = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(Mode.init(rawValue:))
        var seen = Set<Mode>()
        // A view added in a later version, unknown to the stored order, goes
        // at the end rather than missing.
        let order = (stored + Mode.allCases).filter { seen.insert($0).inserted }
        let hidden = Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(Mode.init(rawValue:)))
        return Self(
            entries: order.map { Entry(mode: $0, isShown: !hidden.contains($0)) },
            start: defaults.string(forKey: startKey).flatMap(Start.init(rawValue:)) ?? .first
        )
    }

    func save(in defaults: UserDefaults = HeftDefaults.shared) {
        defaults.set(entries.map(\.mode.rawValue), forKey: Self.orderKey)
        defaults.set(entries.filter { !$0.isShown }.map(\.mode.rawValue), forKey: Self.hiddenKey)
        defaults.set(start.rawValue, forKey: Self.startKey)
    }

    static func lastUsed(in defaults: UserDefaults = HeftDefaults.shared) -> Mode? {
        defaults.string(forKey: lastUsedKey).flatMap(Mode.init(rawValue:))
    }

    static func recordLastUsed(_ mode: Mode, in defaults: UserDefaults = HeftDefaults.shared) {
        defaults.set(mode.rawValue, forKey: lastUsedKey)
    }
}
