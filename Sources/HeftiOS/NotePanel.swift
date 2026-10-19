import HeftCore
import SwiftUI

/// The note's headings, each indented under the one it sits in, the
/// reader's own marked. A tap goes there.
struct OutlineList: View {
    let document: NoteDocument
    let choose: (NoteOutline.Entry) -> Void

    var body: some View {
        let entries = document.outline.entries
        ScrollViewReader { proxy in
            List {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button { choose(entry) } label: {
                        Text(entry.title.isEmpty ? "Untitled heading" : entry.title)
                            .font(entry.depth == 0 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(entry.title.isEmpty ? .tertiary : .primary)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(min(entry.depth, 5)) * 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // A wash, as a chosen row in the lists has, rather than
                    // the accent, which read as a link.
                    .listRowBackground(index == document.outlineCurrent ? Color.primary.opacity(0.08) : Color.clear)
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Headings", systemImage: "list.bullet.indent",
                                           description: Text("This note's headings are listed here."))
                }
            }
            .onAppear {
                document.watchOutline()
                if let current = document.outlineCurrent, entries.indices.contains(current) {
                    proxy.scrollTo(entries[current].id, anchor: .center)
                }
            }
            .onDisappear { document.unwatchOutline() }
            // The reader's heading kept in sight as the note moves beside it.
            .onChange(of: document.outlineCurrent) { _, current in
                guard let current, entries.indices.contains(current) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(entries[current].id) }
            }
        }
    }
}

/// The iPad's panel beside a note, as the Mac's right sidebar: the note's
/// Outline, or the notes that link to it.
struct NotePanelView: View {
    let document: NoteDocument
    let backlinks: [Backlink]
    let openNote: (String) -> Void
    @State private var preferences = BrowsingPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $preferences.notePanel) {
                ForEach(BrowsingPreferences.NotePanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.symbol).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            switch preferences.notePanel {
            case .outline:
                OutlineList(document: document) { document.reveal($0) }
            case .backlinks:
                ScrollView {
                    if backlinks.isEmpty {
                        ContentUnavailableView("No Links Here", systemImage: "arrow.uturn.left",
                                               description: Text("Notes that link to this one are listed here."))
                    } else {
                        BacklinksView(backlinks: backlinks, open: openNote)
                            .padding(16)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The note open in the iPad's note pane, for the panel beside it.
struct PanelNote: Equatable {
    let document: NoteDocument
    static func == (a: Self, b: Self) -> Bool { a.document === b.document }
}

struct PanelNoteKey: PreferenceKey {
    static let defaultValue: PanelNote? = nil
    static func reduce(value: inout PanelNote?, nextValue: () -> PanelNote?) {
        value = nextValue() ?? value
    }
}
