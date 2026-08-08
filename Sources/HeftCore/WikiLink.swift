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

    // MARK: - Rewriting

    /// Repoints every link in `source` that `matches` accepts, leaving the rest
    /// of the file untouched.
    ///
    /// Only the *target* of a matched link is replaced; its heading, block id,
    /// alias and embed size are copied through as raw source. That matters more
    /// than it sounds: rebuilding a link from its parsed parts would normalise
    /// Obsidian's `\|` table escape into a bare pipe and quietly break every
    /// table the link appears in.
    ///
    /// Fenced code is skipped, so a rename cannot edit someone's code sample.
    public static func rewriteTargets(
        in source: String,
        matches: (WikiLink) -> Bool,
        replacement: (WikiLink) -> String
    ) -> (text: String, count: Int) {
        var lines: [String] = []
        var count = 0
        var inFence = false
        var fenceMarker = ""

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                lines.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                lines.append(line)
                continue
            }
            let (rewritten, changed) = rewriteLine(line, matches: matches, replacement: replacement)
            lines.append(rewritten)
            count += changed
        }
        return (lines.joined(separator: "\n"), count)
    }

    private static func rewriteLine(
        _ line: String,
        matches: (WikiLink) -> Bool,
        replacement: (WikiLink) -> String
    ) -> (String, Int) {
        let chars = Array(line)
        var out = ""
        var count = 0
        var i = 0

        while i < chars.count {
            let isEmbed = chars[i] == "!" && i + 2 < chars.count
                && chars[i + 1] == "[" && chars[i + 2] == "["
            let isLink = chars[i] == "[" && i + 1 < chars.count && chars[i + 1] == "["

            guard isEmbed || isLink else {
                out.append(chars[i])
                i += 1
                continue
            }
            // Same innermost-pair rule the parser uses, so `\[[[Note]]` is
            // rewritten on its real link rather than on a bracket run.
            if isLink {
                var run = 0
                while i + run < chars.count, chars[i + run] == "[" { run += 1 }
                if run > 2 {
                    let extra = run - 2
                    out += String(repeating: "[", count: extra)
                    i += extra
                    continue
                }
            }

            let contentStart = i + (isEmbed ? 3 : 2)
            guard let close = findClose(chars, from: contentStart) else {
                out.append(chars[i])
                i += 1
                continue
            }
            let body = String(chars[contentStart..<close])
            guard !body.isEmpty else {
                out.append(chars[i])
                i += 1
                continue
            }

            let link = parse(body: body, isEmbed: isEmbed)
            if matches(link) {
                let tail = tailIndex(ofBody: body)
                out += (isEmbed ? "![[" : "[[") + replacement(link) + String(body[tail...]) + "]]"
                count += 1
            } else {
                out += String(chars[i...(close + 1)])
            }
            i = close + 2
        }
        return (out, count)
    }

    /// Where a link body stops naming a file and starts carrying a heading,
    /// alias or embed size — everything from here on is copied through as-is.
    ///
    /// Obsidian escapes the separator as `\|` inside tables. The backslash
    /// belongs to the separator, not to the filename, so the tail has to start
    /// before it or a rename eats it and the table row breaks.
    private static func tailIndex(ofBody body: String) -> String.Index {
        guard let stop = body.firstIndex(where: { $0 == "#" || $0 == "|" })
        else { return body.endIndex }
        guard body[stop] == "|", stop > body.startIndex else { return stop }
        let before = body.index(before: stop)
        return body[before] == "\\" ? before : stop
    }

    /// How a link should be spelled after its target file moves.
    ///
    /// The original shape is kept: a bare name stays a bare name, a path stays
    /// a path, and an explicit `.md` survives. Rewriting everything to a full
    /// path would also resolve, but it would churn links the rename never
    /// needed to touch.
    public static func retargeted(_ old: String, to newRelativePath: String) -> String {
        // `.md` is the only extension a link may omit. An attachment's
        // extension is part of its name, so dropping it would break the link.
        let dropsExtension = (newRelativePath as NSString).pathExtension.lowercased() == "md"
            && !old.lowercased().hasSuffix(".md")
        let spelled = dropsExtension
            ? (newRelativePath as NSString).deletingPathExtension
            : newRelativePath
        return old.contains("/") ? spelled : (spelled as NSString).lastPathComponent
    }
}
