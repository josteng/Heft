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
                "Log this in \(.applicationName)",
            ],
            shortTitle: "Add to Today's Note",
            systemImageName: "calendar.badge.plus"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
