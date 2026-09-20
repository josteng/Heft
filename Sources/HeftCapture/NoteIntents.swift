import AppIntents
import Foundation
import HeftCore

/// The two captures that take a note rather than assuming one.
///
/// Here rather than in the app for the same reason the inbox and daily
/// captures are: an intent declared in the app is run *by* the app, and macOS
/// activates it to do so. Adding a line should never take the screen, and
/// neither should being asked which note you meant.
///
/// Both only ever add. Nothing here rewrites a line already on disk, which is
/// what lets them run unattended while every other edit is a proposal.
struct AppendToNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to a Note"
    static let description = IntentDescription(
        "Appends a timestamped item to any note in your Heft vault.",
        categoryName: "Capture"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Note")
    var note: NoteEntity

    @Parameter(
        title: "Text",
        requestValueDialog: "What would you like to add?"
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$note)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vault = CaptureVaultPreference.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        try NoteAppend.append(text, to: note.id, in: vault)
        // Same reason as a note made by voice: this is the note you will want
        // next, and Quick Open should already know that.
        FrecencyStore.notes(forVaultAt: vault.path).record(note.id)
        return .result(dialog: "Added to \(note.name).")
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Note"
    static let description = IntentDescription(
        "Makes a new note in your Heft vault. A name already taken gets a numbered sibling rather than being replaced.",
        categoryName: "Capture"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Name",
        requestValueDialog: "What should the note be called?"
    )
    var name: String

    @Parameter(title: "Text")
    var text: String?

    /// Vault-relative, and it has to exist already. A misheard folder name
    /// that created one would scatter folders through the vault, and the
    /// failure is easier to correct than the mess.
    @Parameter(title: "Folder")
    var folder: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a note called \(\.$name)") {
            \.$text
            \.$folder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        guard let vault = CaptureVaultPreference.url else {
            throw NoteCreation.Failure.vaultUnavailable
        }
        let url = try NoteCreation.create(named: name, body: text, in: vault, folder: folder)
        guard let made = NoteRef(url: url, vaultRoot: vault) else {
            throw NoteCreation.Failure.unusableName(name)
        }
        let entity = NoteEntity(made)
        return .result(value: entity, dialog: "Created \(entity.name).")
    }
}

/// Handing back today's daily note, so it never has to be looked up.
///
/// Resolution by name is what fails: asked to add a line to "my daily note",
/// Siri searches its own semantic index, which is empty here because macOS 27
/// refuses Spotlight donations from third-party apps, and offers to create a
/// note called "daily note" instead. An intent that *returns* the note is not
/// a search at all, so the index is not in the way.
///
/// It creates today's note when there is none, from the vault's template, for
/// the same reason `AddToTodaysNoteIntent` does: the first line written on a
/// morning should not have to be preceded by making the file.
struct TodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Note"
    static let description = IntentDescription(
        "Answers with today's daily note, creating it from your template if it is not there yet.",
        categoryName: "Navigation"
    )
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> {
        guard let vault = CaptureVaultPreference.url else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        let settings = ObsidianSettings.load(vaultRoot: vault)
        let url = try DailyNotes(vaultRoot: vault, settings: settings).ensureNote(for: Date())
        guard let note = NoteRef(url: url, vaultRoot: vault) else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        return .result(value: NoteEntity(note))
    }
}

/// Answering "what do my notes say about X" without the vault being indexed.
///
/// macOS 27.0 refuses every third-party Spotlight donation, so Siri cannot
/// search the vault the way it searches Apple Notes, and the in-app search
/// schema only ever opens a window. This is the route that needs neither: an
/// intent that takes the question and returns the notes, which Siri lays out
/// as cards built from each note's display representation and can read the
/// content of. In the extension, because answering must not take the screen.
///
/// Returns the schema note rather than `NoteEntity`, so what Siri gets back
/// is the same kind of thing it creates and appends to, content included.
@available(macOS 27.0, *)
struct FindNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Notes"
    static let description = IntentDescription(
        "Finds the notes in your Heft vault that mention something, and answers with them.",
        categoryName: "Navigation"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Search for",
        requestValueDialog: "What should the notes mention?"
    )
    var query: String

    /// Ten is a screen of cards; past that the answer is a list to scroll.
    @Parameter(title: "Limit", default: 10)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find notes mentioning \(\.$query)") {
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[SiriNoteEntity]> & ProvidesDialog {
        guard let vault = CaptureVaultPreference.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        let index = VaultIndex.open(vaultAt: vault)
        let notes = NoteFinding.notes(matching: query, in: index, limit: max(1, limit))
            .map { SiriNoteEntity($0, in: vault) }
        let dialog: IntentDialog = notes.isEmpty
            ? "No note in Heft mentions \(query)."
            : "\(notes.count) notes mention \(query)."
        return .result(value: notes, dialog: dialog)
    }
}
