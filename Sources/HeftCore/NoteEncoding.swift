import Foundation

/// The encoding a note's file is read in and written back in.
///
/// UTF-8, or Latin-1 for a file that is not valid UTF-8, as an old editor
/// leaves `é` as the lone byte E9. Latin-1 gives every byte a character of its
/// own, so the text written back is the file byte for byte; the editor read
/// such a note as Latin-1 and saved it as UTF-8, which rewrote every byte
/// above 127. VS Code keeps a file's encoding the same way, by looking at the
/// file it replaces, as `ByteOrderMark` does for the mark.
public enum NoteEncoding {

    /// The note's text, for an editor that writes it back. Nil when the file
    /// cannot be read.
    public static func read(_ url: URL) -> String? {
        // Strict first, which also drops a byte-order mark.
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    /// `text` as the bytes to replace the file at `url` with: Latin-1 when
    /// that file is not UTF-8, otherwise UTF-8 with the mark the file has.
    public static func data(_ text: String, replacing url: URL) throws -> Data {
        guard let existing = try? Data(contentsOf: url), !existing.isEmpty,
              String(data: existing, encoding: .utf8) == nil
        else { return ByteOrderMark.data(text, replacing: url) }
        guard let latin1 = text.data(using: .isoLatin1) else {
            throw NotRepresentable(
                note: url.deletingPathExtension().lastPathComponent,
                character: text.first { String($0).data(using: .isoLatin1) == nil } ?? "?"
            )
        }
        return latin1
    }

    /// A character typed into a Latin-1 note that Latin-1 has no byte for.
    /// Refused rather than converting the whole file to UTF-8 unasked.
    public struct NotRepresentable: LocalizedError, Equatable {
        public let note: String
        public let character: Character

        public var errorDescription: String? {
            "\(note) is a Latin-1 file, which has no “\(character)”. Remove it to save, "
                + "or convert the note to UTF-8 in another editor."
        }
    }
}
