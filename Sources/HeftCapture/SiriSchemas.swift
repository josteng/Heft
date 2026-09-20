import AppIntents
import Foundation
import HeftCore
import UniformTypeIdentifiers

// The two Notes-schema intents Heft adopts, which is what lets Siri map a
// phrasing nobody registered onto a capture. macOS 27 only, like the
// entities they take, which live in `HeftCore` because the app has to be
// able to open what these create.
//
// Assistant-only, so neither appears in Shortcuts. The actions there are the
// plain ones, and a second "Create a Note" in the picker would only be a way
// to pick the wrong one.

// `notes.updateNote` is deliberately left alone: it rewrites a note in place,
// with no diff and no review, which is exactly what the proposal system
// exists to prevent. Creating and appending only ever add, so they can run
// unattended.

enum SiriSchemaError: LocalizedError {
    case attachmentsUnsupported

    var errorDescription: String? {
        "Heft cannot file attachments from Siri yet. Create the note without them, "
            + "then drag the file into it."
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .notes.createNote)
struct SiriCreateNoteIntent {
    static let isAssistantOnly = true

    @Parameter(title: "Name") var name: String
    @Parameter(title: "Content") var content: String?
    @Parameter(title: "Folder") var folder: SiriFolderEntity?
    /// Part of the schema and ignored: Heft has no pinning.
    @Parameter(title: "Pinned") var isPinned: Bool
    /// Part of the schema, and refused rather than dropped.
    ///
    /// Placing a file means resolving where attachments belong for this vault
    /// and linking it from the note, which `AttachmentDestination` already
    /// does for a paste. Until that is wired through, saying so is the only
    /// honest answer: silently losing a file somebody handed Siri is worse
    /// than failing in front of them.
    @Parameter(title: "Attachments", supportedContentTypes: [.item])
    var attachments: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<SiriNoteEntity> {
        guard let vault = CaptureVaultPreference.url else {
            throw NoteCreation.Failure.vaultUnavailable
        }
        guard attachments.isEmpty else { throw SiriSchemaError.attachmentsUnsupported }
        // A note dictated with no name still has to be called something, and
        // the day it was made is the one fact always available.
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = DailyNotes(
            vaultRoot: vault, settings: ObsidianSettings.load(vaultRoot: vault)
        ).stem(for: Date())
        let url = try NoteCreation.create(
            named: title.isEmpty ? fallback : title,
            body: content,
            in: vault,
            folder: folder?.id
        )
        guard let made = NoteRef(url: url, vaultRoot: vault) else {
            throw NoteCreation.Failure.unusableName(title.isEmpty ? fallback : title)
        }
        return .result(value: SiriNoteEntity(made, in: vault))
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .notes.appendText)
struct SiriAppendTextIntent {
    static let isAssistantOnly = true

    @Parameter(title: "Note") var target: SiriNoteEntity
    @Parameter(title: "Text") var content: String

    func perform() async throws -> some IntentResult & ReturnsValue<SiriNoteEntity> {
        guard let vault = CaptureVaultPreference.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        try NoteAppend.append(content, to: target.id, in: vault)
        FrecencyStore.notes(forVaultAt: vault.path).record(target.id)
        let index = VaultIndex.open(vaultAt: vault)
        guard let note = index.notes.first(where: { $0.relativePath == target.id }) else {
            return .result(value: target)
        }
        return .result(value: SiriNoteEntity(note, in: vault))
    }
}
