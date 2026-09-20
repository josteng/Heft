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

/// Opening a named note, which is the one thing an entity buys that a fixed
/// phrase cannot: "open my roof note" names a note rather than a verb.
///
/// Foreground, unlike everything in the extension. Showing a note is the
/// request, so activating the app is not a side effect here, it is the point.
/// `OpenIntent`, not a plain one, which is what makes a note openable from
/// somewhere other than Shortcuts.
///
/// Apple's guidance is explicit: "For each `AppEntity` type that you define
/// and donate to Spotlight, create an `OpenIntent` type that opens that entity
/// in your app." That is how a result Siri or Spotlight shows becomes
/// something you can click, and it is why clicking one only ever launched
/// Heft: there was no intent to say what to open.
///
/// The parameter has to be called `target`; the protocol requires it.
struct OpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a Note"
    static let description = IntentDescription(
        "Opens a note from your Heft vault in a window.",
        categoryName: "Navigation"
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Note", requestValueDialog: "Which note?")
    var target: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        guard let vault = IntentVaultDestination.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        let url = target.url(in: vault)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InboxCaptureError.vaultUnavailable
        }
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
        // The note is spoken as part of the phrase, so the system resolves it
        // through `NoteEntityQuery` before the intent runs and asks only when
        // the name matches more than one note.
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open my \(\.$target) note in \(.applicationName)",
                "Show me \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open a Note",
            systemImageName: "doc.text"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}

/// Opening the note Siri is holding, which is what makes a result card a
/// link.
///
/// Siri's note is `SiriNoteEntity`, not `NoteEntity`: the one it creates
/// or finds through the Notes schema is that type, and an `OpenIntent` opens
/// only entities of its own target type. This is the app's half of Apple's
/// rule that every entity handed to the system gets an intent to open it;
/// `OpenNoteIntent` above is the same thing for Shortcuts' note. Adopted
/// through the system schema so Siri knows it as "open", the way Bear
/// declares its own.
///
/// Assistant-only: Shortcuts already has "Open a Note", and this one would
/// be the same row over a note type its picker never shows.
///
/// There is deliberately no `.system.searchInApp` beside it. Declared, that
/// schema took every Siri request that named Heft, "open my thesis note"
/// and "what do my notes say about the thesis" included, opened the search
/// window, and left Siri on "looking over results" until it gave up; the
/// open and find intents were never reached. `FindNotesIntent` answers a
/// search without a window, which is what was wanted of Siri anyway.
@available(macOS 27.0, *)
@AppIntent(schema: .system.open)
struct SiriOpenNoteIntent {
    static let isAssistantOnly = true
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Note")
    var target: SiriNoteEntity

    func perform() async throws -> some IntentResult {
        guard let vault = IntentVaultDestination.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        let url = target.url(in: vault)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InboxCaptureError.vaultUnavailable
        }
        await MainActor.run {
            IntentNavigation.shared.open(url, in: vault)
        }
        return .result()
    }
}
