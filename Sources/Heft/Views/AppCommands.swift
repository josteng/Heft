import SwiftUI

struct AppCommandShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let display: String

    static let openToday = Self(
        key: "t", modifiers: [.command, .shift], display: "⇧⌘T"
    )
    static let toggleCalendar = Self(
        key: "d", modifiers: [.command, .shift], display: "⇧⌘D"
    )
}

/// One command owns all of its palette metadata and behaviour. Adding a
/// command is one entry in `registry`, rather than edits to parallel switches.
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let searchTerms: String
    let shortcut: AppCommandShortcut?
    private let enabled: @MainActor (AppModel) -> Bool
    private let action: @MainActor (AppModel) -> Void

    init(
        id: String,
        title: String,
        symbol: String,
        searchTerms: String,
        shortcut: AppCommandShortcut? = nil,
        enabled: @escaping @MainActor (AppModel) -> Bool = { _ in true },
        action: @escaping @MainActor (AppModel) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.searchTerms = searchTerms
        self.shortcut = shortcut
        self.enabled = enabled
        self.action = action
    }

    static let registry: [Self] = [
        Self(
            id: "startPresentation",
            title: "Start presentation",
            symbol: "play.rectangle",
            searchTerms: "slides present slideshow deck current note",
            enabled: { $0.current != nil },
            action: { $0.isPresentationPresented = true }
        ),
        Self(
            id: "openToday",
            title: "Open today's note",
            symbol: "calendar.badge.clock",
            searchTerms: "daily today note open",
            shortcut: .openToday,
            action: { $0.openDailyNote(for: Date()) }
        ),
        Self(
            id: "toggleColorfulEmphasis",
            title: "Toggle colorful formatting",
            symbol: "paintpalette",
            searchTerms: "heading bars bold italic color formatting appearance",
            action: { $0.isColorfulFormattingEnabled.toggle() }
        ),
        Self(
            id: "toggleCalendar",
            title: "Toggle calendar",
            symbol: "calendar",
            searchTerms: "calendar show hide toggle sidebar",
            shortcut: .toggleCalendar,
            action: { $0.isCalendarVisible.toggle() }
        ),
    ]

    @MainActor func isEnabled(on model: AppModel) -> Bool { enabled(model) }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(title) \(searchTerms)".localizedCaseInsensitiveContains(query)
    }

    @MainActor func perform(on model: AppModel) { action(model) }
}
