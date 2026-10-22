import HeftCore
import SwiftUI
import UIKit

/// Aa on the iPad: the phone's format panel as a popover from the note's
/// toolbar, as Notes has it there. The same tools, sent to the same editor
/// through `NoteDocument`, so what each writes is the phone's.
struct FormatButton: View {
    let document: NoteDocument
    @State private var showing = false

    var body: some View {
        Button("Format", systemImage: "textformat") { showing = true }
            .tint(.primary)
            .popover(isPresented: $showing) {
                FormatPopover(document: document)
                    .presentationCompactAdaptation(.popover)
            }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.environment["HEFT_IOS_PAD_FORMAT"] != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showing = true
            }
            #endif
    }
}

struct FormatPopover: View {
    let document: NoteDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = document.formatState
        VStack(alignment: .leading, spacing: 14) {
            // Closed from here as well as by tapping away, as Notes' panel is.
            HStack {
                Text("Format").font(.title3.bold())
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.fill.tertiary, in: .circle)
                    .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                style(.title, "Title", .title2.bold(), on: state.headingLevel == 1)
                style(.heading, "Heading", .title3.bold(), on: state.headingLevel == 2)
                style(.subheading, "Subheading", .headline, on: state.headingLevel == 3)
                style(.body, "Body", .body, on: state.headingLevel == 0)
            }
            HStack(spacing: 10) {
                group([
                    (.bold, "bold", "Bold"), (.italic, "italic", "Italic"),
                    (.strikethrough, "strikethrough", "Strikethrough"),
                    (.code, "chevron.left.forwardslash.chevron.right", "Code"),
                ], state: state)
                HStack(spacing: 1) {
                    segment(.highlight, "highlighter", "Highlight", on: state.inline.contains(.highlight))
                    colorMenu
                }
                .clipShape(.capsule)
            }
            HStack(spacing: 10) {
                group([(.task, "checklist", "Task"), (.bullets, "list.bullet", "Bulleted List"),
                       (.numbers, "list.number", "Numbered List")], state: state)
                group([(.outdent, "decrease.indent", "Outdent"), (.indent, "increase.indent", "Indent")], state: state)
                group([(.quote, "text.quote", "Quote"), (.callout, "exclamationmark.bubble", "Callout")], state: state)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private func style(_ tool: FormatTool, _ title: String, _ font: Font, on: Bool) -> some View {
        Button { document.format(tool) } label: {
            Text(title)
                .font(font)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func group(_ tools: [(FormatTool, String, String)], state: FormatState) -> some View {
        HStack(spacing: 1) {
            ForEach(tools.indices, id: \.self) { index in
                let (tool, symbol, label) = tools[index]
                segment(tool, symbol, label, on: isOn(tool, state))
            }
        }
        .clipShape(.capsule)
    }

    private func segment(_ tool: FormatTool, _ symbol: String, _ label: String, on: Bool) -> some View {
        Button { document.format(tool) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The highlighter's colour, as on the phone: choosing one recolours the
    /// highlight at the caret and the ones after it.
    private var colorMenu: some View {
        let current = document.highlightColor
        return Menu {
            ForEach([nil] + HighlightColor.allCases.map(Optional.some), id: \.self) { color in
                Button {
                    document.format(.color(color))
                } label: {
                    Label {
                        Text(color?.title ?? "Default")
                    } icon: {
                        Image(uiImage: UIImage(systemName: "circle.fill")!
                            .withTintColor(Theme.highlightSwatch(color ?? .yellow), renderingMode: .alwaysOriginal))
                    }
                }
            }
        } label: {
            Image(systemName: "circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: Theme.highlightSwatch(current ?? .yellow)))
                .frame(width: 48, height: 44)
                .background(.fill.tertiary)
        }
        .accessibilityLabel("Highlight Colour")
    }

    private func isOn(_ tool: FormatTool, _ state: FormatState) -> Bool {
        switch tool {
        case .quote: state.quoted
        case .task, .bullets, .numbers: state.list == tool
        default: state.inline.contains(tool)
        }
    }
}

/// The note's tools in the iPad's bar: Aa, a checklist, and a picture or
/// file, the three Notes keeps there.
struct PadNoteTools: ToolbarContent {
    let document: NoteDocument

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            FormatButton(document: document)
            Button("Checklist", systemImage: "checklist") { document.format(.task) }
                .tint(.primary)
            Menu("Add Photo or File", systemImage: "photo.on.rectangle") {
                ForEach(AttachSource.available, id: \.self) { source in
                    Button(source.title, systemImage: source.symbol) {
                        if document.textView?.isFirstResponder == false { document.textView?.becomeFirstResponder() }
                        document.attach(source)
                    }
                }
            }
            .tint(.primary)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }
}

/// Link, tag and callout suggestions at the foot of the note on the iPad,
/// above the keyboard, where on the phone the keyboard's strip has them.
struct SuggestionBar: View {
    let document: NoteDocument

    var body: some View {
        let chips = document.suggestionChips
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(chips.indices, id: \.self) { index in
                    let chip = chips[index]
                    Button { document.acceptSuggestion(index) } label: {
                        HStack(spacing: 6) {
                            if let symbol = chip.symbol {
                                Image(systemName: symbol)
                                    .foregroundStyle(chip.tint.map { AnyShapeStyle(Color(uiColor: $0)) } ?? AnyShapeStyle(.primary))
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(chip.title).font(.subheadline).lineLimit(1)
                                if !chip.detail.isEmpty {
                                    Text(chip.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 240)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 52)
        .glassEffect(in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
