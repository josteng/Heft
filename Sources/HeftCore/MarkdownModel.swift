import Foundation
import Markdown

/// A rendering-ready markdown tree.
///
/// swift-markdown's own AST is walked once into this model rather than being
/// rendered directly, for two reasons: the model is UI-framework-free (so it
/// stays in the portable core), and Obsidian's non-CommonMark syntax
/// (`[[links]]`, `==highlights==`) is folded in here exactly once.
///
/// Those extensions are applied to *text nodes only*. By that point cmark has
/// already isolated code spans and fenced blocks into their own nodes, so a
/// `[[link]]` written inside a code sample is structurally out of reach and
/// cannot be corrupted. Doing the same work with a regex over raw source is
/// what makes naive implementations mangle code blocks.
public indirect enum MDBlock: Sendable {
    case heading(level: Int, inlines: [MDInline], anchor: String)
    case paragraph([MDInline])
    case codeBlock(language: String?, code: String)
    case quote(kind: CalloutKind?, title: String?, blocks: [MDBlock])
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case table(header: [[MDInline]], rows: [[[MDInline]]], alignments: [MDColumnAlignment])
    case thematicBreak
    case html(String)
}

public struct MDListItem: Sendable {
    /// `nil` for a normal bullet, otherwise the task's checked state.
    public let checked: Bool?
    public let blocks: [MDBlock]
    public init(checked: Bool?, blocks: [MDBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public enum MDColumnAlignment: Sendable, Hashable { case leading, center, trailing }

/// Obsidian callouts: `> [!note] Title`.
public enum CalloutKind: String, Sendable, CaseIterable {
    case note, abstract, info, todo, tip, success, question, warning
    case failure, danger, bug, example, quote

    public static func parse(_ raw: String) -> CalloutKind? {
        switch raw.lowercased() {
        case "note": .note
        case "abstract", "summary", "tldr": .abstract
        case "info": .info
        case "todo": .todo
        case "tip", "hint", "important": .tip
        case "success", "check", "done": .success
        case "question", "help", "faq": .question
        case "warning", "caution", "attention": .warning
        case "failure", "fail", "missing": .failure
        case "danger", "error": .danger
        case "bug": .bug
        case "example": .example
        case "quote", "cite": .quote
        default: nil
        }
    }

    /// The other spellings Obsidian accepts for this kind. Offered by
    /// completion so typing `tldr` or `caution` finds the callout it means,
    /// rather than only the one canonical name.
    public var aliases: [String] {
        switch self {
        case .abstract: ["summary", "tldr"]
        case .tip: ["hint", "important"]
        case .success: ["check", "done"]
        case .question: ["help", "faq"]
        case .warning: ["caution", "attention"]
        case .failure: ["fail", "missing"]
        case .danger: ["error"]
        case .quote: ["cite"]
        default: []
        }
    }

    public var symbol: String {
        switch self {
        case .note: "pencil.circle.fill"
        case .abstract: "doc.text.fill"
        case .info: "info.circle.fill"
        case .todo: "checkmark.circle.fill"
        case .tip: "flame.fill"
        case .success: "checkmark.seal.fill"
        case .question: "questionmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        case .danger: "bolt.trianglebadge.exclamationmark.fill"
        case .bug: "ant.fill"
        case .example: "list.bullet.clipboard.fill"
        case .quote: "quote.opening"
        }
    }
}

public indirect enum MDInline: Sendable {
    case text(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strikethrough([MDInline])
    case highlight([MDInline])
    case code(String)
    case link(destination: String?, children: [MDInline])
    case image(source: String?, alt: String)
    case wikiLink(WikiLink)
    case embed(WikiLink)
    /// LaTeX. `display` is `$$…$$`, otherwise `$…$`.
    case math(String, display: Bool)
    /// Obsidian `#tag`, without the leading hash.
    case tag(String)
    case softBreak
    case lineBreak
}

/// A parsed note, with each top-level block tied back to the lines it came
/// from.
///
/// The line ranges are what makes block-based editing possible: to let the
/// reader click a rendered block and edit its source, the renderer has to know
/// which slice of the file that block occupies, and how to splice an edit back
/// in without disturbing anything else.
public struct MDDocument: Sendable {
    public let frontmatter: String?
    public let blocks: [MDBlock]
    /// Parallel to `blocks`: inclusive, zero-based line range in the *full*
    /// source, frontmatter included.
    public let lineRanges: [ClosedRange<Int>]

    public init(frontmatter: String?, blocks: [MDBlock], lineRanges: [ClosedRange<Int>]) {
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.lineRanges = lineRanges
    }

    /// The source lines backing block `index`.
    public func source(ofBlock index: Int, in fullSource: String) -> String? {
        guard lineRanges.indices.contains(index) else { return nil }
        let lines = fullSource.components(separatedBy: "\n")
        let range = lineRanges[index]
        guard range.lowerBound >= 0, range.upperBound < lines.count else { return nil }
        return lines[range].joined(separator: "\n")
    }

    /// Replaces block `index`'s lines with `replacement`, leaving the rest of
    /// the file byte-identical.
    public func replacing(block index: Int, with replacement: String, in fullSource: String) -> String? {
        guard lineRanges.indices.contains(index) else { return nil }
        var lines = fullSource.components(separatedBy: "\n")
        let range = lineRanges[index]
        guard range.lowerBound >= 0, range.upperBound < lines.count else { return nil }
        lines.replaceSubrange(range, with: replacement.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }
}

public enum MarkdownModel {

    /// Parses a note body. Frontmatter is returned separately rather than
    /// rendered, matching how Obsidian treats it.
    public static func parse(_ source: String) -> (frontmatter: String?, blocks: [MDBlock]) {
        let document = parseDocument(source)
        return (document.frontmatter, document.blocks)
    }

    /// Parses and records where each top-level block came from.
    public static func parseDocument(_ source: String) -> MDDocument {
        let (frontmatter, body) = NoteText.splitFrontmatter(source)
        // cmark reports 1-based lines within the body; shift them so they index
        // the full file, which is what an editor needs to splice against.
        let offset = source.components(separatedBy: "\n").count
            - body.components(separatedBy: "\n").count

        let document = Document(parsing: body)
        var blocks: [MDBlock] = []
        var ranges: [ClosedRange<Int>] = []

        func lineRange(of markup: Markup) -> ClosedRange<Int>? {
            guard let range = markup.range else { return nil }
            let lower = max(0, range.lowerBound.line - 1 + offset)
            return lower...max(lower, range.upperBound.line - 1 + offset)
        }

        for child in document.children {
            // A list is split into one editable unit per item. Editing a whole
            // list at once — turning every bullet into raw source because the
            // caret entered one of them — is jarring; Obsidian reveals only the
            // line you are on. Each item still renders as a list so bullets,
            // checkboxes and indentation are unchanged.
            if let items = topLevelListItems(child) {
                for (item, block) in items {
                    blocks.append(block)
                    ranges.append(lineRange(of: item) ?? -1...(-1))
                }
                continue
            }

            guard let block = block(from: child) else { continue }
            blocks.append(block)
            // Should not happen for top-level nodes, but a renderer must never
            // crash on a missing range — mark it uneditable instead.
            ranges.append(lineRange(of: child) ?? -1...(-1))
        }
        return MDDocument(frontmatter: frontmatter, blocks: blocks, lineRanges: ranges)
    }

    // MARK: - Blocks

    static func blocks(from container: Markup) -> [MDBlock] {
        container.children.compactMap(block(from:))
    }

    private static func block(from markup: Markup) -> MDBlock? {
        switch markup {
        case let heading as Heading:
            let inlines = self.inlines(from: heading)
            return .heading(level: heading.level, inlines: inlines, anchor: heading.plainText)

        case let paragraph as Paragraph:
            // A `$$…$$` block spanning several lines arrives as one paragraph
            // whose text is split across soft breaks, so the inline math
            // scanner never sees the delimiters as adjacent. Detect it here,
            // at the paragraph level, before falling back to inline handling.
            if let latex = displayMathOnly(paragraph) {
                return .paragraph([.math(latex, display: true)])
            }
            return .paragraph(inlines(from: paragraph))

        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return .codeBlock(
                language: (language?.isEmpty ?? true) ? nil : language,
                code: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            )

        case let quote as BlockQuote:
            return calloutOrQuote(quote)

        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: listItems(list))

        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: listItems(list))

        case is ThematicBreak:
            return .thematicBreak

        case let table as Markdown.Table:
            return self.table(table)

        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->") { return nil }
            return .html(html.rawHTML)

        default:
            // Anything unrecognised still contributes its children rather than
            // silently dropping content.
            let children = blocks(from: markup)
            if children.isEmpty { return nil }
            return .quote(kind: nil, title: nil, blocks: children)
        }
    }

    /// Splits a top-level list into one single-item list per entry, pairing each
    /// with the `ListItem` whose source range it occupies. Returns `nil` for
    /// anything that is not a list.
    private static func topLevelListItems(_ markup: Markup) -> [(Markup, MDBlock)]? {
        let ordered: Bool
        let start: Int
        switch markup {
        case let list as OrderedList:
            ordered = true
            start = Int(list.startIndex)
        case is UnorderedList:
            ordered = false
            start = 1
        default:
            return nil
        }

        var result: [(Markup, MDBlock)] = []
        for (offset, child) in markup.children.enumerated() {
            guard let item = child as? ListItem else { continue }
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            let single = MDListItem(checked: checked, blocks: blocks(from: item))
            result.append((item, .list(ordered: ordered, start: start + offset, items: [single])))
        }
        return result.isEmpty ? nil : result
    }

    /// The LaTeX of a paragraph that is nothing but one `$$…$$` block.
    private static func displayMathOnly(_ paragraph: Paragraph) -> String? {
        var text = ""
        for child in paragraph.children {
            switch child {
            case let run as Markdown.Text: text += run.string
            case is SoftBreak, is LineBreak: text += "\n"
            default: return nil  // anything richer is not pure math
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        // A second `$$` inside means this is prose containing two blocks.
        guard !inner.contains("$$") else { return nil }
        let latex = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return latex.isEmpty ? nil : latex
    }

    private static func listItems(_ list: Markup) -> [MDListItem] {
        list.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            return MDListItem(checked: checked, blocks: blocks(from: item))
        }
    }

    /// Detects the `> [!warning] Title` callout form, falling back to a plain quote.
    private static func calloutOrQuote(_ quote: BlockQuote) -> MDBlock {
        var inner = blocks(from: quote)

        guard case .paragraph(let firstInlines)? = inner.first,
              case .text(let leading)? = firstInlines.first
        else { return .quote(kind: nil, title: nil, blocks: inner) }

        let trimmed = leading.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), let close = trimmed.firstIndex(of: "]") else {
            return .quote(kind: nil, title: nil, blocks: inner)
        }

        let rawKind = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close])
            .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let kind = CalloutKind.parse(rawKind) else {
            return .quote(kind: nil, title: nil, blocks: inner)
        }

        // Strip the marker; whatever follows on that line becomes the title.
        var remainder = Array(firstInlines.dropFirst())
        let afterMarker = String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)

        var title = afterMarker
        var bodyInlines: [MDInline] = []
        if let breakIndex = remainder.firstIndex(where: { if case .softBreak = $0 { true } else { false } }) {
            // Title text ended at the first line break; the rest is body.
            let titlePart = remainder[..<breakIndex]
            bodyInlines = Array(remainder[remainder.index(after: breakIndex)...])
            if !titlePart.isEmpty { title += plainText(titlePart) }
            remainder = []
        }

        inner.removeFirst()
        if !bodyInlines.isEmpty { inner.insert(.paragraph(bodyInlines), at: 0) }
        else if !remainder.isEmpty { inner.insert(.paragraph(remainder), at: 0) }

        return .quote(
            kind: kind,
            title: title.isEmpty ? kind.rawValue.capitalized : title,
            blocks: inner
        )
    }

    private static func table(_ table: Markdown.Table) -> MDBlock {
        let alignments: [MDColumnAlignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        let header = Array(table.head.cells).map { inlines(from: $0) }
        let rows = Array(table.body.rows).map { row in Array(row.cells).map { inlines(from: $0) } }
        return .table(header: header, rows: rows, alignments: alignments)
    }

    // MARK: - Inlines

    static func inlines(from container: Markup) -> [MDInline] {
        container.children.flatMap(inline(from:))
    }

    private static func inline(from markup: Markup) -> [MDInline] {
        switch markup {
        case let text as Markdown.Text:
            return expand(text: text.string)
        case let emphasis as Emphasis:
            return [.emphasis(inlines(from: emphasis))]
        case let strong as Strong:
            return [.strong(inlines(from: strong))]
        case let strike as Strikethrough:
            return [.strikethrough(inlines(from: strike))]
        case let code as InlineCode:
            return [.code(code.code)]
        case let link as Markdown.Link:
            return [.link(destination: link.destination, children: inlines(from: link))]
        case let image as Markdown.Image:
            return [.image(source: image.source, alt: image.plainText)]
        case is SoftBreak:
            return [.softBreak]
        case is LineBreak:
            return [.lineBreak]
        case let html as InlineHTML:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->") { return [] }
            // Obsidian passes raw inline HTML through; showing the markup is
            // less surprising than dropping the content entirely.
            return [.text(html.rawHTML)]
        default:
            let children = inlines(from: markup)
            if !children.isEmpty { return children }
            // Leaf node this model does not know about: keep its text rather
            // than dropping the content.
            if let convertible = markup as? any PlainTextConvertibleMarkup {
                return [.text(convertible.plainText)]
            }
            return []
        }
    }

    /// Applies the Obsidian-only inline syntax to a plain text run.
    private static func expand(text: String) -> [MDInline] {
        WikiLinkParser.segments(in: text).flatMap { segment -> [MDInline] in
            switch segment {
            case .link(let link):
                return [link.isEmbed ? .embed(link) : .wikiLink(link)]
            case .text(let literal):
                return splitMath(literal)
                    .flatMap { piece -> [MDInline] in
                        if case .text(let plain) = piece { return splitHighlights(plain) }
                        return [piece]
                    }
                    .flatMap { piece -> [MDInline] in
                        if case .text(let plain) = piece { return splitTags(plain) }
                        return [piece]
                    }
            }
        }
    }

    /// Splits `$$…$$` and `$…$` out of literal text.
    ///
    /// Runs on text nodes only, so a `$` inside a code span is already out of
    /// reach. The inline form additionally requires non-space just inside the
    /// delimiters, so "$5 and $10" stays as prose.
    private static func splitMath(_ s: String) -> [MDInline] {
        guard s.contains("$") else { return s.isEmpty ? [] : [.text(s)] }

        let ns = s as NSString
        var result: [MDInline] = []
        var cursor = 0

        for match in mathMatches(in: s) {
            guard match.range.location >= cursor else { continue }
            if match.range.location > cursor {
                result.append(.text(ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor
                ))))
            }
            result.append(.math(match.latex, display: match.display))
            cursor = NSMaxRange(match.range)
        }

        if cursor < ns.length {
            result.append(.text(ns.substring(from: cursor)))
        }
        return result.isEmpty ? [.text(s)] : result
    }

    private struct MathMatch {
        let range: NSRange
        let latex: String
        let display: Bool
    }

    private static let displayMathRegex = try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$"#)
    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"\$(?![\s$])((?:[^$\n]|\\\$)+?)(?<![\s\\])\$"#
    )

    private static func mathMatches(in s: String) -> [MathMatch] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [MathMatch] = []

        for m in displayMathRegex.matches(in: s, range: full) where m.numberOfRanges > 1 {
            found.append(MathMatch(range: m.range, latex: ns.substring(with: m.range(at: 1)), display: true))
        }
        for m in inlineMathRegex.matches(in: s, range: full) where m.numberOfRanges > 1 {
            // Skip anything already claimed by a display-math match.
            guard !found.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
            found.append(MathMatch(range: m.range, latex: ns.substring(with: m.range(at: 1)), display: false))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Splits `==highlighted==` runs out of literal text.
    private static func splitHighlights(_ s: String) -> [MDInline] {
        guard s.contains("==") else { return s.isEmpty ? [] : [.text(s)] }

        var result: [MDInline] = []
        var rest = Substring(s)
        while let open = rest.range(of: "==") {
            guard let close = rest.range(of: "==", range: open.upperBound..<rest.endIndex) else { break }
            let before = rest[rest.startIndex..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            // `== ==` with nothing between is not a highlight.
            guard !inner.isEmpty else { break }
            if !before.isEmpty { result.append(.text(String(before))) }
            result.append(.highlight([.text(String(inner))]))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { result.append(.text(String(rest))) }
        return result.isEmpty ? [.text(s)] : result
    }

    /// Splits Obsidian `#tag` out of literal text.
    ///
    /// A heading's hashes never reach here — cmark has already consumed them
    /// into the `Heading` node — so a `#` at the start of a text run is a tag.
    private static func splitTags(_ s: String) -> [MDInline] {
        guard s.contains("#") else { return s.isEmpty ? [] : [.text(s)] }

        let ns = s as NSString
        var result: [MDInline] = []
        var cursor = 0

        for match in tagRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        where match.numberOfRanges > 1 {
            let full = match.range(at: 1)
            if full.location > cursor {
                result.append(.text(ns.substring(with: NSRange(
                    location: cursor, length: full.location - cursor
                ))))
            }
            result.append(.tag(ns.substring(with: match.range(at: 2))))
            cursor = NSMaxRange(full)
        }

        if cursor < ns.length { result.append(.text(ns.substring(from: cursor))) }
        return result.isEmpty ? [.text(s)] : result
    }

    /// Requires a non-word character before the hash so `C#` and URL fragments
    /// are not mistaken for tags. Group 1 is the whole tag, group 2 its name.
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/&#])(#([A-Za-z][\w/-]*))"#
    )

    public static func plainText(_ inlines: some Sequence<MDInline>) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s): s
            case .code(let s): s
            case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c):
                plainText(c)
            case .link(_, let c): plainText(c)
            case .image(_, let alt): alt
            case .wikiLink(let l), .embed(let l): l.displayText
            case .math(let latex, _): latex
            case .tag(let name): "#\(name)"
            case .softBreak, .lineBreak: " "
            }
        }.joined()
    }
}
