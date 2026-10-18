import HeftCore
import SwiftUI

/// The Mac's ⌘T bar on iOS: notes, commands, tags, folders and text in one
/// field, the same scopes behind the same prefixes (`@` notes, `>` commands,
/// `#` tags, `/` text), ranked against each other on the core's one scale,
/// and Pinned, Recent and Frequent before anything is typed. Ask stays on
/// the Mac, where its agent runs.
///
/// The pieces are the core's (`BarScope`, `CommandMatch`, `StartList`,
/// `ContentSearch`, `scoredSearch`); what is assembled here is the Mac's
/// `SearchBarModel` without the window around it.
enum SearchRow: Identifiable, Equatable {
    case note(NoteRef)
    case command(MobileCommand)
    case tag(String, count: Int)
    case folder(String, count: Int)
    case scope(BarScope)
    case hit(ContentMatch)
    /// Every text match, in the Text scope.
    case allText(count: Int)

    var id: String {
        switch self {
        case .note(let note): "note:" + note.relativePath
        case .command(let command): "command:" + command.id
        case .tag(let tag, _): "tag:" + tag
        case .folder(let path, _): "folder:" + path
        case .scope(let scope): "scope:" + scope.title
        case .hit(let hit): "hit:" + hit.id
        case .allText: "alltext"
        }
    }

    static func == (left: SearchRow, right: SearchRow) -> Bool { left.id == right.id }
}

struct SearchSection: Identifiable {
    var title: String?
    var rows: [SearchRow]
    var id: String { (title ?? "") + "#" + (rows.first?.id ?? "") }
}

/// A command the search lists, as the Mac's palette lists its own.
struct MobileCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var terms = ""
    let run: () -> Void

    /// What iOS can do from a search field, built over the window's actions.
    static func all(_ library: LibraryActions) -> [MobileCommand] {
        [
            MobileCommand(id: "newNote", title: "New Note", symbol: "square.and.pencil",
                          terms: "create add", run: library.newNote),
            MobileCommand(id: "newFolder", title: "New Folder", symbol: "folder.badge.plus",
                          terms: "create add directory", run: library.newFolder),
            MobileCommand(id: "openToday", title: "Today's Daily Note", symbol: "calendar",
                          terms: "daily journal date", run: library.today),
            MobileCommand(id: "capture", title: "Capture", symbol: "text.badge.plus",
                          terms: "inbox quick add", run: library.capture),
            MobileCommand(id: "showFiles", title: "Show Files", symbol: "folder",
                          terms: "tree browse sidebar", run: { library.show(.files) }),
            MobileCommand(id: "showRecent", title: "Show Recent", symbol: "clock",
                          terms: "history sidebar", run: { library.show(.recent) }),
            MobileCommand(id: "showTags", title: "Show Tags", symbol: "number",
                          terms: "sidebar", run: { library.show(.tags) }),
            MobileCommand(id: "settings", title: "Settings", symbol: "gearshape",
                          terms: "preferences appearance colours", run: library.settings),
            MobileCommand(id: "refresh", title: "Refresh Vault", symbol: "arrow.clockwise",
                          terms: "rescan reload sync", run: library.refresh),
        ]
    }
}

/// The search's state: the scope chosen, and the text matches, which are
/// read off the main thread and arrive after the names.
@MainActor @Observable
final class SearchModel {
    var scope: BarScope?
    private(set) var text: ContentSearchResult = .empty()
    private var textKey = ""

    /// Ask is the Mac's: its agent runs there.
    static let chips: [BarScope] = BarScope.chips.filter { $0 != .ask }

    static let commandUse = FrecencyStore(key: "dev.stenglein.Heft.iOS.commandUse")

    /// A prefix typed alone into an unscoped field enters its scope, as on
    /// the Mac, and is taken out of the field.
    func enterScope(byTyping query: String) -> Bool {
        guard scope == nil, let entered = BarScope.entered(byTyping: query), entered != .ask else { return false }
        scope = entered
        return true
    }

    /// Text matches for what is typed, within the scope's notes; waits for a
    /// pause and runs off the main thread, as the Mac's does.
    func searchText(_ query: String, vault: MobileVault) async {
        let term = query.trimmingCharacters(in: .whitespaces)
        let notes = scopedNotes(vault)
        let key = "\(term)#\(notes.count)#\(vault.generation)#\(scope?.title ?? "")"
        guard key != textKey else { return }
        guard term.count >= 2, wantsText(term, vault: vault) else {
            text = .empty()
            textKey = key
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) {
            ContentSearch.run(notes: notes, query: term, limit: 200)
        }.value
        guard !Task.isCancelled else { return }
        text = result
        textKey = key
    }

    private func wantsText(_ term: String, vault: MobileVault) -> Bool {
        switch scope {
        case nil, .contents, .tag, .folder: true
        default: false
        }
    }

    /// The notes a scope searches: one folder's, one tag's, or all.
    private func scopedNotes(_ vault: MobileVault) -> [NoteRef] {
        switch scope {
        case .folder(let path):
            return vault.index.notes.filter { $0.folder == path || $0.folder.hasPrefix(path + "/") }
        case .tag(let tag):
            let tagged = Set(vault.index.notes(taggedWith: tag).map(\.relativePath))
            return vault.index.notes.filter { tagged.contains($0.relativePath) }
        default:
            return vault.index.notes
        }
    }

    /// What choosing a row does: a note or a match opens, a command runs,
    /// a tag, folder or scope is entered, as Return does on the Mac.
    func act(on row: SearchRow, push: (MobileRoute) -> Void, setQuery: (String) -> Void) {
        switch row {
        case .note(let note): push(.note(note.relativePath))
        case .hit(let hit): push(.note(hit.note.relativePath))
        case .command(let command):
            Self.commandUse.record(command.id)
            RecentUses.record(RecentUses.commandKey(command.id))
            command.run()
        case .tag(let tag, _): scope = .tag(tag); setQuery("")
        case .folder(let path, _): scope = .folder(path); setQuery("")
        case .scope(let chosen): scope = chosen; setQuery("")
        case .allText: scope = .contents
        }
    }

    /// The row Return would choose: the first listed.
    func firstRow(for query: String, vault: MobileVault, commands: [MobileCommand]) -> SearchRow? {
        sections(for: query, vault: vault, commands: commands).first?.rows.first
    }

    // MARK: Rows

    func sections(for query: String, vault: MobileVault, commands: [MobileCommand]) -> [SearchSection] {
        let term = query.trimmingCharacters(in: .whitespaces)
        switch scope {
        case nil:
            return term.isEmpty ? startSections(vault: vault, commands: commands)
                : everything(term, vault: vault, commands: commands)
        case .notes:
            return [SearchSection(title: nil, rows: notes(term, in: vault.index.notes, vault: vault, limit: 100))]
        case .commands:
            let ranked = commands.compactMap { command -> (MobileCommand, Int)? in
                guard let score = CommandMatch.score(query: term, title: command.title, terms: command.terms)
                else { return nil }
                return (command, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.commandUse.score($0.0.id) > Self.commandUse.score($1.0.id) }
            return [SearchSection(title: nil, rows: ranked.map { .command($0.0) })]
        case .tags:
            let tags = term.isEmpty ? vault.index.allTags : vault.index.tags(matching: term)
            return [SearchSection(title: nil, rows: tags.map { .tag($0, count: vault.index.noteCount(forTag: $0)) })]
        case .folders:
            let folders = vault.folderPaths.filter { !$0.isEmpty }
                .compactMap { path -> (String, Int)? in
                    let name = (path as NSString).lastPathComponent
                    guard let score = CommandMatch.score(query: term, title: name, terms: path) else { return nil }
                    return (path, score)
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            return [SearchSection(title: nil, rows: folders.map { .folder($0.0, count: folderCount($0.0, vault: vault)) })]
        case .tag, .folder:
            let names = notes(term, in: scopedNotes(vault), vault: vault, limit: 100)
            return [SearchSection(title: names.isEmpty ? nil : "Notes", rows: names)] + textSections(limit: nil)
        case .contents:
            return textSections(limit: nil, heading: false)
        case .recent:
            let opened = vault.openedAt
            let rows = vault.index.notes.filter { opened[$0.relativePath] != nil }
                .sorted { opened[$0.relativePath]! > opened[$1.relativePath]! }
                .filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }
            return [SearchSection(title: nil, rows: rows.map(SearchRow.note))]
        case .frequent:
            let rows = byUse(vault.index.notes, vault: vault)
                .filter { vault.familiarity($0) > 0 && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)) }
            return [SearchSection(title: nil, rows: rows.map(SearchRow.note))]
        case .ask:
            return []
        }
    }

    /// Before anything is typed: what was pinned, the notes opened last,
    /// then what is used most of anything, then the rest of the notes by
    /// use: the Mac's standard start list.
    private func startSections(vault: MobileVault, commands: [MobileCommand]) -> [SearchSection] {
        var shown = Set<String>()
        func fresh(_ rows: [SearchRow], _ limit: Int) -> [SearchRow] {
            var kept: [SearchRow] = []
            for row in rows where !shown.contains(row.id) {
                shown.insert(row.id)
                kept.append(row)
                if kept.count == limit { break }
            }
            return kept
        }
        let pinned = fresh(vault.pins.values(of: .note).compactMap { vault.note(at: $0) }.map(SearchRow.note)
            + vault.pins.values(of: .folder).map { .folder($0, count: folderCount($0, vault: vault)) }, 10)
        let opened = vault.openedAt
        let recent = fresh(vault.index.notes.filter { opened[$0.relativePath] != nil }
            .sorted { opened[$0.relativePath]! > opened[$1.relativePath]! }.map(SearchRow.note), 5)
        // Notes and commands on one scale: each store's own score.
        let usedNotes = vault.index.notes.map { (SearchRow.note($0), vault.familiarity($0)) }
        let usedCommands = commands.map { (SearchRow.command($0), Self.commandUse.score($0.id)) }
        let frequent = fresh((usedNotes + usedCommands).filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.map(\.0), 12)
        let rest = fresh(byUse(vault.index.notes, vault: vault).map(SearchRow.note), 60)
        return [
            SearchSection(title: "Pinned", rows: pinned),
            SearchSection(title: "Recent", rows: recent),
            SearchSection(title: "Frequent", rows: frequent),
            SearchSection(title: "Notes", rows: rest),
        ].filter { !$0.rows.isEmpty }
    }

    /// Typed, with no scope: scopes, commands, tags, folders and notes in
    /// one list by how well each answers, then text when names found few.
    private func everything(_ term: String, vault: MobileVault, commands: [MobileCommand]) -> [SearchSection] {
        var scored: [(SearchRow, Int)] = []
        for scope in Self.chips where scope.isNamed(byPrefix: term) {
            scored.append((.scope(scope), 260))
        }
        for command in commands {
            if let score = CommandMatch.score(query: term, title: command.title, terms: command.terms) {
                scored.append((.command(command), score))
            }
        }
        let tagTerm = term.hasPrefix("#") ? String(term.dropFirst()) : term
        for tag in vault.index.tags(matching: tagTerm).prefix(8) {
            if let score = CommandMatch.score(query: tagTerm, title: tag, terms: "") {
                scored.append((.tag(tag, count: vault.index.noteCount(forTag: tag)), score))
            }
        }
        for path in vault.folderPaths where !path.isEmpty {
            if let score = CommandMatch.score(query: term, title: (path as NSString).lastPathComponent, terms: path) {
                scored.append((.folder(path, count: folderCount(path, vault: vault)), score))
            }
        }
        for found in vault.index.scoredSearch(
            term, limit: 40, familiarity: { vault.familiarity($0) }, pinned: { vault.isPinned($0.relativePath) }
        ) {
            scored.append((.note(found.note), found.score))
        }
        // Stable on ties, so the gathering order above breaks them.
        let ranked = scored.enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
        var sections = [SearchSection(title: nil, rows: Array(ranked.prefix(50)))]
        // As the Mac: text only once names have found fewer than ten.
        if ranked.count < 10 { sections += textSections(limit: 8) }
        return sections.filter { !$0.rows.isEmpty }
    }

    private func textSections(limit: Int?, heading: Bool = true) -> [SearchSection] {
        guard !text.matches.isEmpty else { return [] }
        let hits = limit.map { Array(text.matches.prefix($0)) } ?? text.matches
        var rows = hits.map(SearchRow.hit)
        if let limit, text.matches.count > limit { rows.append(.allText(count: text.totalOccurrences)) }
        let notes = text.matchedNotes
        return [SearchSection(title: heading ? "Text: \(notes) \(notes == 1 ? "note" : "notes")" : nil, rows: rows)]
    }

    private func notes(_ term: String, in pool: [NoteRef], vault: MobileVault, limit: Int) -> [SearchRow] {
        guard !term.isEmpty else { return byUse(pool, vault: vault).prefix(limit).map(SearchRow.note) }
        let allowed = Set(pool.map(\.relativePath))
        return vault.index.scoredSearch(
            term, limit: limit, familiarity: { vault.familiarity($0) },
            pinned: { vault.isPinned($0.relativePath) }, including: { allowed.contains($0.relativePath) }
        ).map { .note($0.note) }
    }

    /// Most used first, then by name.
    private func byUse(_ notes: [NoteRef], vault: MobileVault) -> [NoteRef] {
        notes.sorted {
            let left = vault.familiarity($0), right = vault.familiarity($1)
            return left != right ? left > right : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func folderCount(_ path: String, vault: MobileVault) -> Int {
        vault.folder(at: path)?.children.count ?? 0
    }
}

/// The search's list: the scope chips, then the sections. Notes are links,
/// so a phone pushes them and the iPad's sidebar selects them; everything
/// else acts here.
struct UniversalSearchList: View {
    let query: String
    let model: SearchModel
    /// Puts text in the field, as "All matches" carries the query on.
    var setQuery: (String) -> Void = { _ in }
    /// Notes as buttons rather than links, for a panel with no navigation
    /// stack to push onto.
    var asButtons = false
    /// The row the keyboard has chosen, lit.
    var highlighted: String?
    /// The scope chips at the head of the list; the phone has them above
    /// its keyboard instead.
    var showsChips = true
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library
    @Environment(\.mobilePush) private var push

    var body: some View {
        let commands = library.map(MobileCommand.all) ?? []
        if showsChips {
            Section {
                ScopeChips(model: model)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
        ForEach(model.sections(for: query, vault: vault, commands: commands)) { section in
            Section {
                ForEach(section.rows) { row in
                    rowView(row)
                        .listRowBackground(highlighted == row.id ? Rectangle().fill(.tint.opacity(0.22)) : nil)
                }
            } header: {
                if let title = section.title { Text(title) }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SearchRow) -> some View {
        switch row {
        case .note(let note) where asButtons:
            Button { act(row) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name)
                    if !note.folder.isEmpty {
                        Text(note.folder).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .tint(.primary)
        case .note(let note):
            NoteRow(note: note)
        case .hit(let hit) where asButtons:
            Button { act(row) } label: { hitLabel(hit) }
                .tint(.primary)
        case .hit(let hit):
            NavigationLink(value: MobileRoute.note(hit.note.relativePath)) { hitLabel(hit) }
        case .command(let command):
            Button { act(row) } label: { Label(command.title, systemImage: command.symbol) }
                .tint(.primary)
        case .tag(let tag, let count):
            Button { act(row) } label: { counted("#\(tag)", "number", count) }
                .tint(.primary)
        case .folder(let path, let count):
            Button { act(row) } label: { counted(path, "folder", count) }
                .tint(.primary)
        case .scope(let scope):
            Button { act(row) } label: { Label(scope.title, systemImage: scope.symbol) }
                .tint(.primary)
        case .allText(let count):
            Button { act(row) } label: { Label("All \(count) matches in text", systemImage: "text.magnifyingglass") }
                .tint(.primary)
        }
    }

    private func act(_ row: SearchRow) {
        model.act(on: row, push: { push($0) }, setQuery: setQuery)
    }

    private func hitLabel(_ hit: ContentMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.note.name).font(.subheadline.weight(.semibold))
            Text(hit.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func counted(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

}

extension View {
    /// Text matches for the search, read in the background; on the list's
    /// host, which is always there, where a section of results is not.
    func searchingText(_ query: String, model: SearchModel) -> some View {
        modifier(SearchTextTask(query: query, model: model))
    }
}

private struct SearchTextTask: ViewModifier {
    let query: String
    let model: SearchModel
    @Environment(MobileVault.self) private var vault

    func body(content: Content) -> some View {
        content.task(id: "\(query)#\(model.scope?.title ?? "")#\(vault.generation)") {
            await model.searchText(query, vault: vault)
        }
    }
}

/// The scopes as chips; the chosen one carries an ✕ to leave it, as
/// Backspace in an empty field does on the Mac.
struct ScopeChips: View {
    let model: SearchModel
    /// Full size above the phone's keyboard, smaller under a panel's field.
    var large = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let scope = model.scope, !SearchModel.chips.contains(scope) {
                    chip(scope, chosen: true)
                }
                ForEach(SearchModel.chips, id: \.self) { scope in
                    chip(scope, chosen: model.scope == scope)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ scope: BarScope, chosen: Bool) -> some View {
        Button {
            model.scope = chosen ? nil : scope
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scope.symbol)
                Text(scope.title)
                if chosen { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
            }
            .font(large ? .body : .subheadline)
            .padding(.horizontal, large ? 14 : 12)
            .padding(.vertical, large ? 9 : 6)
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The iPad's ⌘T: the Mac's search bar as a panel over the window, not a
/// list in the sidebar, where it read as part of Files, Recent and Tags.
/// Choosing a row opens it beside the sidebar and closes the panel, as do
/// Esc and a tap outside it. ↑↓ and Return choose with a keyboard.
struct SearchPanel: View {
    @Binding var isPresented: Bool
    /// Where a chosen note goes: the iPad's note pane.
    let open: (MobileRoute) -> Void
    @State private var query = ""
    @State private var model = SearchModel()
    @State private var selected = 0
    @FocusState private var focused: Bool
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library

    var body: some View {
        let rows = flatRows
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: model.scope?.symbol ?? "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(model.scope?.placeholder ?? BarScope.unscopedPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { choose(rows) }
                        .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                        .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    if !query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                Divider()
                List {
                    UniversalSearchList(
                        query: query, model: model, setQuery: { query = $0 },
                        asButtons: true, highlighted: rows.indices.contains(selected) ? rows[selected].id : nil
                    )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchingText(query, model: model)
                .environment(\.mobilePush) { route in
                    open(route)
                    close()
                }
            }
            .frame(width: 620)
            .frame(maxHeight: 560)
            .glassEffect(in: .rect(cornerRadius: 26))
            .padding(.top, 60)
        }
        .onAppear {
            focused = true
            #if DEBUG
            if let preset = ProcessInfo.processInfo.environment["HEFT_IOS_QUERY"] { query = preset }
            #endif
        }
        .onChange(of: query) { _, typed in
            selected = 0
            if model.enterScope(byTyping: typed) { query = "" }
        }
        .onChange(of: model.scope) { selected = 0 }
    }

    /// Every row in order, as the keyboard steps through them.
    private var flatRows: [SearchRow] {
        let commands = library.map(MobileCommand.all) ?? []
        return model.sections(for: query, vault: vault, commands: commands).flatMap(\.rows)
    }

    private func move(_ step: Int, in rows: [SearchRow]) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    private func choose(_ rows: [SearchRow]) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        model.act(on: row, push: { route in
            open(route)
            close()
        }, setQuery: { query = $0 })
        // A command closes the panel too; entering a scope keeps it open.
        if case .command = row { close() }
    }

    private func close() {
        isPresented = false
    }
}
