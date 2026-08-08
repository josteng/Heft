import HeftCore
import SwiftUI

/// Conservative fuzzy note-name switcher (⌘O).
struct QuickOpenView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var results: [NoteRef] { model.index.search(query, limit: 60) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onChange(of: query) { selection = 0 }
                PaletteDismissButton(query: $query) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, note in
                            ResultRow(note: note, isSelected: index == selection)
                                .id(index)
                                .onTapGesture { selection = index; openSelection() }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
        // Arrow keys move the selection while focus stays in the text field.
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func openSelection() {
        guard results.indices.contains(selection) else { return }
        model.open(results[selection])
        dismiss()
    }
}

private struct ResultRow: View {
    let note: NoteRef
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(note.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !note.folder.isEmpty {
                Text(note.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}
