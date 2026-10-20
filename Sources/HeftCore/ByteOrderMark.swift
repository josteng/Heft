import Foundation

/// The UTF-8 byte-order mark, which a note keeps exactly when its file has one.
///
/// It is the file's encoding, not its text: Foundation's UTF-8 read drops it,
/// and Obsidian strips it too, so frontmatter, the first heading and every
/// offset read the note without it. Writing the text back put the rest of the
/// file back and lost the mark; VS Code keeps "UTF-8 with BOM" the same way
/// this does, by looking at the file it replaces. Never added to a file
/// without one, so a note Heft creates has none.
public enum ByteOrderMark {
    public static let bytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Whether the file at `url` starts with the mark. False when unreadable.
    public static func isPresent(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes.count)).map(Array.init) == bytes
    }

    /// `text` as the bytes to replace the file at `url` with: marked when
    /// that file is.
    public static func data(_ text: String, replacing url: URL) -> Data {
        var data = Data(text.utf8)
        if isPresent(at: url), text.unicodeScalars.first != "\u{FEFF}" {
            data.insert(contentsOf: bytes, at: 0)
        }
        return data
    }

    /// `text` without a leading mark, for a read that decoded it as a character.
    public static func stripped(_ text: String) -> String {
        guard text.unicodeScalars.first == "\u{FEFF}" else { return text }
        return String(text.unicodeScalars.dropFirst())
    }
}

extension String {
    /// Writes the string over a note, atomically and as UTF-8, keeping the
    /// byte-order mark the file has. Every write over an existing note goes
    /// through this rather than `write(to:atomically:encoding:)`.
    public func writeNote(to url: URL) throws {
        try ByteOrderMark.data(self, replacing: url).write(to: url, options: .atomic)
    }
}
