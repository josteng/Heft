import Foundation

/// One styled construct found in markdown source.
///
/// `syntax` holds the marker characters (`**`, `[[`, `# `) that live mode hides
/// when the cursor is elsewhere. Nothing here mutates the text: the editor keeps
/// the document string byte-for-byte and only changes how it is drawn, which is
/// what makes hybrid editing safe to run against a real vault.
public struct MarkdownDecoration: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case frontmatter
        case codeBlock(language: String?)
        case heading(level: Int)
        case blockQuote
        case listMarker(kind: ListMarkerKind, depth: Int)
        case bold
        case italic
        case strikethrough
        case highlight
        case inlineCode
        case wikiLink(target: String, isEmbed: Bool)
        case link(destination: String)
        case tag
        case inlineMath(String)
        case blockMath(String)
        case thematicBreak
    }

    public let range: NSRange
    public let syntax: [NSRange]
    public let style: Style

    public init(range: NSRange, syntax: [NSRange] = [], style: Style) {
        self.range = range
        self.syntax = syntax
        self.style = style
    }
}

public enum ListMarkerKind: Sendable, Equatable {
    /// `-`, `*` or `+`: replaced by a drawn bullet.
    case bullet
    /// `1.` / `1)`: the numeral stays legible, so it is only dimmed.
    case ordered
    /// `- [ ]` / `- [x]`: replaced by a drawn checkbox.
    case task(checked: Bool)
}

public enum LiveDecorator {

    /// Finds every construct worth styling. Emitted roughly outermost-first so a
    /// consumer applying attributes in order gets inner spans winning.
    public static func decorations(in source: String) -> [MarkdownDecoration] {
        let text = source as NSString
        var result: [MarkdownDecoration] = []

        // Code regions are computed first and everything else is excluded from
        // them, so `**not bold**` inside a fence stays literal.
        var protected: [NSRange] = []

        if let fm = firstMatch(#"\A---\n[\s\S]*?\n---"#, text) {
            result.append(MarkdownDecoration(range: fm, style: .frontmatter))
            protected.append(fm)
        }

        for match in matches(#"(?m)^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?^[ \t]*\1[ \t]*$"#, text, excluding: protected) {
            let language = languageOfFence(match, text)
            result.append(MarkdownDecoration(
                range: match, syntax: fenceSyntaxRanges(match, text), style: .codeBlock(language: language)
            ))
            protected.append(match)
        }
        // An unterminated fence still needs protecting, or the rest of the file
        // gets styled as prose while the user is mid-typing a code block.
        for match in matches(#"(?m)^[ \t]*(```|~~~)[^\n]*\n[\s\S]*\z"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, style: .codeBlock(language: nil)))
            protected.append(match)
        }

        // Block math before inline, so `$$x$$` is not read as two empty `$$`.
        for match in matches(#"\$\$[\s\S]+?\$\$"#, text, excluding: protected) {
            let inner = NSRange(location: match.location + 2, length: match.length - 4)
            guard inner.length > 0 else { continue }
            let latex = text.substring(with: inner)
            // Only `$$…$$` alone on its line becomes a drawn block. One sitting
            // mid-sentence has no line of its own to reserve, so it would be
            // painted over the surrounding prose.
            let style: MarkdownDecoration.Style = ownsItsLines(match, text)
                ? .blockMath(latex)
                : .inlineMath(latex)
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 2),
                         NSRange(location: NSMaxRange(match) - 2, length: 2)],
                style: style
            ))
            protected.append(match)
        }

        for match in matches(#"`[^`\n]+`"#, text, excluding: protected) {
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 1),
                         NSRange(location: NSMaxRange(match) - 1, length: 1)],
                style: .inlineCode
            ))
            protected.append(match)
        }

        // Inline math. Requires non-space just inside the delimiters so prices
        // ("$5 to $10") are not mistaken for math.
        for match in matches(#"\$(?![\s$])((?:[^$\n]|\\\$)+?)(?<![\s\\])\$"#, text, excluding: protected) {
            let inner = NSRange(location: match.location + 1, length: match.length - 2)
            guard inner.length > 0 else { continue }
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: 1),
                         NSRange(location: NSMaxRange(match) - 1, length: 1)],
                style: .inlineMath(text.substring(with: inner))
            ))
            protected.append(match)
        }

        result.append(contentsOf: blockDecorations(text, protected: protected))
        result.append(contentsOf: inlineDecorations(text, protected: protected))
        return result
    }

    /// True when nothing but whitespace shares the construct's first and last lines.
    private static func ownsItsLines(_ range: NSRange, _ text: NSString) -> Bool {
        let lines = text.lineRange(for: range)
        let before = text.substring(with: NSRange(
            location: lines.location, length: range.location - lines.location
        ))
        let after = text.substring(with: NSRange(
            location: NSMaxRange(range), length: NSMaxRange(lines) - NSMaxRange(range)
        ))
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Block constructs

    private static func blockDecorations(_ text: NSString, protected: [NSRange]) -> [MarkdownDecoration] {
        var result: [MarkdownDecoration] = []

        for match in matches(#"(?m)^(#{1,6})[ \t]+\S.*$"#, text, excluding: protected) {
            let line = text.substring(with: match)
            let level = line.prefix { $0 == "#" }.count
            // Hide the hashes and the space that follows them.
            var syntaxLength = level
            while syntaxLength < line.count,
                  line[line.index(line.startIndex, offsetBy: syntaxLength)] == " " {
                syntaxLength += 1
            }
            result.append(MarkdownDecoration(
                range: match,
                syntax: [NSRange(location: match.location, length: syntaxLength)],
                style: .heading(level: level)
            ))
        }

        for match in matches(#"(?m)^[ \t]*>[ \t]?"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, syntax: [match], style: .blockQuote))
        }

        for match in matches(#"(?m)^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#, text, excluding: protected) {
            let marker = text.substring(with: match)
            let leading = marker.prefix { $0 == " " || $0 == "\t" }
            // Two spaces or one tab per nesting level, which is what both
            // Obsidian and CommonMark produce.
            let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) } + (leading.filter { $0 == " " }.count / 2)

            let kind: ListMarkerKind
            if let box = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) {
                kind = .task(checked: marker[box].lowercased().contains("x"))
            } else if marker.contains(where: \.isNumber) {
                kind = .ordered
            } else {
                kind = .bullet
            }

            // The whole marker hides, indentation included: the editor redraws
            // it as a real bullet, checkbox or numeral, and positions it from
            // the paragraph indent rather than from leading whitespace.
            result.append(MarkdownDecoration(
                range: match, syntax: [match], style: .listMarker(kind: kind, depth: depth)
            ))
        }

        for match in matches(#"(?m)^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, style: .thematicBreak))
        }

        return result
    }

    // MARK: - Inline constructs

    private static func inlineDecorations(_ text: NSString, protected: [NSRange]) -> [MarkdownDecoration] {
        var result: [MarkdownDecoration] = []

        func wrapped(_ pattern: String, _ markerLength: Int, _ style: MarkdownDecoration.Style) {
            for match in matches(pattern, text, excluding: protected) {
                result.append(MarkdownDecoration(
                    range: match,
                    syntax: [NSRange(location: match.location, length: markerLength),
                             NSRange(location: NSMaxRange(match) - markerLength, length: markerLength)],
                    style: style
                ))
            }
        }

        wrapped(#"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#, 2, .bold)
        wrapped(#"(?<![*\w])\*(?=[^\s*])([^\n*]+?)(?<=[^\s*])\*(?![*\w])"#, 1, .italic)
        wrapped(#"(?<![_\w])_(?=\S)([^\n_]+?)(?<=\S)_(?![_\w])"#, 1, .italic)
        wrapped(#"~~(?=\S)([^\n]+?)(?<=\S)~~"#, 2, .strikethrough)
        wrapped(#"==(?=\S)([^\n]+?)(?<=\S)=="#, 2, .highlight)

        // Wikilinks and embeds. The alias marker `Target|` is hidden too, so the
        // reader sees just the alias, as Obsidian does.
        for match in matches(#"!?\[\[[^\]\n]+\]\]"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            let isEmbed = raw.hasPrefix("!")
            let openLength = isEmbed ? 3 : 2
            var syntax = [
                NSRange(location: match.location, length: openLength),
                NSRange(location: NSMaxRange(match) - 2, length: 2),
            ]

            let bodyStart = match.location + openLength
            let bodyLength = match.length - openLength - 2
            let body = text.substring(with: NSRange(location: bodyStart, length: bodyLength))

            if let pipe = body.firstIndex(of: "|") {
                let prefix = body.distance(from: body.startIndex, to: pipe) + 1
                syntax.append(NSRange(location: bodyStart, length: prefix))
            }

            let link = WikiLinkParser.links(in: raw).first
            result.append(MarkdownDecoration(
                range: match, syntax: syntax,
                style: .wikiLink(target: link?.target ?? body, isEmbed: isEmbed)
            ))
        }

        for match in matches(#"\[([^\]\n]*)\]\(([^)\n]+)\)"#, text, excluding: protected) {
            let raw = text.substring(with: match)
            guard let close = raw.range(of: "](") else { continue }
            // Length of the label alone, excluding the opening bracket, so the
            // trailing `](url)` range starts exactly on the `]`.
            let labelLength = raw.distance(from: raw.index(after: raw.startIndex), to: close.lowerBound)
            let destination = String(raw[close.upperBound...].dropLast())
            result.append(MarkdownDecoration(
                range: match,
                syntax: [
                    NSRange(location: match.location, length: 1),
                    NSRange(location: match.location + 1 + labelLength,
                            length: match.length - labelLength - 1),
                ],
                style: .link(destination: destination)
            ))
        }

        for match in matches(#"(?<![\w/&])#[A-Za-z][\w/-]*"#, text, excluding: protected) {
            result.append(MarkdownDecoration(range: match, style: .tag))
        }

        return result
    }

    // MARK: - Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        // Patterns are literals in this file; a failure is a programmer error.
        let made = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        cache[pattern] = made
        return made
    }

    private static func matches(_ pattern: String, _ text: NSString, excluding: [NSRange] = []) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        return regex(pattern).matches(in: text as String, range: full)
            .map(\.range)
            .filter { candidate in
                !excluding.contains { NSIntersectionRange($0, candidate).length > 0 }
            }
    }

    private static func firstMatch(_ pattern: String, _ text: NSString) -> NSRange? {
        matches(pattern, text).first
    }

    private static func languageOfFence(_ range: NSRange, _ text: NSString) -> String? {
        let firstLineEnd = text.range(of: "\n", options: [], range: range)
        guard firstLineEnd.location != NSNotFound else { return nil }
        let header = text.substring(with: NSRange(
            location: range.location, length: firstLineEnd.location - range.location
        ))
        let language = header.trimmingCharacters(in: CharacterSet(charactersIn: " \t`~"))
        return language.isEmpty ? nil : language
    }

    /// The opening fence line and the closing fence, which live mode hides.
    private static func fenceSyntaxRanges(_ range: NSRange, _ text: NSString) -> [NSRange] {
        var syntax: [NSRange] = []
        let firstLineEnd = text.range(of: "\n", options: [], range: range)
        if firstLineEnd.location != NSNotFound {
            syntax.append(NSRange(
                location: range.location,
                length: firstLineEnd.location - range.location + 1
            ))
        }
        if let lastNewline = lastIndexOfNewline(in: range, text) {
            syntax.append(NSRange(location: lastNewline, length: NSMaxRange(range) - lastNewline))
        }
        return syntax
    }

    private static func lastIndexOfNewline(in range: NSRange, _ text: NSString) -> Int? {
        let found = text.range(of: "\n", options: .backwards, range: range)
        return found.location == NSNotFound ? nil : found.location
    }
}
