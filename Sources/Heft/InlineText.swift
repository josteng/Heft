import AppKit
import HeftCore
import SwiftUI

/// Everything the renderer needs to turn a link or an embed into something
/// concrete on disk.
struct RenderContext {
    let index: VaultIndex
    let current: NoteRef?
    let vaultRoot: URL?
    /// Mirrors the vault's Obsidian setting; see `ObsidianSettings`.
    var strictLineBreaks: Bool = false

    func resolve(_ link: WikiLink) -> NoteRef? { index.resolve(link, from: current) }

    /// Resolves a standard markdown path (`![](x.png)`) which may be vault-
    /// relative, note-relative, absolute, or a remote URL.
    func resolveResource(_ source: String) -> URL? {
        guard let decoded = source.removingPercentEncoding ?? Optional(source) else { return nil }
        if let url = URL(string: decoded), url.scheme != nil, url.scheme != "file" { return url }
        guard let vaultRoot else { return nil }

        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }

        let noteDirectory = current?.url.deletingLastPathComponent() ?? vaultRoot
        let candidates = [
            noteDirectory.appendingPathComponent(decoded),
            vaultRoot.appendingPathComponent(decoded),
        ]
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.standardizedFileURL.path) {
            return candidate.standardizedFileURL
        }
        // Last resort: match on filename alone, which is how Obsidian finds
        // attachments that have since been moved to another folder.
        let name = (decoded as NSString).lastPathComponent
        return index.allFiles.first { $0.url.lastPathComponent == name }?.url
    }
}

/// A fragment of one line of text. Inline math is an image that has to sit
/// *inside* the flow of a sentence, which `AttributedString` cannot express, so
/// runs are concatenated into a SwiftUI `Text` instead.
enum InlineRun {
    case styled(AttributedString)
    case math(NSImage)
}

/// A paragraph is a run of styled text interrupted by things that cannot live
/// inside an `AttributedString`: images, transclusions and display math.
enum ParagraphPiece: Identifiable {
    case text([InlineRun])
    case image(url: URL, width: CGFloat?, height: CGFloat?, alt: String)
    case mathBlock(NSImage, latex: String)
    case noteEmbed(NoteRef)
    case brokenEmbed(String)

    var id: String {
        switch self {
        case .text(let runs):
            "t:" + runs.map {
                switch $0 {
                case .styled(let s): String(s.characters.prefix(24))
                case .math: "⟨math⟩"
                }
            }.joined()
        case .image(let url, _, _, _): "i:\(url.path)"
        case .mathBlock(_, let latex): "m:\(latex)"
        case .noteEmbed(let ref): "n:\(ref.relativePath)"
        case .brokenEmbed(let name): "b:\(name)"
        }
    }
}

enum InlineText {

    /// Internal URL scheme used to route clicks in rendered text back into the
    /// app. Real `http(s)` links keep their own destination and open normally.
    static func heftURL(target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "heft"
        components.host = "follow"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url
    }

    static func pieces(
        _ inlines: [MDInline],
        context: RenderContext,
        baseFont: Font = Theme.body,
        mathPointSize: CGFloat = Theme.bodySize
    ) -> [ParagraphPiece] {
        var pieces: [ParagraphPiece] = []
        var runs: [InlineRun] = []
        var buffer = AttributedString()

        func sealBuffer() {
            if !buffer.characters.isEmpty {
                runs.append(.styled(buffer))
                buffer = AttributedString()
            }
        }
        func flush() {
            sealBuffer()
            if !runs.isEmpty {
                pieces.append(.text(runs))
                runs = []
            }
        }

        func append(_ list: [MDInline], _ style: Style) {
            for inline in list {
                switch inline {
                case .text(let s):
                    buffer += styled(s, style, baseFont)

                case .emphasis(let c):
                    append(c, style.with(italic: true))
                case .strong(let c):
                    append(c, style.with(bold: true))
                case .strikethrough(let c):
                    append(c, style.with(strike: true))
                case .highlight(let c):
                    append(c, style.with(highlight: true))

                case .code(let s):
                    var run = AttributedString(s)
                    run.font = Theme.mono
                    run.backgroundColor = Theme.codeBackground
                    if let link = style.link { run.link = link }
                    buffer += run

                case .link(let destination, let children):
                    let url = destination.flatMap { URL(string: $0) }
                    append(children, style.with(link: url, color: Theme.linkColor))

                case .wikiLink(let link):
                    let resolved = context.resolve(link)
                    let url = heftURL(target: linkTarget(link))
                    append(
                        [.text(link.displayText)],
                        style.with(
                            link: url,
                            color: resolved == nil ? Theme.unresolvedLinkColor : Theme.linkColor
                        )
                    )

                case .image(let source, let alt):
                    if let source, let url = context.resolveResource(source) {
                        flush()
                        pieces.append(.image(url: url, width: nil, height: nil, alt: alt))
                    } else {
                        buffer += styled(alt.isEmpty ? "🖼︎" : alt, style, baseFont)
                    }

                case .embed(let link):
                    flush()
                    pieces.append(embedPiece(link, context: context))

                case .math(let latex, let display):
                    let rendered = MathRenderer.image(
                        latex: latex,
                        fontSize: display ? mathPointSize + 3 : mathPointSize,
                        color: .textColor,
                        display: display
                    )
                    guard let rendered else {
                        // Unparseable LaTeX (often just mid-typing): show the
                        // source rather than dropping the content.
                        buffer += styled(display ? "$$\(latex)$$" : "$\(latex)$", style.with(highlight: false), Theme.mono)
                        continue
                    }
                    if display {
                        flush()
                        pieces.append(.mathBlock(rendered, latex: latex))
                    } else {
                        sealBuffer()
                        runs.append(.math(rendered))
                    }

                case .tag(let name):
                    var run = AttributedString("#\(name)")
                    run.font = baseFont
                    run.foregroundColor = Theme.tagColor
                    run.backgroundColor = Theme.tagBackground
                    buffer += run

                case .softBreak:
                    // Obsidian's default renders a single newline as a break.
                    buffer += AttributedString(context.strictLineBreaks ? " " : "\n")
                case .lineBreak:
                    buffer += AttributedString("\n")
                }
            }
        }

        append(inlines, Style())
        flush()
        return pieces
    }

    /// Renders `[[Target#Heading]]` back into the string form the model parses,
    /// so the click handler can re-resolve it without carrying extra state.
    private static func linkTarget(_ link: WikiLink) -> String {
        var s = link.target
        if let blockID = link.blockID { s += "#^\(blockID)" }
        else if let heading = link.heading { s += "#\(heading)" }
        return s
    }

    private static func embedPiece(_ link: WikiLink, context: RenderContext) -> ParagraphPiece {
        guard let ref = context.resolve(link) else { return .brokenEmbed(link.target) }
        switch ref.kind {
        case .image:
            return .image(
                url: ref.url,
                width: link.embedWidth.map(CGFloat.init),
                height: link.embedHeight.map(CGFloat.init),
                alt: link.alias ?? ref.name
            )
        case .markdown:
            return .noteEmbed(ref)
        default:
            return .brokenEmbed(ref.name)
        }
    }

    // MARK: - Styling

    private struct Style {
        var bold = false
        var italic = false
        var strike = false
        var highlight = false
        var link: URL?
        var color: Color?

        func with(
            bold: Bool? = nil, italic: Bool? = nil, strike: Bool? = nil,
            highlight: Bool? = nil, link: URL? = nil, color: Color? = nil
        ) -> Style {
            var copy = self
            if let bold { copy.bold = bold }
            if let italic { copy.italic = italic }
            if let strike { copy.strike = strike }
            if let highlight { copy.highlight = highlight }
            if let link { copy.link = link }
            if let color { copy.color = color }
            return copy
        }
    }

    private static func styled(_ string: String, _ style: Style, _ baseFont: Font) -> AttributedString {
        var run = AttributedString(string)
        var font = baseFont
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        run.font = font
        if style.strike { run.strikethroughStyle = .single }
        if style.highlight { run.backgroundColor = Theme.highlightBackground }
        if let color = style.color { run.foregroundColor = color }
        if let link = style.link { run.link = link }
        return run
    }
}

/// Small NSImage cache so scrolling a note with several embeds does not hit
/// the disk on every layout pass.
enum ImageCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 80
        return c
    }()

    static func image(at url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard url.isFileURL, let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func clear() { cache.removeAllObjects() }
}
