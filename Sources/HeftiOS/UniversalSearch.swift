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

    /// ⌘1…⌘5: the chip with that number, or no scope when it is the one
    /// already chosen.
    /// Out of the scope, to its parent where it has one.
    func leave() {
        scope = scope?.parent
    }

    func choose(chip number: Int) {
        guard let chip = BarScope.chip(number: number), chip != .ask else { return }
        // As on the Mac: from any scope, and its own number keeps it.
        scope = chip
    }

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
        case .tag(let tag, _): enter(.tag(tag), setQuery: setQuery)
        case .folder(let path, _): enter(.folder(path), setQuery: setQuery)
        case .scope(let chosen): enter(chosen, setQuery: setQuery)
        case .allText: scope = .contents
        }
    }

    /// Into a scope, counted as a use, so tags, folders and scopes rise in
    /// Recent and Frequent as they do on the Mac.
    private func enter(_ chosen: BarScope, setQuery: (String) -> Void) {
        Self.commandUse.record(chosen.useKey)
        RecentUses.record(chosen.useKey)
        scope = chosen
        setQuery("")
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
            guard !term.isEmpty else { return arranged(vault.index.notes, kind: .notes, vault: vault) }
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
            if term.isEmpty {
                return arranged(scopedNotes(vault), kind: isTag ? .tag : .folder, vault: vault)
            }
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

    /// Before anything is typed: the start list's rows from the top, each
    /// of its kinds, by its order, and nothing a row above already listed;
    /// the last fills the rest. The Mac's ⌘T list, set in Settings ▸ Search.
    private func startSections(vault: MobileVault, commands: [MobileCommand]) -> [SearchSection] {
        let list = StartList.current
        let uses = RecentUses.dates()
        var shown = Set<String>()
        var sections: [SearchSection] = []
        for (row, limit) in list.plan {
            var kept: [SearchRow] = []
            for candidate in candidates(row, vault: vault, commands: commands, uses: uses)
            where !shown.contains(candidate.id) {
                shown.insert(candidate.id)
                kept.append(candidate)
                if kept.count == limit { break }
            }
            if !kept.isEmpty { sections.append(SearchSection(title: row.title, rows: kept)) }
        }
        if sections.isEmpty {
            sections = [SearchSection(title: "Notes", rows: byUse(vault.index.notes, vault: vault).prefix(60).map(SearchRow.note))]
        }
        return sections
    }

    /// One start row's items, in its order.
    private func candidates(
        _ row: StartList.Row, vault: MobileVault, commands: [MobileCommand], uses: [String: Date]
    ) -> [SearchRow] {
        let kinds = row.kinds
        if row.order == .pinned {
            var rows: [SearchRow] = []
            if kinds.contains(.notes) {
                rows += vault.pins.values(of: .note).compactMap { vault.note(at: $0) }.map(SearchRow.note)
            }
            if kinds.contains(.folders) {
                rows += vault.pins.values(of: .folder).map { .folder($0, count: folderCount($0, vault: vault)) }
            }
            return rows
        }
        var scored: [(SearchRow, Double)] = []
        let recent = row.order == .recent
        func value(_ key: String) -> Double {
            recent ? uses[key]?.timeIntervalSince1970 ?? 0 : Self.commandUse.score(key)
        }
        if kinds.contains(.notes) {
            for note in vault.index.notes {
                let score = recent
                    ? vault.openedAt[note.relativePath]?.timeIntervalSince1970 ?? 0
                    : vault.familiarity(note)
                scored.append((.note(note), score))
            }
        }
        if kinds.contains(.commands) {
            for command in commands {
                let key = recent ? RecentUses.commandKey(command.id) : command.id
                scored.append((.command(command), value(key)))
            }
        }
        if kinds.contains(.tags) {
            for tag in vault.index.allTags {
                scored.append((.tag(tag, count: vault.index.noteCount(forTag: tag)), value(BarScope.tag(tag).useKey)))
            }
        }
        if kinds.contains(.folders) {
            for path in vault.folderPaths where !path.isEmpty {
                scored.append((.folder(path, count: folderCount(path, vault: vault)), value(BarScope.folder(path).useKey)))
            }
        }
        if kinds.contains(.scopes) {
            for scope in Self.chips { scored.append((.scope(scope), value(scope.useKey))) }
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
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

    private var isTag: Bool {
        if case .tag = scope { return true }
        return false
    }

    /// A scope's notes before anything is typed, in the order Settings ▸
    /// Search sets for it: recent or frequent first, one of them alone, by
    /// name, or by last edit.
    private func arranged(_ pool: [NoteRef], kind: ScopeOrders.Kind, vault: MobileVault) -> [SearchSection] {
        let order = ScopeOrders.current[kind]
        let opened = vault.openedAt
        let recent = opened.sorted { $0.value > $1.value }.map(\.key)
        let result = order.arrange(
            byUse(pool, vault: vault), recent: recent, limit: 200,
            isUsed: { vault.familiarity($0) > 0 || opened[$0.relativePath] != nil },
            edited: { vault.index.modificationDate(of: $0.relativePath) }
        )
        guard let heading = result.heading else {
            return [SearchSection(title: nil, rows: result.all.map(SearchRow.note))]
        }
        return [
            SearchSection(title: heading.title, rows: result.lead.map(SearchRow.note)),
            SearchSection(title: "Other", rows: result.rest.map(SearchRow.note)),
        ].filter { !$0.rows.isEmpty }
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
    /// The scope chips at the head of the list, while no scope is chosen;
    /// the phone has them under its field instead.
    var showsChips = true
    /// Rename, move, delete and the rest, from a row's long press or right
    /// click; the screen holding the list carries them out.
    var itemAction: ((ItemAction) -> Void)? = nil
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library
    @Environment(\.mobilePush) private var push

    var body: some View {
        let commands = library.map(MobileCommand.all) ?? []
        if showsChips, model.scope == nil {
            Section {
                ScopeChips(model: model, numbered: asButtons)
                    .listRowInsets(EdgeInsets(top: asButtons ? 10 : 4, leading: 0, bottom: asButtons ? 6 : 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        ForEach(model.sections(for: query, vault: vault, commands: commands)) { section in
            Section {
                ForEach(section.rows) { row in
                    withMenu(rowView(row), for: row)
                        .listRowInsets(asButtons ? Self.panelRowInsets : nil)
                        .listRowBackground(highlighted == row.id ? Rectangle().fill(.tint.opacity(0.22)) : nil)
                        // The panel has none, as the Mac's bar has none: a
                        // plain list drew them under some rows and not others.
                        .listRowSeparator(asButtons ? .hidden : .automatic)
                }
            } header: {
                if let title = section.title {
                    if asButtons {
                        // Small, as the Mac's bar labels its sections.
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 2, trailing: 18))
                    } else {
                        Text(title)
                    }
                }
            }
        }
    }

    /// The panel's rows, as close together as the Mac's bar sets them.
    private static let panelRowInsets = EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18)

    @ViewBuilder
    private func rowView(_ row: SearchRow) -> some View {
        switch row {
        case .note(let note) where asButtons:
            // One line, the folder trailing, as the Mac's bar lists a note.
            Button { act(row) } label: { panelLine(note.name, "doc.text", detail: note.folder) }
                .tint(.primary)
        case .note(let note):
            NoteRow(note: note)
        case .hit(let hit) where asButtons:
            Button { act(row) } label: { panelHit(hit) }
                .tint(.primary)
        case .hit(let hit):
            NavigationLink(value: MobileRoute.note(hit.note.relativePath)) { hitLabel(hit) }
        case .command(let command) where asButtons:
            Button { act(row) } label: { panelLine(command.title, command.symbol) }
                .tint(.primary)
        case .tag(let tag, let count) where asButtons:
            Button { act(row) } label: { panelLine("#\(tag)", "number", detail: "\(count)") }
                .tint(.primary)
        case .folder(let path, let count) where asButtons:
            Button { act(row) } label: { panelLine(path, "folder", detail: "\(count)") }
                .tint(.primary)
        case .scope(let scope) where asButtons:
            Button { act(row) } label: { panelLine(scope.title, scope.symbol) }
                .tint(.primary)
        case .allText(let count) where asButtons:
            Button { act(row) } label: { panelLine("All \(count) matches in text", "text.magnifyingglass") }
                .tint(.primary)
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

    /// The Files list's menu on a note, a text match's note or a folder, as
    /// the Mac's bar gives its rows the file tree's menus.
    @ViewBuilder
    private func withMenu(_ view: some View, for row: SearchRow) -> some View {
        if let itemAction, let item = Self.item(row) {
            view.contextMenu { ItemMenu(item: item, perform: itemAction) }
        } else {
            view
        }
    }

    private static func item(_ row: SearchRow) -> ItemRef? {
        switch row {
        case .note(let note): ItemRef(path: note.relativePath, isFolder: false)
        case .hit(let hit): ItemRef(path: hit.note.relativePath, isFolder: false)
        case .folder(let path, _): ItemRef(path: path, isFolder: true)
        default: nil
        }
    }

    private func act(_ row: SearchRow) {
        model.act(on: row, push: { push($0) }, setQuery: setQuery)
    }

    /// A row of the panel, as the Mac's bar sets one: a quiet icon in a
    /// column of its own, the name, and what qualifies it at the far end.
    private func panelLine(_ title: String, _ symbol: String, detail: String = "") -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .contentShape(.rect)
    }

    /// A text match in the panel: the note on the first line, as its row
    /// above would show it, and the matched line under it.
    private func panelHit(_ hit: ContentMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.note.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 8)
                    if hit.occurrences > 1 {
                        Text("\(hit.occurrences) matches").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                Text(hit.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contentShape(.rect)
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
/// The scopes to search in. In the iPad's panel they show only while none
/// is chosen, as on the Mac, where a chosen one moves into the field as a
/// `ScopeToken`. On the phone, whose keyboard cannot report Delete in an
/// empty field, they stay: the chosen one is coloured and a second tap
/// leaves it.
struct ScopeChips: View {
    let model: SearchModel
    /// Full size under the phone's field, with the chosen one kept and
    /// coloured; smaller under a panel's.
    var large = false
    /// ⌘1… beside each, where a hardware keyboard chooses them.
    var numbered = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // A tag or folder entered from its list leads, chosen.
                    if let scope = model.scope, !SearchModel.chips.contains(scope) {
                        chip(scope)
                    }
                    ForEach(SearchModel.chips, id: \.self) { chip($0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, large ? 4 : 0)
            }
        }
    }

    private func chip(_ scope: BarScope) -> some View {
        let chosen = model.scope == scope
        return Button {
            if chosen { model.leave() } else { model.scope = scope }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scope.symbol)
                Text(scope.title)
                if numbered, let number = scope.chipNumber {
                    Text("⌘\(number)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(large ? .body : .subheadline)
            .padding(.horizontal, large ? 14 : 12)
            .padding(.vertical, large ? 9 : 6)
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .modifier(ChipBackground(chosen: chosen, glass: large))
        }
        .buttonStyle(.plain)
    }
}

/// Glass under the phone's field, where the chips float over the list; a
/// plain fill inside the iPad's panel, which is glass already.
private struct ChipBackground: ViewModifier {
    let chosen: Bool
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(chosen ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                in: .capsule)
        } else {
            content.background(.fill.tertiary, in: .capsule)
        }
    }
}

/// The chosen scope in the field, where the magnifier was, as the Mac's bar
/// shows it. Tapping it leaves the scope: a tag for the list of tags,
/// anything else for no scope.
struct ScopeToken: View {
    let model: SearchModel
    let scope: BarScope

    var body: some View {
        Button {
            model.leave()
        } label: {
            // The text keeps the text colour: a light accent is unreadable
            // as text on a tint of itself.
            HStack(spacing: 4) {
                Image(systemName: scope.symbol).foregroundStyle(.tint)
                Text(scope.title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.22), in: .capsule)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Searching \(scope.title)")
        .accessibilityHint("Leaves the scope")
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
    /// Held by the window, so the menu bar's ⌘1… can choose its scope.
    let model: SearchModel
    @State private var query = ""
    @State private var selected = 0
    @State private var action: ItemAction?
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
                    if let scope = model.scope {
                        ScopeToken(model: model, scope: scope)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    TextField(model.scope?.placeholder ?? BarScope.unscopedPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { choose(rows) }
                        .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                        .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        // ⌘. is iPadOS's Escape, for keyboards without the key.
                        .onKeyPress(keys: ["."]) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            close()
                            return .handled
                        }
                        // Delete in an empty field leaves the scope, as on the Mac.
                        .onKeyPress(.delete) {
                            guard query.isEmpty, model.scope != nil else { return .ignored }
                            model.leave()
                            return .handled
                        }
                        // ⌘1–⌘3 come through the menu bar; these two have no
                        // menu item of their own.
                        .onKeyPress(keys: ["4", "5"]) { press in
                            guard press.modifiers.contains(.command),
                                  let number = Int(String(press.key.character)) else { return .ignored }
                            model.choose(chip: number)
                            return .handled
                        }
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
                        asButtons: true, highlighted: rows.indices.contains(selected) ? rows[selected].id : nil,
                        itemAction: { action = $0 }
                    )
                }
                .itemActionHost($action)
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 34)
                .environment(\.defaultMinListHeaderHeight, 0)
                .listSectionSpacing(0)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .searchingText(query, model: model)
                .environment(\.mobilePush) { route in
                    open(route)
                    close()
                }
            }
            .frame(width: 620)
            .animation(.easeOut(duration: 0.22), value: model.scope)
            .frame(maxHeight: 560)
            .glassEffect(in: .rect(cornerRadius: 26))
            .padding(.top, 60)
        }
        .onAppear {
            // The scope is the opener's: none for ⌘T, notes for ⌘O.
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
