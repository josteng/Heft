import Foundation

/// Line-level helpers over raw note source. Kept separate from the markdown
/// AST because the editor and the indexer both need cheap answers without
/// paying for a full parse of every file in the vault.
public enum NoteText {

    public struct Heading: Equatable, Sendable {
        public let level: Int
        public let text: String
        public let line: Int
    }

    /// Splits leading YAML frontmatter from the body.
    /// Returns `nil` frontmatter when the note does not open with `---`.
    public static func splitFrontmatter(_ source: String) -> (frontmatter: String?, body: String) {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, source)
        }
        // Find the closing fence. An unterminated block is not frontmatter.
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            let fm = lines[1..<i].joined(separator: "\n")
            let body = lines[(i + 1)...].joined(separator: "\n")
            return (fm, body)
        }
        return (nil, source)
    }

    /// ATX headings, skipping fenced code blocks so `# comment` inside a shell
    /// snippet is not mistaken for a heading.
    public static func headings(in source: String) -> [Heading] {
        var result: [Heading] = []
        var inFence = false
        var fenceMarker = ""

        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                continue
            }
            guard trimmed.hasPrefix("#") else { continue }

            let hashes = trimmed.prefix { $0 == "#" }
            let level = hashes.count
            guard level <= 6 else { continue }
            let rest = trimmed.dropFirst(level)
            // "#tag" is a tag, not a heading: a heading needs whitespace after the hashes.
            guard rest.first == " " || rest.isEmpty else { continue }

            result.append(Heading(
                level: level,
                text: rest.trimmingCharacters(in: .whitespaces),
                line: index
            ))
        }
        return result
    }

    /// Line index of a heading whose text matches `title`, case-insensitively.
    public static func lineOfHeading(_ title: String, in source: String) -> Int? {
        let needle = title.lowercased()
        return headings(in: source).first { $0.text.lowercased() == needle }?.line
    }

    /// Line index carrying a `^blockid` marker.
    public static func lineOfBlockID(_ blockID: String, in source: String) -> Int? {
        let needle = "^" + blockID
        for (index, line) in source.components(separatedBy: "\n").enumerated()
        where line.trimmingCharacters(in: .whitespaces).hasSuffix(needle) {
            return index
        }
        return nil
    }

    /// The slice of `source` an embed should show.
    ///
    /// `![[Note]]` takes the whole body, `![[Note#Section]]` takes that heading
    /// and everything under it up to the next heading of the same or higher
    /// level, and `![[Note#^id]]` takes the single line carrying the block id.
    /// Returns nil when the reference names something the note does not have,
    /// so the caller can leave the source visible rather than show an empty box.
    public static func embedBody(of source: String, heading: String?, blockID: String?) -> String? {
        let lines = splitFrontmatter(source).body.components(separatedBy: "\n")

        if let blockID {
            guard let index = lineOfBlockID(blockID, in: lines.joined(separator: "\n"))
            else { return nil }
            // The marker is an anchor, not content, so it is not shown.
            return lines[index]
                .replacingOccurrences(of: "^" + blockID, with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        guard let heading, !heading.isEmpty else {
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let body = lines.joined(separator: "\n")
        let all = headings(in: body)
        guard let start = all.first(where: { $0.text.lowercased() == heading.lowercased() })
        else { return nil }

        let end = all
            .first { $0.line > start.line && $0.level <= start.level }?.line ?? lines.count
        return lines[start.line..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short plain-text preview, with frontmatter, headings and markers removed.
    public static func excerpt(_ source: String, limit: Int = 140) -> String {
        let body = splitFrontmatter(source).body
        for line in body.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("---"), !t.hasPrefix("```") else { continue }
            for marker in ["**", "*", "`", "> ", "- ", "==", "~~"] {
                t = t.replacingOccurrences(of: marker, with: "")
            }
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            return t.count > limit ? String(t.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : t
        }
        return ""
    }

    /// Enumerates lines outside fenced code blocks, so link indexing does not
    /// pick up `[[examples]]` written inside a code sample.
    public static func forEachProseLine(_ source: String, _ body: (Int, String) -> Void) {
        var inFence = false
        var fenceMarker = ""
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                continue
            }
            body(index, line)
        }
    }
}
