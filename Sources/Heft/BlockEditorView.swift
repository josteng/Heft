import AppKit
import HeftCore
import SwiftUI

/// The single editing surface: the preview renderer, made editable.
///
/// Every block renders exactly as it does when reading. Clicking one swaps it
/// for its markdown source; leaving it splices the source back into the file by
/// line range, so the rest of the note stays byte-identical.
///
/// This is the only way to get block-level layout — rounded tables, per-block
/// padding, rules under headings, callout cards — into an editor. A text engine
/// styles a single run of characters and cannot express any of it.
struct BlockEditorView: View {
    @EnvironmentObject private var model: AppModel

    @State private var document = MDDocument(frontmatter: nil, blocks: [], lineRanges: [])
    @State private var focused: Int?
    @State private var draft = ""
    @State private var draftHeight: CGFloat = 24
    /// Click location inside the block just focused, used to seat the caret.
    @State private var caretPoint: CGPoint?

    private var context: RenderContext {
        RenderContext(
            index: model.index, current: model.current, vaultRoot: model.vaultRoot,
            strictLineBreaks: model.settings.strictLineBreaks
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.blockSpacing) {
                if let frontmatter = document.frontmatter, !frontmatter.isEmpty {
                    FrontmatterCard(yaml: frontmatter)
                }

                ForEach(document.blocks.indices, id: \.self) { index in
                    row(at: index)
                }

                // Clicking past the end puts the caret in the last block, the
                // way a text editor would.
                Color.clear
                    .frame(height: 120)
                    .contentShape(.rect)
                    .onTapGesture { focus(document.blocks.count - 1) }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, Theme.verticalPadding)
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Selectable text would eat the click that focuses a block.
        .environment(\.markdownTextSelectable, false)
        .task(id: model.documentGeneration) { reparse() }
        .onChange(of: model.text) { if focused == nil { reparse() } }
    }

    @ViewBuilder
    private func row(at index: Int) -> some View {
        if focused == index {
            BlockSourceField(
                text: $draft,
                height: $draftHeight,
                isFocused: true,
                font: editorFont(for: document.blocks[index]),
                caretPoint: caretPoint,
                onMoveOut: { direction in commit(); focus(index + direction) },
                onSplit: { head, tail in split(index, head: head, tail: tail) },
                onMergeBack: { mergeBack(index) },
                onCommit: { commit() }
            )
            .frame(height: draftHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // No padding or border here: any box around the focused block
            // changes its size and shoves the rest of the document around as
            // the caret moves. The affordance is painted *outside* the layout
            // instead — a background and a bar in the left margin, neither of
            // which occupies space.
            // Just the margin bar, no filled box: the fill read as noise on
            // every keystroke, and the caret plus the bar is enough to say
            // which block is live.
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                    .padding(.vertical, -5)
                    .offset(x: -18)
            }
        } else {
            BlockRow(block: document.blocks[index], context: context)
                .contentShape(.rect)
                // Rendered blocks are editable, so the pointer has to say so.
                .pointerStyle(.horizontalText)
                // SpatialTapGesture rather than onTapGesture: it reports where
                // the click landed, which is what seats the caret.
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in focus(index, at: value.location) }
                )
        }
    }

    // MARK: - Editing

    private func reparse() {
        document = MarkdownModel.parseDocument(model.text)
    }

    private func focus(_ index: Int, at point: CGPoint? = nil) {
        guard document.blocks.indices.contains(index) else { return }
        commit()
        draft = document.source(ofBlock: index, in: model.text) ?? ""
        caretPoint = point
        focused = index
    }

    /// Writes the draft back into the file and re-renders.
    private func commit() {
        guard let index = focused,
              let original = document.source(ofBlock: index, in: model.text),
              original != draft,
              let updated = document.replacing(block: index, with: draft, in: model.text)
        else { return }
        model.text = updated
        document = MarkdownModel.parseDocument(updated)
    }

    /// Matches the font the rendered block uses, so focus never reflows.
    private func editorFont(for block: MDBlock) -> NSFont {
        guard case .heading(let level, _, _) = block else { return Theme.blockEditorFont }
        let sizes: [CGFloat] = [28, 22, 18, 16, 15, 14]
        return NSFont.systemFont(
            ofSize: sizes[min(max(level, 1), 6) - 1],
            weight: level <= 2 ? .bold : .semibold
        )
    }

    /// Leading list marker of `line`, e.g. "- ", "- [ ] ", "3. " — used to keep
    /// a list going when Enter starts the next item, the way every editor does.
    private func listMarker(continuing line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let match = rest.range(of: #"^([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#,
                                  options: .regularExpression) {
            // A new task starts unchecked, never inheriting a tick.
            return indent + rest[match].replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]")
        }
        return ""
    }

    private func split(_ index: Int, head: String, tail: String) {
        let marker = listMarker(continuing: head.components(separatedBy: "\n").last ?? head)
        // A list continues into the next item; prose gets a blank line between.
        let joiner = marker.isEmpty ? "\n\n" : "\n"
        guard let updated = document.replacing(
            block: index, with: head + joiner + marker + tail, in: model.text
        ) else { return }
        model.text = updated
        document = MarkdownModel.parseDocument(updated)
        focus(min(index + 1, document.blocks.count - 1))
    }

    private func mergeBack(_ index: Int) {
        guard index > 0 else { return }
        commit()
        // Join this block onto the previous one, then put the caret in it.
        guard let previous = document.source(ofBlock: index - 1, in: model.text),
              let current = document.source(ofBlock: index, in: model.text),
              let withoutCurrent = document.replacing(block: index, with: "", in: model.text)
        else { return }
        let rejoined = MarkdownModel.parseDocument(withoutCurrent)
        guard let updated = rejoined.replacing(
            block: index - 1, with: previous + "\n" + current, in: withoutCurrent
        ) else { return }
        model.text = updated
        document = MarkdownModel.parseDocument(updated)
        focus(index - 1)
    }
}

/// One rendered block, reusing the reading renderer verbatim.
private struct BlockRow: View {
    let block: MDBlock
    let context: RenderContext

    var body: some View {
        MarkdownView(blocks: [block], context: context)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FrontmatterCard: View {
    let yaml: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(yaml)
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Properties", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.codeBackground.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}
