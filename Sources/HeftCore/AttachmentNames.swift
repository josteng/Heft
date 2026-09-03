import Foundation

/// Attachment filenames mentioned anywhere in a note.
///
/// Deliberately not a link parser. A vault says where it keeps its files in
/// more ways than `![[…]]`: a markdown image, a bare relative path, or a
/// frontmatter property like `Cover: Books/Covers/Dune.jpg`. All of them
/// are evidence of the same habit, and an embed-only scan misses a folder of
/// seven covers entirely.
public enum AttachmentNames {

    /// Every filename in `text` that looks like an attachment, lowercased and
    /// stripped of any folders in front of it.
    ///
    /// One scan of the note, rather than a search per known attachment: a
    /// vault with fifty attachments and four hundred notes would otherwise be
    /// twenty thousand substring searches.
    public static func mentioned(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        var candidates: [String] = []

        // A filename runs until whitespace or a delimiter that cannot be part
        // of one. `|` ends it too, because Obsidian writes `![[chart.png|500]]`.
        func flush() {
            if !current.isEmpty { candidates.append(current) }
            current = ""
        }
        for character in text {
            switch character {
            case " ", "\t", "\n", "\r", "[", "]", "(", ")", "\"", "'", "|", "<", ">", "#", ",", ";":
                flush()
            default:
                current.append(character)
            }
        }
        flush()

        for candidate in candidates {
            let name = candidate.split(separator: "/").last.map(String.init) ?? candidate
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, extensions.contains(ext) else { continue }
            found.insert(name.lowercased())
        }
        return found
    }

    /// What counts as an attachment. Wider than `VaultScanner.imageExtensions`
    /// because a vault files PDFs and recordings the same way it files
    /// pictures, and the question here is where things are kept.
    public static let extensions: Set<String> =
        VaultScanner.imageExtensions.union([
            "pdf", "mp4", "mov", "m4a", "mp3", "wav", "zip", "canvas",
        ])
}
