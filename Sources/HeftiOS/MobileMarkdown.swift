import HeftCore
import SwiftUI
import UIKit

/// What rendering needs beyond the blocks: where links resolve from.
struct MarkdownContext {
    let index: VaultIndex
    let root: URL
    let note: NoteRef?
}

/// A rendered note, from `MarkdownModel`'s blocks.
///
/// Read-only, so unlike the Mac's live surface it has no reason to keep
/// markup in place: it draws the parsed document, the way the Mac's
/// presentation mode does.
struct MarkdownBlocksView: View {
    let blocks: [MDBlock]
    let context: MarkdownContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                BlockView(block: blocks[index], context: context)
            }
        }
    }
}

private struct BlockView: View {
    let block: MDBlock
    let context: MarkdownContext

    var body: some View {
        switch block {
        case .heading(let level, let inlines, _):
            Text(MarkdownInlines.attributed(inlines))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let inlines):
            ParagraphView(inlines: inlines, context: context)
        case .codeBlock(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        case .quote(let kind, let title, let blocks):
            QuoteView(kind: kind, title: title, blocks: blocks, context: context)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { offset in
                    let item = items[offset]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + offset, checked: item.checked)
                        MarkdownBlocksView(blocks: item.blocks, context: context)
                            .opacity(item.checked == true ? 0.55 : 1)
                    }
                }
            }
        case .table(let header, let rows, _):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(header.indices, id: \.self) {
                            Text(MarkdownInlines.attributed(header[$0])).bold()
                        }
                    }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) {
                                Text(MarkdownInlines.attributed(rows[row][$0]))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case .thematicBreak:
            Divider()
        case .html(let html):
            // Comments are how Heft and Obsidian leave markers in a note;
            // they are not meant to be read.
            if !html.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
                Text(html).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
        } else if ordered {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        default: .headline
        }
    }
}

private struct QuoteView: View {
    let kind: CalloutKind?
    let title: String?
    let blocks: [MDBlock]
    let context: MarkdownContext

    var body: some View {
        if let kind {
            VStack(alignment: .leading, spacing: 8) {
                Label(title ?? kind.rawValue.capitalized, systemImage: kind.symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                MarkdownBlocksView(blocks: blocks, context: context)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
        } else {
            MarkdownBlocksView(blocks: blocks, context: context)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tertiary).frame(width: 3)
                }
        }
    }

    private var tint: Color {
        switch kind {
        case .warning, .question: .orange
        case .failure, .danger, .bug: .red
        case .success, .todo: .green
        case .tip: .teal
        case .example: .purple
        case .quote: .gray
        default: .blue
        }
    }
}

/// A paragraph, split around its pictures: an image cannot sit inside a
/// `Text`, so each embedded one becomes a block of its own between runs.
private struct ParagraphView: View {
    let inlines: [MDInline]
    let context: MarkdownContext

    private enum Piece {
        case text([MDInline])
        case picture(URL)
    }

    var body: some View {
        let pieces = split()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pieces.indices, id: \.self) { index in
                switch pieces[index] {
                case .text(let run):
                    Text(MarkdownInlines.attributed(run))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .picture(let url):
                    EmbeddedPicture(url: url)
                }
            }
        }
    }

    private func split() -> [Piece] {
        var pieces: [Piece] = []
        var run: [MDInline] = []
        func flush() {
            let blank = run.allSatisfy {
                switch $0 {
                case .softBreak, .lineBreak: true
                case .text(let text): text.trimmingCharacters(in: .whitespaces).isEmpty
                default: false
                }
            }
            if !blank { pieces.append(.text(run)) }
            run = []
        }
        for inline in inlines {
            if let url = pictureURL(inline) {
                flush()
                pieces.append(.picture(url))
            } else {
                run.append(inline)
            }
        }
        flush()
        return pieces
    }

    private func pictureURL(_ inline: MDInline) -> URL? {
        switch inline {
        case .embed(let link):
            guard let ref = context.index.resolve(link, from: context.note), ref.kind == .image
            else { return nil }
            return ref.url
        case .image(let source?, _):
            if let url = URL(string: source), url.scheme == "https" || url.scheme == "http" {
                return url
            }
            let decoded = source.removingPercentEncoding ?? source
            let folder = context.note?.url.deletingLastPathComponent() ?? context.root
            return folder.appendingPathComponent(decoded)
        default:
            return nil
        }
    }
}

private struct EmbeddedPicture: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if url.isFileURL {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 120)
                }
            } else {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 120)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) {
            if url.isFileURL { image = await MobileImages.load(url) }
        }
    }
}

enum MobileImages {
    /// Loads off the main thread and through a coordinator, so a picture
    /// still in iCloud is fetched rather than drawn as nothing.
    static func load(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            var data: Data?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) {
                data = try? Data(contentsOf: $0)
            }
            return data.flatMap(UIImage.init(data:))
        }.value
    }
}

/// Inline markdown as an `AttributedString`, with links Heft handles itself.
///
/// A wikilink or a tag becomes an `x-heft:` link, which the note view's
/// `openURL` handler turns into navigation; anything else opens as usual.
enum MarkdownInlines {
    static let scheme = "x-heft"

    static func attributed(_ inlines: [MDInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { $0 += attributed($1) }
    }

    private static func attributed(_ inline: MDInline) -> AttributedString {
        switch inline {
        case .text(let text):
            return AttributedString(text)
        case .emphasis(let children):
            return adding(.emphasized, to: attributed(children))
        case .strong(let children):
            return adding(.stronglyEmphasized, to: attributed(children))
        case .strikethrough(let children):
            return adding(.strikethrough, to: attributed(children))
        case .highlight(let children, let color):
            var text = attributed(children)
            text.backgroundColor = highlight(color).opacity(0.3)
            return text
        case .code(let code):
            var text = AttributedString(code)
            text.inlinePresentationIntent = .code
            text.backgroundColor = Color.secondary.opacity(0.15)
            return text
        case .link(let destination, let children):
            var text = attributed(children)
            if let destination { text.link = linkURL(destination) }
            return text
        case .image(_, let alt):
            return AttributedString(alt)
        case .wikiLink(let link), .embed(let link):
            var text = AttributedString(link.displayText)
            text.link = noteURL(link)
            return text
        case .math(let source, _):
            var text = AttributedString(source)
            text.inlinePresentationIntent = .code
            return text
        case .tag(let tag):
            var text = AttributedString("#\(tag)")
            text.link = url(host: "tag", items: ["name": tag])
            return text
        case .softBreak:
            return AttributedString(" ")
        case .lineBreak:
            return AttributedString("\n")
        }
    }

    private static func adding(_ intent: InlinePresentationIntent,
                               to text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            let existing = text[run.range].inlinePresentationIntent ?? []
            text[run.range].inlinePresentationIntent = existing.union(intent)
        }
        return text
    }

    private static func highlight(_ color: HighlightColor?) -> Color {
        switch color {
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .yellow, nil: .yellow
        }
    }

    /// A markdown link to a file in the vault (`[x](Folder/Note.md)`) is a
    /// note link too; only a link with a scheme leaves the app.
    private static func linkURL(_ destination: String) -> URL? {
        if let url = URL(string: destination), url.scheme != nil { return url }
        let decoded = destination.removingPercentEncoding ?? destination
        let parts = decoded.split(separator: "#", maxSplits: 1).map(String.init)
        let target = parts.first.map { ($0 as NSString).deletingPathExtension } ?? ""
        return noteURL(WikiLink(target: target, heading: parts.count > 1 ? parts[1] : nil))
    }

    static func noteURL(_ link: WikiLink) -> URL? {
        var items = ["target": link.target]
        if let heading = link.heading { items["heading"] = heading }
        return url(host: "link", items: items)
    }

    private static func url(host: String, items: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    /// The link a tapped `x-heft:` URL stands for.
    enum Target {
        case note(WikiLink)
        case tag(String)
    }

    static func target(of url: URL) -> Target? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        switch url.host {
        case "link":
            return .note(WikiLink(target: value("target") ?? "", heading: value("heading")))
        case "tag":
            return value("name").map(Target.tag)
        default:
            return nil
        }
    }
}
