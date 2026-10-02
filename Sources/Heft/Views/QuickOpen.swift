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
    /// Scoped by default, like vault search. Scope used to be ignored here
    /// because a note outside the folder then looked as though it had fallen
    /// out of the index; the toggle and the row offering the rest of the
    /// vault are what say why it is missing.
    @State private var searchesEntireVault = false
    /// A heading chosen in the list: that order alone, in full, until it is
    /// chosen again or something is typed.
    @State private var only: QuickOpenOrder.Lead?
    /// The heading just chosen, drawn brighter for a moment so the choice
    /// visibly registered before the other rows fade.
    @State private var flashing: QuickOpenOrder.Lead?
    @FocusState private var isFocused: Bool
    /// Observed so a change in Settings redraws a switcher already open.
    @ObservedObject private var settings = GeneralSettings.shared

    private var isScoped: Bool { model.scopePath != nil && !searchesEntireVault }

    private var arranged: QuickOpenOrder.Arranged {
        model.quickOpenList(
            query, entireVault: searchesEntireVault, order: settings.quickOpenOrder, only: only
        )
    }

    private var results: [NoteRef] { arranged.all }
    private var rows: [QuickOpenOrder.Row] { arranged.rows }

    /// Matches outside the focused folder, offered when none are inside it.
    private var matchesElsewhere: Int {
        guard isScoped, results.isEmpty,
              !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { return 0 }
        return model.quickOpenResults(query, entireVault: true).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes, or paste a path", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onChange(of: query) {
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty { only = nil }
                        selectFirstNote()
                    }
                PaletteDismissButton(query: $query) { dismiss() }
                if model.scopePath != nil {
                    Button { searchesEntireVault.toggle(); selectFirstNote() } label: {
                        Image(systemName: searchesEntireVault ? "globe" : "scope")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(searchesEntireVault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(searchesEntireVault ? "Showing the entire vault" : "Showing \(model.scopeName)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    // At most 60 lightweight rows: eager layout avoids the
                    // retained-child behaviour LazyVStack exhibits in sheets.
                    VStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                            switch row {
                            case .heading(let kind):
                                HeadingRow(
                                    title: kind.title,
                                    hint: only == nil ? "Show All" : "Back",
                                    isSelected: index == selection,
                                    isFlashing: flashing == kind
                                )
                                .id(row)
                                .onTapGesture { selection = index; openSelection() }
                            case .note(let note):
                                ResultRow(note: note, isSelected: index == selection)
                                    .id(row)
                                    .onTapGesture { selection = index; openSelection() }
                                    // A result is a file, and dragging one out
                                    // beats opening it to find its path. The
                                    // gesture is simultaneous so a click still
                                    // opens it, and only fires once the pointer
                                    // has travelled.
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 6)
                                            .onChanged { _ in beginFileDrag(for: note.url) }
                                    )
                            }
                        }
                        if matchesElsewhere > 0 {
                            Button {
                                searchesEntireVault = true
                                selectFirstNote()
                            } label: {
                                Label(
                                    "None in \(model.scopeName). Show \(matchesElsewhere) in the entire vault",
                                    systemImage: "globe"
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    #if os(macOS)
                    .background(OverlayScrollerConfiguration())
                    #endif
                }
                // No anchor, so the list scrolls the least it can to reveal the
                // row and holds still while the selection is already visible.
                // Naming one asks for the row to be put *there* on every move,
                // which scrolls from the first arrow press and pins the
                // selection mid-list, unlike every other menu on the system.
                // Rows are identified by what they show, not where: choosing a
                // heading keeps the rows both lists share in place and fades
                // the rest, where an index identity replaced every row.
                .onChange(of: selection) {
                    if rows.indices.contains(selection) { proxy.scrollTo(rows[selection]) }
                }
            }
            // A sheet's scrolling subtree can retain its initial children even
            // while the query and surrounding controls update.
            // Give the result subtree query identity so filtering cannot show
            // stale empty-query rows.
            // Not keyed on a chosen heading: that change is animated row by
            // row instead of replacing the list.
            .id("\(query)#\(searchesEntireVault)#\(settings.quickOpenOrder)")
            .frame(height: PaletteMetrics.pickerListHeight)
        }
        .frame(width: PaletteMetrics.pickerWidth)
        .background(PaletteSheetBackground())
        .presentationBackground(.clear)
        .onAppear { isFocused = true; selectFirstNote() }
        .onChange(of: settings.quickOpenOrder) { selectFirstNote() }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    private func selectFirstNote() {
        selection = arranged.firstNoteRow
    }

    /// Return on a note opens it; on a heading it lists that order alone,
    /// and on that heading again goes back to both.
    private func openSelection() {
        guard rows.indices.contains(selection) else { return }
        switch rows[selection] {
        case .heading(let kind):
            // The flash is drawn in a turn of its own and then animated away
            // with the switch; set together, it would never be seen.
            flashing = kind
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) {
                    flashing = nil
                    only = only == kind ? nil : kind
                    selectFirstNote()
                }
            }
        case .note(let note):
            model.open(note)
            dismiss()
        }
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

/// A heading inside the list, styled as a sidebar section is. It is
/// selectable, so it says what Return will do once the arrows reach it.
private struct HeadingRow: View {
    @Environment(\.appAccent) private var accent

    let title: String
    let hint: String
    let isSelected: Bool
    var isFlashing = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            if isSelected {
                Text(hint).font(.system(size: 11))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected || isFlashing {
                RoundedRectangle(cornerRadius: 6).fill(accent)
                    .overlay(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isFlashing ? 0.35 : 0)))
            }
        }
        .contentShape(.rect)
        // The gap above a heading sits outside its highlight, or the label
        // is drawn low inside it.
        .padding(.top, 3)
    }
}

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
