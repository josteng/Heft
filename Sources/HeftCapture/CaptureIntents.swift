import AppIntents
import Foundation
import HeftCore

/// One destination rather than a vault picker on every quick run: the vault
/// chosen in Settings ▸ Capture, or failing that the one opened last.
///
/// Read from the app's own preference domain, which the extension's
/// Info.plist names for `HeftDefaults`; its own domain would be empty.
private enum CaptureDestination {
    static var url: URL? { CaptureVaultPreference.url }
}

/// The two captures, and only these: anything that has to show a window
/// stays in the app, which is the process that has windows. `OpenIntents`
/// there is the other half.
struct CaptureToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Inbox"
    static let description = IntentDescription(
        "Adds a timestamped note to the inbox note of your most recently opened Heft vault."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Note",
        requestValueDialog: "What would you like to add to your Heft inbox?"
    )
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture to Inbox: \(\.$note)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vault = CaptureDestination.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        try InboxCapture(vaultRoot: vault).capture(note)
        return .result(dialog: "Added to Inbox in \(vault.lastPathComponent).")
    }
}

struct AddToTodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Today's Note"
    static let description = IntentDescription(
        "Appends a timestamped item to today's daily note in your most recently opened Heft vault."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Note",
        requestValueDialog: "What would you like to add to today's note?"
    )
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add to Today's Note: \(\.$note)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vault = CaptureDestination.url else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        let settings = ObsidianSettings.load(vaultRoot: vault)
        try DailyNoteCapture(vaultRoot: vault, settings: settings).capture(note)
        return .result(dialog: "Added to today's note in \(vault.lastPathComponent).")
    }
}

/// The Spotlight rows for the captures. Declared here rather than in the
/// app so that running one never has to launch the app: a provider names
/// only intents compiled into its own target.
struct HeftCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToInboxIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Add a note to \(.applicationName) Inbox",
            ],
            shortTitle: "Capture to Inbox",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: AddToTodaysNoteIntent(),
            phrases: [
                "Add to today's note in \(.applicationName)",
                "Add to my \(.applicationName) daily note",
                "Log this in \(.applicationName)",
            ],
            shortTitle: "Add to Today's Note",
            systemImageName: "calendar.badge.plus"
        )
        // The note is named in the phrase itself, so "add the milk to my
        // shopping note" resolves through `NoteEntityQuery` and asks nothing.
        AppShortcut(
            intent: AppendToNoteIntent(),
            phrases: [
                "Add to \(\.$note) in \(.applicationName)",
                "Add to my \(\.$note) note in \(.applicationName)",
                "Append to \(\.$note) in \(.applicationName)",
            ],
            shortTitle: "Add to a Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: TodaysNoteIntent(),
            phrases: [
                "Get today's note in \(.applicationName)",
                "Today's \(.applicationName) note",
            ],
            shortTitle: "Get Today's Note",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
                "Start a note in \(.applicationName)",
            ],
            shortTitle: "Create a Note",
            systemImageName: "doc.badge.plus"
        )
        // Last, because the extractor applies an availability branch to
        // every row after it, and the rows above must stay on macOS 26.
        // Without a phrase Siri never chose this one: asked what the notes
        // say about something, it queried its own index, found nothing of
        // Heft's, and answered so. A phrase cannot carry free text, so the
        // question comes as a second turn.
        if #available(macOS 27.0, *) {
            AppShortcut(
                intent: FindNotesIntent(),
                phrases: [
                    "Find notes in \(.applicationName)",
                    "Search my \(.applicationName) notes",
                    "Find a note in \(.applicationName)",
                    "What do my \(.applicationName) notes say",
                ],
                shortTitle: "Find Notes",
                systemImageName: "magnifyingglass"
            )
        }
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
