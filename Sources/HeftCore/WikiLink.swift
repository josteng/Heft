import Foundation

/// A parsed Obsidian-style link: `[[Target#Heading|Alias]]` or an embed
/// `![[Image.png|300]]`.
public struct WikiLink: Equatable, Sendable {
    public var target: String        // "Note", "folder/Note", "Image.png" — may be empty for [[#Heading]]
    public var heading: String?      // after '#'
    public var blockID: String?      // after '#^'
    public var alias: String?        // after '|' on a normal link
    public var isEmbed: Bool
    public var embedWidth: Int?      // ![[img.png|300]] or |300x200
    public var embedHeight: Int?

    /// What the reader should see when the link is not resolved to a note.
    public var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        var text = target.isEmpty ? "" : (target as NSString).lastPathComponent
        if text.hasSuffix(".md") { text = String(text.dropLast(3)) }
        if text.isEmpty, let heading { return heading }
        if let heading, !heading.isEmpty { return "\(text) › \(heading)" }
        return text
    }

    public init(
        target: String, heading: String? = nil, blockID: String? = nil,
        alias: String? = nil, isEmbed: Bool = false,
        embedWidth: Int? = nil, embedHeight: Int? = nil
    ) {
        self.target = target
        self.heading = heading
        self.blockID = blockID
        self.alias = alias
        self.isEmbed = isEmbed
        self.embedWidth = embedWidth
        self.embedHeight = embedHeight
    }
}

/// A run of source text: either literal text or a wikilink.
public enum WikiSegment: Equatable, Sendable {
    case text(String)
    case link(WikiLink)
}

public enum WikiLinkParser {

    /// Splits text into literal runs and wikilinks.
    ///
    /// This is run over markdown *text nodes* rather than raw source, so code
    /// spans and fenced code blocks have already been separated out by the
    /// markdown parser and cannot be corrupted here.
    public static func segments(in text: String) -> [WikiSegment] {
        var segments: [WikiSegment] = []
        var literal = ""
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // Detect "![[" (embed) or "[[" (link).
            let isEmbed = chars[i] == "!" && i + 2 < chars.count && chars[i + 1] == "[" && chars[i + 2] == "["
            let isLink = chars[i] == "[" && i + 1 < chars.count && chars[i + 1] == "["

            guard isEmbed || isLink else {
                literal.append(chars[i])
                i += 1
                continue
            }

            // A run of three or more `[` is a literal bracket sitting against a
            // link: `[[[Note]]]`, or `\[[[Note]]` where a note escaped a bracket
            // before linking. The link is the innermost pair, so shed the extras
            // as literal text and re-enter at the real opener. Starting at the
            // first `[` instead glues a bracket onto the target and the link
            // silently fails to resolve.
            if isLink {
                var runLength = 0
                while i + runLength < chars.count, chars[i + runLength] == "[" { runLength += 1 }
                if runLength > 2 {
                    let extra = runLength - 2
                    literal += String(repeating: "[", count: extra)
                    i += extra
                    continue
                }
            }

            let contentStart = i + (isEmbed ? 3 : 2)
            guard let closeIdx = findClose(chars, from: contentStart) else {
                literal.append(chars[i])
                i += 1
                continue
            }

            let body = String(chars[contentStart..<closeIdx])
            // An empty or newline-spanning body is not a link; treat as text.
            guard !body.isEmpty, !body.contains("\n") else {
                literal.append(chars[i])
                i += 1
                continue
            }

            if !literal.isEmpty {
                segments.append(.text(literal))
                literal = ""
            }
            segments.append(.link(parse(body: body, isEmbed: isEmbed)))
            i = closeIdx + 2
        }

        if !literal.isEmpty { segments.append(.text(literal)) }
        return segments
    }

    /// All links in a body of text, ignoring literal runs.
    public static func links(in text: String) -> [WikiLink] {
        segments(in: text).compactMap { if case .link(let l) = $0 { return l } else { return nil } }
    }

    private static func findClose(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            // Don't run past a line break looking for a closer.
            if chars[i] == "\n" { return nil }
            i += 1
        }
        return nil
    }

    private static func parse(body: String, isEmbed: Bool) -> WikiLink {
        // Obsidian escapes the separator as `\|` when a link sits inside a
        // table, where a bare pipe would end the cell. Both spellings mean the
        // same thing, so normalise before splitting; otherwise the backslash
        // ends up glued to the filename and the link never resolves.
        let normalised = body.replacingOccurrences(of: "\\|", with: "|")

        // Split on the FIRST '|'. Headings may contain '#', so pipe comes first.
        var left = normalised
        var right: String?
        if let pipe = normalised.firstIndex(of: "|") {
            left = String(normalised[normalised.startIndex..<pipe])
            right = String(normalised[normalised.index(after: pipe)...])
        }

        var target = left
        var heading: String?
        var blockID: String?
        if let hash = left.firstIndex(of: "#") {
            target = String(left[left.startIndex..<hash])
            let after = String(left[left.index(after: hash)...])
            if after.hasPrefix("^") {
                blockID = String(after.dropFirst())
            } else if !after.isEmpty {
                heading = after
            }
        }

        target = target.trimmingCharacters(in: .whitespaces)

        var link = WikiLink(
            target: target, heading: heading, blockID: blockID,
            isEmbed: isEmbed
        )

        if let right {
            let trimmed = right.trimmingCharacters(in: .whitespaces)
            // On an embed, a purely numeric suffix is a size, not an alias:
            // ![[img.png|300]] or ![[img.png|300x200]]
            if isEmbed, let size = parseSize(trimmed) {
                link.embedWidth = size.0
                link.embedHeight = size.1
            } else {
                link.alias = trimmed
            }
        }
        return link
    }

    private static func parseSize(_ s: String) -> (Int, Int?)? {
        if let w = Int(s) { return (w, nil) }
        let parts = s.split(separator: "x", maxSplits: 1)
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { return (w, h) }
        return nil
    }
}
