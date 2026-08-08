import AppKit
import HeftCore
import SwiftUI

/// Whether rendered text may be selected with the mouse.
///
/// In the block editor it must not be: SwiftUI's text selection consumes mouse
/// events before a tap gesture sees them, so a selectable paragraph can never
/// be clicked into for editing. Selection there comes from entering the block.
private struct MarkdownSelectableKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var markdownTextSelectable: Bool {
        get { self[MarkdownSelectableKey.self] }
        set { self[MarkdownSelectableKey.self] = newValue }
    }

    var markdownFontScale: CGFloat {
        get { self[MarkdownFontScaleKey.self] }
        set { self[MarkdownFontScaleKey.self] = newValue }
    }
}

private struct MarkdownFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private enum HeadingBaselineAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[.firstTextBaseline]
    }
}

private extension VerticalAlignment {
    static let headingBaseline = VerticalAlignment(HeadingBaselineAlignment.self)
}

private extension View {
    /// `.enabled` and `.disabled` are distinct types, so this cannot be a
    /// ternary — it needs two branches.
    @ViewBuilder
    func markdownSelectable(_ enabled: Bool) -> some View {
        if enabled { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

/// Renders a parsed note. Recursive through quotes, lists and transclusions.
struct MarkdownView: View {
    let blocks: [MDBlock]
    let context: RenderContext
    var embedDepth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, context: context, embedDepth: embedDepth)
            }
        }
    }
}

private struct BlockView: View {
    let block: MDBlock
    let context: RenderContext
    let embedDepth: Int
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        switch block {
        case .heading(let level, let inlines, _):
            ParagraphView(
                inlines: inlines,
                context: context,
                font: Theme.heading(level, scale: fontScale),
                embedDepth: embedDepth
            )
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .headingBaseline)) {
                if context.colorfulFormatting {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.headingAccent(level))
                        .frame(
                            width: 3,
                            height: Theme.headingCapHeight(level, scale: fontScale)
                        )
                        .alignmentGuide(.headingBaseline) { dimensions in
                            dimensions[.bottom]
                        }
                        .offset(x: -12)
                }
            }
            .padding(.top, Theme.headingTopPadding(level))

        case .paragraph(let inlines):
            ParagraphView(
                inlines: inlines,
                context: context,
                font: Theme.body(scale: fontScale),
                embedDepth: embedDepth
            )

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .quote(let kind, let title, let blocks):
            if let kind {
                CalloutView(kind: kind, title: title ?? "", blocks: blocks, context: context, embedDepth: embedDepth)
            } else {
                QuoteView(blocks: blocks, context: context, embedDepth: embedDepth)
            }

        case .list(let ordered, let start, let items):
            ListView(ordered: ordered, start: start, items: items, context: context, embedDepth: embedDepth)

        case .table(let header, let rows, let alignments):
            TableView(header: header, rows: rows, alignments: alignments, context: context)

        case .thematicBreak:
            Divider().padding(.vertical, 6)

        case .html(let raw):
            // Raw HTML is shown as source rather than rendered: a WebView per
            // block would defeat the point of the app being instant.
            Text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.mono(scale: fontScale))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground, in: .rect(cornerRadius: 6))
        }
    }
}

// MARK: - Paragraph

private struct ParagraphView: View {
    let inlines: [MDInline]
    let context: RenderContext
    let font: Font
    let embedDepth: Int
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        PieceStack(
            pieces: InlineText.pieces(inlines, context: context, baseFont: font),
            context: context,
            embedDepth: embedDepth,
            fontScale: fontScale
        )
    }
}

/// Renders a paragraph's pieces. Shared by body paragraphs and table cells so
/// that an image embedded in a cell renders as an image rather than being
/// silently dropped, which is how charts-in-a-table notes are written.
private struct PieceStack: View {
    let pieces: [ParagraphPiece]
    let context: RenderContext
    let embedDepth: Int
    var spacing: CGFloat = 10
    /// Body paragraphs claim the full measure; table cells must not, or every
    /// column stretches and the row grows far beyond its content.
    var fillWidth: Bool = true
    var fontScale: CGFloat = 1

    @Environment(\.markdownTextSelectable) private var isSelectable

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(pieces) { piece in
                switch piece {
                case .text(let runs):
                    Self.concatenated(runs)
                        .lineSpacing(Theme.lineSpacing * fontScale)
                        .markdownSelectable(isSelectable)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)

                case .image(let url, let width, let height, let alt):
                    EmbeddedImage(url: url, width: width, height: height, alt: alt)

                case .mathBlock(let image, _):
                    // Display math gets its own centred line, as in LaTeX.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: image.size.width, height: image.size.height)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)

                case .noteEmbed(let ref):
                    TransclusionView(ref: ref, context: context, embedDepth: embedDepth)

                case .brokenEmbed(let name):
                    Label("Missing attachment: \(name)", systemImage: "questionmark.square.dashed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBackground, in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    /// Inline math is an image spliced into the sentence, which only `Text`
    /// concatenation can express.
    private static func concatenated(_ runs: [InlineRun]) -> Text {
        // Interpolation rather than `Text + Text`, which is deprecated on
        // macOS 26. Both `AttributedString` and `Image` interpolate directly.
        runs.reduce(Text(verbatim: "")) { accumulated, run in
            switch run {
            case .styled(let attributed):
                Text("\(accumulated)\(attributed)")
            case .math(let image):
                Text("\(accumulated)\(Image(nsImage: image))")
            }
        }
    }
}

private struct EmbeddedImage: View {
    let url: URL
    let width: CGFloat?
    let height: CGFloat?
    let alt: String

    var body: some View {
        Group {
            if let image = ImageCache.image(at: url) {
                // Both dimensions are pinned. A resizable image given only a
                // maxWidth still reports its intrinsic height as the ideal, so
                // the row reserves hundreds of points of empty space.
                let natural = image.size
                let displayWidth = width ?? min(natural.width, Theme.contentMaxWidth)
                let ratio = natural.width > 0 ? natural.height / natural.width : 0.618
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth, height: height ?? (displayWidth * ratio))
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }
}

/// `![[Another Note]]` rendered inline. Depth-limited: a note that embeds
/// itself, directly or in a cycle, must not recurse forever.
private struct TransclusionView: View {
    let ref: NoteRef
    let context: RenderContext
    let embedDepth: Int

    private static let maxDepth = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ref.name, systemImage: "doc.text")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if embedDepth >= Self.maxDepth {
                Text("Embed nested too deeply")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let source = try? String(contentsOf: ref.url, encoding: .utf8) {
                let parsed = MarkdownModel.parse(source)
                MarkdownView(
                    blocks: parsed.blocks,
                    context: RenderContext(
                        index: context.index,
                        current: ref,
                        vaultRoot: context.vaultRoot,
                        colorfulFormatting: context.colorfulFormatting
                    ),
                    embedDepth: embedDepth + 1
                )
            } else {
                Text("Could not read \(ref.relativePath)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
    }
}

// MARK: - Code

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var didCopy = false
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language.uppercased())
                        .font(.system(size: 10 * fontScale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10 * fontScale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .opacity(language == nil && !didCopy ? 0.5 : 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeSyntaxHighlighting.attributed(code: code, language: language))
                    .font(Theme.mono(scale: fontScale))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Quotes and callouts

private struct QuoteView: View {
    let blocks: [MDBlock]
    let context: RenderContext
    let embedDepth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tertiary)
                .frame(width: 3)
            MarkdownView(blocks: blocks, context: context, embedDepth: embedDepth)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CalloutView: View {
    let kind: CalloutKind
    let title: String
    let blocks: [MDBlock]
    let context: RenderContext
    let embedDepth: Int
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        let tint = Theme.calloutTint(kind)
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: kind.symbol)
                .font(.system(size: Theme.bodySize * fontScale, weight: .semibold))
                .foregroundStyle(tint)
            if !blocks.isEmpty {
                MarkdownView(blocks: blocks, context: context, embedDepth: embedDepth)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
                .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
        }
    }
}

// MARK: - Lists

private struct ListView: View {
    let ordered: Bool
    let start: Int
    let items: [MDListItem]
    let context: RenderContext
    let embedDepth: Int
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item, at: offset)
                        .frame(minWidth: 18, alignment: .trailing)
                    MarkdownView(blocks: item.blocks, context: context, embedDepth: embedDepth)
                        .strikethrough(item.checked == true, color: .secondary)
                        .foregroundStyle(item.checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(for item: MDListItem, at offset: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .font(.system(size: Theme.bodySize * fontScale))
        } else if ordered {
            Text("\(start + offset).")
                .font(Theme.body(scale: fontScale).monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(Theme.body(scale: fontScale))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tables

private struct TableView: View {
    let header: [[MDInline]]
    let rows: [[[MDInline]]]
    let alignments: [MDColumnAlignment]
    let context: RenderContext
    @Environment(\.markdownFontScale) private var fontScale

    var body: some View {
        // Tables are the one block that legitimately exceeds the measure, so
        // it scrolls inside itself rather than widening the whole column.
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, index: index, bold: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, index: index, bold: false)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.codeBackground.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private func cellView(_ cell: [MDInline], index: Int, bold: Bool) -> some View {
        PieceStack(
            pieces: InlineText.pieces(
                cell,
                context: context,
                baseFont: bold ? Theme.body(scale: fontScale).bold() : Theme.body(scale: fontScale),
                mathPointSize: Theme.bodySize * fontScale,
                fontScale: fontScale
            ),
            context: context,
            embedDepth: 0,
            spacing: 6,
            fillWidth: false,
            fontScale: fontScale
        )
        .frame(alignment: alignment(index))
    }

    private func alignment(_ index: Int) -> Alignment {
        switch alignments.indices.contains(index) ? alignments[index] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
