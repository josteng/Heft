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
    case renameUnsupported

    var errorDescription: String? {
        switch self {
        case .attachmentsUnsupported:
            "Heft cannot file attachments from Siri yet. Create the note without them, "
                + "then drag the file into it."
        case .renameUnsupported:
            "Heft cannot rename or move a note from Siri yet. Rename it in the sidebar."
        }
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

/// The schema's update, which proposes rather than writes.
///
/// Every other verb here only ever adds: a create makes a new note, an
/// append puts a line at the end, and neither can lose a line already
/// written. An update can, and nothing in the file would say so afterwards.
/// The right-click is consent to attempt the edit, not sight of the result,
/// and the moment Siri reaches for this verb is the moment the note is not
/// on screen, which is when it can be judged least.
///
/// So it lands in the review centre with the note's current text as its
/// base, which is a diff to read and one click to take or drop, and is what
/// the proposal system exists for. Writing Tools rewriting a selection needs
/// none of this: that suggestion is in front of you before you accept it.
@available(macOS 27.0, *)
@AppIntent(schema: .notes.updateNote)
struct SiriUpdateNoteIntent {
    static let isAssistantOnly = true

    @Parameter(title: "Note") var target: SiriNoteEntity
    @Parameter(title: "Content") var content: String?
    /// Part of the schema, and refused rather than dropped, for the reason
    /// `SiriCreateNoteIntent` refuses attachments. A rename moves the file
    /// every wikilink in the vault points at, which is `rename`'s whole job
    /// and needs its link rewriting; dropping the request silently would
    /// leave somebody believing a note had been renamed.
    @Parameter(title: "Name") var name: String?
    @Parameter(title: "Folder") var folder: SiriFolderEntity?
    /// Part of the schema and ignored: Heft has no pinning. Optional, unlike
    /// the create schema's, because an update names only what it changes.
    @Parameter(title: "Pinned") var isPinned: Bool?
    @Parameter(title: "Attachments", supportedContentTypes: [.item])
    var attachments: [IntentFile]?

    func perform() async throws -> some IntentResult & ReturnsValue<SiriNoteEntity>
        & ProvidesDialog
    {
        guard let vault = CaptureVaultPreference.url else {
            throw InboxCaptureError.vaultUnavailable
        }
        guard attachments?.isEmpty != false else {
            throw SiriSchemaError.attachmentsUnsupported
        }
        let renamed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard renamed.isEmpty || renamed == target.name, folder == nil else {
            throw SiriSchemaError.renameUnsupported
        }
        // Nothing to review when the rewrite is what is already there.
        guard let body = content,
              try NoteUpdate.propose(body, to: target.id, in: vault, agent: "Siri") != nil
        else {
            return .result(value: target, dialog: "\(target.name) is already like that.")
        }
        return .result(
            value: target,
            dialog: "I put that up for review in Heft rather than writing it."
        )
    }
}
