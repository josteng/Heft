import HeftCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Conservative fuzzy note-name switcher (⌘O).
struct QuickOpenView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var results: [NoteRef] {
        // Quick Open is a vault-wide switcher. Restricting it to a window's
        // focused folder made existing notes look as though they had fallen
        // out of the index, with no indication that scope was the reason.
        model.index.search(query, limit: 60)
    }

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
                    // At most 60 lightweight rows: eager layout avoids the
                    // retained-child behaviour LazyVStack exhibits in sheets.
                    VStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, note in
                            ResultRow(note: note, isSelected: index == selection)
                                .id(index)
                                .onTapGesture { selection = index; openSelection() }
                        }
                    }
                    .padding(6)
                    #if os(macOS)
                    .background(OverlayScrollerConfiguration())
                    #endif
                }
                .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
            }
            // A sheet's scrolling subtree can retain its initial children even
            // while the query and surrounding controls update.
            // Give the result subtree query identity so filtering cannot show
            // stale empty-query rows.
            .id(query)
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
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

#if os(macOS)
/// SwiftUI follows the system's scrollbar preference, which can select a
/// space-taking legacy scroller. A palette needs the macOS overlay treatment:
/// visible while scrolling, faded at rest, and never part of row geometry.
private struct OverlayScrollerConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? ConfiguringView)?.configureScroller()
    }

    private final class ConfiguringView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureNowOrRetry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureNowOrRetry()
        }

        @discardableResult
        func configureScroller() -> Bool {
            guard let scrollView = enclosingScrollView else { return false }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = true
            scrollView.verticalScroller?.controlSize = .small
            return true
        }

        private func configureNowOrRetry() {
            // `viewDidMoveToSuperview` normally has the NSScrollView ancestor
            // already, which lets us set overlay style before the first frame.
            // Keep one next-turn retry for SwiftUI hierarchy changes where the
            // representable is attached from the inside out.
            guard !configureScroller() else { return }
            DispatchQueue.main.async { [weak self] in
                self?.configureScroller()
            }
        }
    }
}
#endif

private struct ResultRow: View {
    @Environment(\.appAccent) private var accent

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
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}
