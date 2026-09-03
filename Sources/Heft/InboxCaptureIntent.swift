import AppIntents
import Foundation
import HeftCore

/// Spotlight actions intentionally have one implicit destination for now. Once
/// Heft persists multiple known vaults, this should become an explicit default
/// Inbox/daily-note vault setting rather than a picker added to every quick run.
private enum IntentVaultDestination {
    static var url: URL? { CaptureVaultPreference.url }
}

struct CaptureToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Inbox"
    static let description = IntentDescription(
        "Adds a timestamped note to Inbox.md in your most recently opened Heft vault."
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
        guard let vault = IntentVaultDestination.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        _ = try await MainActor.run {
            try IntentPresentation.preservingVisibility {
                try InboxCapture(vaultRoot: vault).capture(note)
            }
        }
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
        guard let vault = IntentVaultDestination.url else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        let settings = ObsidianSettings.load(vaultRoot: vault)
        try await MainActor.run {
            _ = try IntentPresentation.preservingVisibility {
                try DailyNoteCapture(vaultRoot: vault, settings: settings).capture(note)
            }
        }
        return .result(dialog: "Added to today's note in \(vault.lastPathComponent).")
    }
}

struct OpenTodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today's Note"
    static let description = IntentDescription(
        "Creates today's daily note from its template when needed, then opens it in Heft."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        guard let vault = IntentVaultDestination.url else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        let settings = ObsidianSettings.load(vaultRoot: vault)
        let url = try DailyNotes(vaultRoot: vault, settings: settings).ensureNote(for: Date())
        VaultContentChangeNotification.post(for: vault)
        await MainActor.run {
            IntentNavigation.shared.open(url, in: vault)
        }
        return .result()
    }
}

struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inbox"
    static let description = IntentDescription(
        "Opens Inbox.md in your most recently opened Heft vault."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        guard let vault = IntentVaultDestination.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        let url = try InboxCapture(vaultRoot: vault).ensureFile()
        await MainActor.run {
            IntentNavigation.shared.open(url, in: vault)
        }
        return .result()
    }
}

struct HeftAppShortcuts: AppShortcutsProvider {
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
            intent: OpenTodaysNoteIntent(),
            phrases: [
                "Open today's note in \(.applicationName)",
                "Open my \(.applicationName) daily note",
            ],
            shortTitle: "Open Today's Note",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: OpenInboxIntent(),
            phrases: [
                "Open \(.applicationName) Inbox",
            ],
            shortTitle: "Open Inbox",
            systemImageName: "tray.full"
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
