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

    /// The characters of a **1-based** line, without its trailing newline.
    ///
    /// The number is 1-based because that is what a search hit carries and
    /// what the editor reveals against; `headings` and `lineOfBlockID` count
    /// from 0. Mixing the two is silent: it lands a line early, and a heading
    /// on the very first line becomes 0, which reveals nothing at all.
    public static func range(ofLine line: Int, in source: String) -> NSRange? {
        let text = source as NSString
        guard text.length > 0, line > 0 else { return nil }

        var start = 0
        var number = 1
        while number < line {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard next > start, next < text.length else { break }
            start = next
            number += 1
        }

        var range = text.lineRange(for: NSRange(location: start, length: 0))
        // The highlight covers the text alone.
        while range.length > 0,
              let last = text.substring(
                  with: NSRange(location: NSMaxRange(range) - 1, length: 1)
              ).first,
              last == "\n" || last == "\r" {
            range.length -= 1
        }
        return range.length > 0 ? range : nil
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

    /// A short plain-text preview: the first line of prose, with frontmatter,
    /// headings, fences, embeds and markup out of the way.
    ///
    /// What the sidebar's Recent list shows under a name, so it reads the way
    /// the note does: a task line gives its text, a link its alias, and a
    /// note that is nothing but headings gives nothing rather than a `#`.
    public static func excerpt(_ source: String, limit: Int = 140) -> String {
        let body = splitFrontmatter(source).body
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("```") || raw.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, !raw.isEmpty, !raw.hasPrefix("#"), !raw.hasPrefix("---"),
                  !raw.hasPrefix("![") else { continue }
            let t = plainLine(raw)
            guard !t.isEmpty else { continue }
            return t.count > limit ? String(t.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : t
        }
        return ""
    }

    /// One line with its Markdown stripped, for `excerpt`.
    static func plainLine(_ line: String) -> String {
        var t = line
        // Quote, list and task markers, in the order they nest.
        while let match = t.firstMatch(of: #/^>\s*/#) { t.removeSubrange(match.range) }
        if let match = t.firstMatch(of: #/^(?:[-*+]|\d+[.)])\s+/#) { t.removeSubrange(match.range) }
        if let match = t.firstMatch(of: #/^\[[ xX]\]\s*/#) { t.removeSubrange(match.range) }
        // `[[Note|alias]]` reads as its alias, `[[Note]]` as its name, and a
        // Markdown link as its text.
        t = t.replacing(#/\[\[([^\]|]*)(?:\|([^\]]*))?\]\]/#) { match in
            String(match.output.2 ?? match.output.1)
        }
        t = t.replacing(#/\[([^\]]*)\]\([^)]*\)/#) { match in String(match.output.1) }
        for marker in ["**", "__", "*", "`", "==", "~~"] {
            t = t.replacingOccurrences(of: marker, with: "")
        }
        return t.trimmingCharacters(in: .whitespaces)
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
