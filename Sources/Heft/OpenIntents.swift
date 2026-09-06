import AppIntents
import Foundation
import HeftCore

/// One destination rather than a vault picker on every quick run: the vault
/// chosen in Settings ▸ Capture, or failing that the one opened last.
private enum IntentVaultDestination {
    static var url: URL? { CaptureVaultPreference.url }
}

/// The intents that need a window, and only those. The captures live in the
/// `HeftCapture` extension so that filing a line from Spotlight never
/// enters, launches or activates this process; an intent that has to show
/// a note has no such choice, since the windows are here.
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
        "Opens the inbox note of your most recently opened Heft vault."
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

/// A provider names only intents compiled into its own target, so the
/// captures' rows are declared beside them in the extension.
struct HeftAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
