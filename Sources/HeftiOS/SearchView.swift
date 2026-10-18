import HeftCore
import SwiftUI

/// Names first, ranked as ⌘T ranks them, then tags, then lines of text.
///
/// The Mac bar's model is bound to its session and commands, so this uses
/// the same `VaultIndex.scoredSearch` and `ContentSearch` underneath it
/// rather than the bar itself.
struct SearchView: View {
    @Environment(MobileVault.self) private var vault
    @State private var query = ""
    @State private var text: ContentSearchResult = .empty()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        List {
            if trimmed.isEmpty {
                Section("Recently Edited") {
                    ForEach(vault.index.notesByLastEdit.prefix(25)) { NoteRow(note: $0) }
                }
            } else {
                let names = vault.index.scoredSearch(
                    trimmed, limit: 30, familiarity: { vault.familiarity($0) }
                )
                if !names.isEmpty {
                    Section("Notes") {
                        ForEach(names, id: \.note.id) { NoteRow(note: $0.note) }
                    }
                }
                let tags = vault.index.tags(matching: tagQuery).prefix(8)
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(Array(tags), id: \.self) { tag in
                            NavigationLink(value: MobileRoute.tag(tag)) {
                                HStack {
                                    Text("#\(tag)")
                                    Spacer()
                                    Text("\(vault.index.noteCount(forTag: tag))")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if !text.matches.isEmpty {
                    Section(textHeading) {
                        ForEach(text.matches.prefix(100)) { match in
                            NavigationLink(value: MobileRoute.note(match.note.relativePath)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.note.name).font(.subheadline.weight(.semibold))
                                    Text(match.preview)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Notes, #tags, text")
        // The search tab collapses its field into the tab bar, which left the
        // tab looking like a list of recent notes; it opens ready to type.
        .searchFocused($fieldFocused)
        .task(id: "\(trimmed)#\(vault.generation)") {
            await searchText()
        }
        .onAppear {
            fieldFocused = true
            #if DEBUG
            if query.isEmpty, let preset = ProcessInfo.processInfo.environment["HEFT_IOS_QUERY"] {
                query = preset
            }
            #endif
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var tagQuery: String {
        trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }

    private var textHeading: String {
        let notes = text.matchedNotes
        return "In Text: \(notes) \(notes == 1 ? "note" : "notes")"
    }

    /// Reads every note, so it waits for typing to pause and runs off the
    /// main thread; a newer query cancels the older one by changing the id.
    private func searchText() async {
        let term = trimmed
        guard term.count >= 2, !term.hasPrefix("#") else {
            text = .empty()
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let notes = vault.index.notes
        let result = await Task.detached(priority: .userInitiated) {
            ContentSearch.run(notes: notes, query: term, limit: 200)
        }.value
        if !Task.isCancelled { text = result }
    }
}
