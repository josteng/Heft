import AppIntents
import Foundation

/// What the system is told about the note or folder a view is showing.
///
/// macOS 27 puts Ask Siri into every context menu, an app's own rows
/// included, and there is no way to take it back out: an app's only choice is
/// whether the question arrives with anything attached. Annotating the view
/// under the pointer with an entity identifier is how that is done, and it is
/// the same annotation Siri reads to answer "this note" in a conversation.
///
/// An identifier here is a vault-relative path, and the queries that resolve
/// one read the capture vault, so a window onto any other vault annotates
/// nothing: one path in two vaults names two different notes, and handing
/// Siri the wrong note is worse than handing it none.
public enum SiriContext {
    public static func note(
        _ relativePath: String, in vault: URL?, capture: URL? = CaptureVaultPreference.url
    ) -> EntityIdentifier? {
        resolves(vault, capture: capture) ? note(relativePath) : nil
    }

    /// For a caller that has already asked `resolves` about its vault, which
    /// is what a list of rows does once rather than once a row.
    ///
    /// The schema note where there is one: it carries the body, so a question
    /// about what is *in* the note has something to read, and its verbs are
    /// the ones a phrasing about a note maps onto. `NoteEntity` knows a name
    /// and a folder, which answers where a note is and nothing else.
    public static func note(_ relativePath: String) -> EntityIdentifier {
        if #available(macOS 27.0, *) {
            return EntityIdentifier(for: SiriNoteEntity.self, identifier: relativePath)
        }
        return EntityIdentifier(for: NoteEntity.self, identifier: relativePath)
    }

    /// The vault root itself is a folder too, and its path is the empty
    /// string, which is what `SiriFolderEntity` calls the vault.
    @available(macOS 27.0, *)
    public static func folder(
        _ relativePath: String, in vault: URL?, capture: URL? = CaptureVaultPreference.url
    ) -> EntityIdentifier? {
        resolves(vault, capture: capture) ? folder(relativePath) : nil
    }

    @available(macOS 27.0, *)
    public static func folder(_ relativePath: String) -> EntityIdentifier {
        EntityIdentifier(for: SiriFolderEntity.self, identifier: relativePath)
    }

    /// Whether a path from this vault is one the entity queries would look up.
    public static func resolves(
        _ vault: URL?, capture: URL? = CaptureVaultPreference.url
    ) -> Bool {
        guard let vault, let capture else { return false }
        return vault.standardizedFileURL.path == capture.standardizedFileURL.path
    }
}
