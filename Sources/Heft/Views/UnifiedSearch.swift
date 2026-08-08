import AppKit
import HeftCore
import SwiftUI

/// One row of the unified palette.
///
/// Notes, commands and text hits share a list rather than living behind three
/// separate shortcuts, because at the moment of typing the user knows *what*
/// they want, not which of the app's indexes happens to hold it.
enum SearchItem: Identifiable {
    case note(NoteRef)
    case command(AppCommand)
    case content(ContentMatch)

    var id: String {
        switch self {
        case .note(let note): "note:\(note.relativePath)"
        case .command(let command): "cmd:\(command.id)"
        case .content(let match): "hit:\(match.id)"
        }
    }
}

/// Which kinds of result a query is asking for.
///
/// The prefixes match Obsidian's, so the muscle memory carries over: `>` runs a
/// command, `#` finds a tag, and anything else searches everything.
enum SearchScope {
    case everything
    case commands
    case tags

    /// Splits a raw field value into a scope and the term inside it.
    static func parse(_ raw: String) -> (scope: SearchScope, term: String) {
        if raw.hasPrefix(">") {
            return (.commands, String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        if raw.hasPrefix("#") {
            return (.tags, String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return (.everything, raw.trimmingCharacters(in: .whitespaces))
    }

    var placeholder: String {
        switch self {
        case .everything: "Search notes, commands and content"
        case .commands: "Run a command"
        case .tags: "Find a tag"
        }
    }
}

struct UnifiedSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    /// Content results arrive late; keeping them keyed by the term they answer
    /// stops a stale set from being shown against a newer query.
    @State private var content = ContentSearchResult.empty()
    @State private var isSearchingContent = false
    @FocusState private var isFocused: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    private var parsed: (scope: SearchScope, term: String) { SearchScope.parse(query) }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
        }
        .frame(width: 640)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task(id: query) { await searchContent() }
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary)
            TextField(parsed.scope.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isFocused)
                .onSubmit(runSelection)
                .onChange(of: query) { selection = 0 }
            if isSearchingContent {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var icon: String {
        switch parsed.scope {
        case .everything: "magnifyingglass"
        case .commands: "chevron.right.2"
        case .tags: "number"
        }
    }

    @ViewBuilder
    private var results: some View {
        let items = self.items
        ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty, !parsed.term.isEmpty, !isSearchingContent {
                    ContentUnavailableView.search(text: parsed.term)
                        .padding(.vertical, 60)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SearchRow(
                                item: item, term: parsed.term,
                                isSelected: index == selection,
                                isEnabled: isEnabled(item)
                            )
                            .id(index)
                            .onTapGesture {
                                selection = index
                                runSelection()
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 380)
    }

    /// Ranked results.
    ///
    /// Names before commands before content: a name match is nearly always the
    /// thing wanted, and content hits are both the slowest to arrive and the
    /// most numerous, so letting them near the top would push everything else
    /// off the first screen.
    private var items: [SearchItem] {
        let (scope, term) = parsed

        switch scope {
        case .commands:
            return AppCommand.registry.filter { $0.matches(term) }.map(SearchItem.command)

        case .tags:
            return model.index.tags(matching: term)
                .prefix(40)
                .flatMap { tag in model.index.notes(taggedWith: tag).map(SearchItem.note) }

        case .everything:
            guard !term.isEmpty else {
                // An empty palette is a recents list, not a dump of the vault.
                return model.recentNotes.prefix(12).map(SearchItem.note)
            }
            let notes = model.index.search(term, limit: 20).map(SearchItem.note)
            let commands = AppCommand.registry
                .filter { $0.matches(term) }
                .map(SearchItem.command)
            // Content hits in a note already listed by name would be a second
            // row for the same destination.
            let named = Set(model.index.search(term, limit: 20).map(\.relativePath))
            let hits = (content.query == term ? content.matches : [])
                .filter { !named.contains($0.note.relativePath) }
                .prefix(30)
                .map(SearchItem.content)
            return notes + commands + hits
        }
    }

    private func isEnabled(_ item: SearchItem) -> Bool {
        if case .command(let command) = item { return command.isEnabled(on: model) }
        return true
    }

    private func searchContent() async {
        let (scope, term) = parsed
        guard scope == .everything, term.count >= 2 else {
            isSearchingContent = false
            content = .empty()
            return
        }
        isSearchingContent = true
        // Long enough that typing a word does not launch a scan per keystroke.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        let notes = model.index.notes
        let result = await Task.detached(priority: .userInitiated) {
            ContentSearch.run(notes: notes, query: term, limit: 60)
        }.value
        guard !Task.isCancelled, SearchScope.parse(query).term == term else { return }
        content = result
        isSearchingContent = false
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func runSelection() {
        let items = self.items
        guard items.indices.contains(selection) else { return }
        switch items[selection] {
        case .note(let note):
            model.open(note)
        case .command(let command):
            guard command.isEnabled(on: model) else { return }
            command.perform(on: model)
        case .content(let match):
            model.open(match.note, revealingLine: match.line)
        }
        dismiss()
    }
}

private struct SearchRow: View {
    let item: SearchItem
    let term: String
    let isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(.white.opacity(0.75))
                                    : AnyShapeStyle(.tertiary)
                            )
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                if case .content(let match) = item {
                    highlighted(match.preview)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(.white.opacity(0.85))
                                : AnyShapeStyle(.secondary)
                        )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(.rect)
    }

    private var symbol: String {
        switch item {
        case .note: "doc.text"
        case .command(let command): command.symbol
        case .content: "text.magnifyingglass"
        }
    }

    private var title: String {
        switch item {
        case .note(let note): note.name
        case .command(let command): command.title
        case .content(let match): match.note.name
        }
    }

    private var trailing: String? {
        switch item {
        case .note(let note): note.folder.isEmpty ? nil : note.folder
        case .command(let command): command.shortcut?.display
        case .content(let match):
            match.occurrences > 1 ? "Line \(match.line) · \(match.occurrences)" : "Line \(match.line)"
        }
    }

    private func highlighted(_ plain: String) -> Text {
        var result = AttributedString(plain)
        guard !term.isEmpty else { return Text(result) }
        var cursor = plain.startIndex
        while cursor < plain.endIndex,
              let range = plain.range(
                of: term, options: .caseInsensitive, range: cursor..<plain.endIndex
              ),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].font = .system(size: 11, weight: .bold)
            if !isSelected { result[lower..<upper].foregroundColor = .accentColor }
            cursor = range.upperBound
        }
        return Text(result)
    }
}
