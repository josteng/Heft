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
    static let toggleSidebar = Self(
        key: "s", modifiers: [.command, .shift], display: "⇧⌘S"
    )
    static let toggleBacklinks = Self(
        key: "b", modifiers: [.command, .option], display: "⌥⌘B"
    )
    static let captureInbox = Self(
        key: "i", modifiers: [.command, .shift], display: "⇧⌘I"
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
    private let displayTitle: @MainActor (AppModel) -> String
    private let enabled: @MainActor (AppModel) -> Bool
    private let action: @MainActor (AppModel) -> Void

    init(
        id: String,
        title: String,
        symbol: String,
        searchTerms: String,
        shortcut: AppCommandShortcut? = nil,
        displayTitle: (@MainActor (AppModel) -> String)? = nil,
        enabled: @escaping @MainActor (AppModel) -> Bool = { _ in true },
        action: @escaping @MainActor (AppModel) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.searchTerms = searchTerms
        self.shortcut = shortcut
        self.displayTitle = displayTitle ?? { _ in title }
        self.enabled = enabled
        self.action = action
    }

    static let registry: [Self] = [
        Self(
            id: "captureInbox",
            title: "Capture to Inbox…",
            symbol: "tray.and.arrow.down",
            searchTerms: "quick note add jot remember thought inbox",
            shortcut: .captureInbox,
            enabled: { $0.vaultRoot != nil },
            action: { $0.presentInboxCapture() }
        ),
        Self(
            id: "reviewProposals",
            title: "Review agent proposals",
            symbol: "sparkles",
            searchTerms: "agent claude ai proposal review diff changes pending accept",
            displayTitle: { model in
                let count = model.proposals.count
                return count == 0
                    ? "Review agent proposals"
                    : "Review agent proposals (\(count))"
            },
            enabled: { !$0.proposals.isEmpty },
            action: { model in
                // The one for the open note if there is one, since that is
                // what the reviewer is already looking at.
                let next = model.proposalsForCurrentNote.first ?? model.proposals.first
                if let next { model.openAndReview(next) }
            }
        ),
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
            enabled: { $0.dailyNotesAreInScope },
            action: { $0.openDailyNote(for: Date()) }
        ),
        Self(
            id: "dailyNoteSettings",
            title: "Daily note settings",
            symbol: "gearshape",
            searchTerms: "calendar daily template folder format configure preferences",
            enabled: { $0.vaultRoot != nil },
            action: { $0.presentDailyNotesSettings() }
        ),
        Self(
            id: "toggleSidebar",
            title: "Toggle sidebar",
            symbol: "sidebar.leading",
            searchTerms: "sidebar navigator files show hide open close view",
            shortcut: .toggleSidebar,
            displayTitle: { $0.columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar" },
            action: { $0.toggleSidebar() }
        ),
        Self(
            id: "toggleColorfulEmphasis",
            title: "Toggle colorful formatting",
            symbol: "paintpalette",
            searchTerms: "heading bars bold italic color formatting appearance",
            displayTitle: { _ in AppearanceSettings.shared.colorfulFormattingEnabled
                ? "Turn off colorful formatting"
                : "Turn on colorful formatting" },
            action: { _ in AppearanceSettings.shared.colorfulFormattingEnabled.toggle() }
        ),
        Self(
            id: "toggleCalendar",
            title: "Toggle calendar",
            symbol: "calendar",
            searchTerms: "calendar show hide toggle sidebar",
            shortcut: .toggleCalendar,
            displayTitle: { $0.isCalendarVisible ? "Hide calendar" : "Show calendar" },
            action: { $0.isCalendarVisible.toggle() }
        ),
        Self(
            id: "toggleBacklinks",
            title: "Toggle backlinks",
            symbol: "link",
            searchTerms: "backlinks inspector panel show hide open close view",
            shortcut: .toggleBacklinks,
            displayTitle: { $0.isInspectorVisible ? "Hide backlinks" : "Show backlinks" },
            action: { $0.isInspectorVisible.toggle() }
        ),
    ]

    @MainActor func isEnabled(on model: AppModel) -> Bool { enabled(model) }
    @MainActor func title(on model: AppModel) -> String { displayTitle(model) }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(title) \(searchTerms)".localizedCaseInsensitiveContains(query)
    }

    @MainActor func perform(on model: AppModel) { action(model) }
}

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var results: [AppCommand] {
        AppCommand.registry.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right.2")
                    .foregroundStyle(.secondary)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit(runSelection)
                    .onChange(of: query) { selection = 0 }
                PaletteDismissButton(query: $query) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        CommandRow(
                            command: command,
                            title: command.title(on: model),
                            isSelected: index == selection,
                            isEnabled: command.isEnabled(on: model)
                        )
                            .onTapGesture {
                                selection = index
                                runSelection()
                            }
                    }
                }
                .padding(6)
            }
            .id(query)
            .frame(height: 240)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func runSelection() {
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        guard command.isEnabled(on: model) else { return }
        command.perform(on: model)
        dismiss()
    }
}

private struct CommandRow: View {
    @Environment(\.appAccent) private var accent

    let command: AppCommand
    let title: String
    let isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: command.symbol)
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(.white.opacity(0.75))
                            : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(.rect)
    }
}
