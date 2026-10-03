import Foundation
import HeftCore

/// The search bar's presentation: open, and narrowed to `scope`.
///
/// `generation` moves when a shortcut asks an already open bar for another
/// scope, so the bar can follow without the sheet closing and reopening.
struct BarRequest: Identifiable, Equatable {
    let id = UUID()
    var scope: BarScope?
    var generation = 0
}

/// One row of the search bar.
enum BarRow: Identifiable {
    /// A section title. With a target it is a row the arrows reach, and
    /// choosing it enters that scope; without one it only labels.
    case heading(String, target: BarScope?)
    case note(NoteRef)
    case command(AppCommand)
    case tag(String, count: Int)
    /// A folder, vault-relative, with how many notes are under it.
    case folder(String, count: Int)
    /// A scope offered by name, for a reader who has not learnt its key.
    case scope(BarScope)
    case hit(ContentMatch)
    /// The way from a name search to the same words in note text, with how
    /// many lines matched once that is known.
    case searchText(String, matches: Int? = nil)
    /// Matches outside the focused folder, offered when none are inside it.
    case elsewhere(Int)

    var id: String {
        switch self {
        case .heading(let title, _): "heading:\(title)"
        case .note(let note): "note:\(note.relativePath)"
        case .command(let command): "command:\(command.id)"
        case .tag(let name, _): "tag:\(name)"
        case .folder(let path, _): "folder:\(path)"
        case .scope(let scope): "scope:\(scope.title)"
        case .hit(let hit): "hit:\(hit.id)"
        case .searchText: "searchText"
        case .elsewhere: "elsewhere"
        }
    }

    var isSelectable: Bool {
        if case .heading(_, nil) = self { return false }
        return true
    }

    /// The scope choosing this row goes into, if it goes into one rather
    /// than opening or running something. Tab goes into it as well.
    var scope: BarScope? {
        switch self {
        case .heading(_, let target): target
        case .tag(let name, _): .tag(name)
        case .folder(let path, _): .folder(path)
        case .scope(let scope): scope
        case .searchText: .contents
        case .command(let command): AppCommand.scopes[command.id]
        default: nil
        }
    }
}

extension AppCommand {
    /// Commands that used to open a picker of their own and now narrow the
    /// bar they are chosen in, rather than closing it to open another.
    static let scopes: [String: BarScope] = [
        "quickOpen": .notes,
        "searchVault": .contents,
    ]
}

extension QuickOpenOrder.Lead {
    var barScope: BarScope { self == .recent ? .recent : .frequent }
}

@MainActor
extension AppModel {

    // MARK: Presenting

    /// Opens the bar narrowed to `scope`, or narrows the one already open.
    func openBar(_ scope: BarScope?) {
        if var open = bar {
            open.scope = scope
            open.generation += 1
            bar = open
        } else {
            bar = BarRequest(scope: scope)
        }
    }

    /// The three pickers this replaced, kept as names for the bar in one
    /// scope: menus, commands and tests ask for them by these names.
    var isQuickOpenPresented: Bool {
        get { bar?.scope == .notes }
        set { setBar(.notes, presented: newValue) }
    }

    var isCommandPalettePresented: Bool {
        get { bar?.scope == .commands }
        set { setBar(.commands, presented: newValue) }
    }

    var isVaultSearchPresented: Bool {
        get { bar?.scope == .contents }
        set { setBar(.contents, presented: newValue) }
    }

    private func setBar(_ scope: BarScope, presented: Bool) {
        if presented {
            openBar(scope)
        } else if bar?.scope == scope {
            bar = nil
        }
    }

    // MARK: Rows

    /// How many used notes and commands the bar with no scope lists before
    /// anything is typed, below the recent block: enough to be worth a
    /// heading, few enough that "Search in" is still reachable.
    static let barFrequentLimit = 12

    /// Fewer name matches than this and the text inside notes is searched
    /// too, with no scope and in a tag or a folder alike: about as many rows
    /// as the list shows, so text fills the room names leave and never
    /// pushes a name out of sight.
    static let barTextThreshold = 10
    /// The most text matches drawn at once. The rows are laid out eagerly,
    /// and five hundred of them made every keystroke wait; the count in the
    /// field still says how many there are.
    static let barTextRowLimit = 150
    /// How many matching lines the bar with no scope shows under the names;
    /// the rest are one row away, in the text scope.
    static let barTextPreview = 8

    /// Whether typing `query` should also search note text: always in the
    /// text scope, and with no scope or in a tag or a folder when names
    /// found fewer than `barTextThreshold` things, so a list names already
    /// fill is left as it was.
    func barWantsText(scope: BarScope?, query: String, entireVault: Bool) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if scope == .contents { return true }
        guard scope == nil || scope?.searchesTextToo == true else { return false }
        let found = nameRows(scope: scope, query: query, entireVault: entireVault, order: .current)
            .filter { if case .searchText = $0 { false } else { true } }
        return found.count < Self.barTextThreshold
    }

    /// What the bar lists for `scope` and `query`.
    ///
    /// - Parameter text: the text search for this query, which runs off the
    ///   main thread and arrives later. It is the whole list in the text
    ///   scope, and follows the name matches in a tag or a folder.
    func barRows(
        scope: BarScope?, query: String, entireVault: Bool,
        order: QuickOpenOrder = .current, text: ContentSearchResult? = nil
    ) -> [BarRow] {
        let rows = nameRows(scope: scope, query: query, entireVault: entireVault, order: order)
        let hits = (text?.matches ?? []).prefix(Self.barTextRowLimit).map(BarRow.hit)
        if scope == .contents { return hits }
        if scope == nil, let text, !hits.isEmpty {
            // The first few lines under the names, and the row into the
            // text scope saying how many more there are.
            let names = rows.filter { if case .searchText = $0 { false } else { true } }
            // The heading is a way in, as Quick Open's are: the text scope,
            // carrying the query.
            return names + [.heading("Text", target: .contents)]
                + hits.prefix(Self.barTextPreview)
                + [.searchText(query, matches: text.totalMatches)]
        }
        guard scope?.searchesTextToo == true, !hits.isEmpty else { return rows }
        // The names stay first and unlabelled, so a note found by name is
        // still one Return away and nothing above it moves when the text
        // arrives; a "Names" heading appearing over them pushed the list down.
        return rows + [.heading("Text", target: nil)] + hits
    }

    private func nameRows(
        scope: BarScope?, query: String, entireVault: Bool, order: QuickOpenOrder
    ) -> [BarRow] {
        let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
        switch scope {
        case nil:
            return typed
                ? everythingRows(query, entireVault: entireVault)
                : startRows(entireVault: entireVault, order: order)
        case .notes:
            var rows = quickOpenList(query, entireVault: entireVault, order: order).rows.map {
                switch $0 {
                case .heading(let kind): BarRow.heading(kind.title, target: kind.barScope)
                case .note(let note): BarRow.note(note)
                }
            }
            if typed {
                let elsewhere = notesElsewhere(query, entireVault: entireVault, nothingFound: rows.isEmpty)
                if elsewhere > 0 { rows.append(.elsewhere(elsewhere)) }
                rows.append(.searchText(query))
            }
            return rows
        case .recent, .frequent:
            let kind: QuickOpenOrder.Lead = scope == .recent ? .recent : .frequent
            let section = quickOpenList("", entireVault: entireVault, only: kind).all
            return named(query, among: section, entireVault: entireVault).map(BarRow.note)
        case .tag(let name):
            return named(query, among: index.notes(taggedWith: name), entireVault: entireVault)
                .map(BarRow.note)
        case .tags:
            return tagRows(query, limit: 200)
        case .folder(let path):
            return named(query, among: notes(under: path), entireVault: true).map(BarRow.note)
        case .folders:
            return folderRows(query, limit: 300)
        case .commands:
            return commandRows(query)
        case .contents:
            return []
        }
    }

    /// The notes a text search in `scope` reads: one tag's or one folder's,
    /// otherwise the focused folder unless asked for the whole vault.
    func barSearchableNotes(scope: BarScope?, entireVault: Bool) -> [NoteRef] {
        switch scope {
        case .tag(let name):
            let inScope = folderFilter(entireVault, .notes)
            return index.notes(taggedWith: name).filter { inScope?($0) ?? true }
        case .folder(let path): return notes(under: path)
        default: return entireVault ? index.notes : scopedNotes
        }
    }

    // MARK: Folders

    /// Every folder that holds a note, at any depth, with how many notes are
    /// under it. Read from the index's notes rather than the tree, so a
    /// folder of only attachments is not offered as a place to search.
    var noteFolders: [(path: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in index.notes {
            var parts = note.relativePath.split(separator: "/").dropLast()
            while !parts.isEmpty {
                counts[parts.joined(separator: "/"), default: 0] += 1
                parts = parts.dropLast()
            }
        }
        return counts.map { (path: $0.key, count: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func notes(under folder: String) -> [NoteRef] {
        index.notes.filter { $0.relativePath.hasPrefix(folder + "/") }
    }

    /// Folders by name: a folder's own name ranks, its path counts as its
    /// search terms. With nothing typed, the ones used most first.
    private func folderRows(_ query: String, limit: Int) -> [BarRow] {
        let folders = noteFolders
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return folders.enumerated()
                .sorted { left, right in
                    let l = FrecencyStore.commands.score(BarScope.folder(left.element.path).useKey)
                    let r = FrecencyStore.commands.score(BarScope.folder(right.element.path).useKey)
                    return l == r ? left.offset < right.offset : l > r
                }
                .prefix(limit)
                .map { BarRow.folder($0.element.path, count: $0.element.count) }
        }
        return folders.compactMap { folder -> (row: BarRow, score: Int)? in
            guard let tier = CommandMatch.score(
                query: query, title: BarScope.folder(folder.path).title, terms: folder.path
            ) else { return nil }
            return (.folder(folder.path, count: folder.count),
                    tier + Self.useBoost(BarScope.folder(folder.path).useKey))
        }
        .enumerated()
        .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
        .prefix(limit)
        .map(\.element.row)
    }

    /// Nothing typed and no scope: what you opened last, then what you use
    /// most: notes, commands, scopes and tags together. The scopes themselves
    /// are a row of chips above the list, so they cost it no rows.
    private func startRows(entireVault: Bool, order: QuickOpenOrder) -> [BarRow] {
        var rows: [BarRow] = []
        var listed = Set<String>()
        let recent = quickOpenList("", entireVault: entireVault, only: .recent).all
        let frequent = frequentRows(entireVault: entireVault)

        let blocks: [(QuickOpenOrder.Lead, [BarRow])] = order.lead == .recent
            ? [(.recent, recent.map(BarRow.note)), (.frequent, frequent)]
            : [(.frequent, frequent), (.recent, recent.map(BarRow.note))]
        // The setting sizes the first block, as in Quick Open; the second is
        // capped so that "Search in" stays within reach.
        let sizes = [order.count, Self.barFrequentLimit]
        for ((kind, candidates), size) in zip(blocks, sizes) {
            let fresh = candidates.filter { !listed.contains($0.id) }.prefix(size)
            guard !fresh.isEmpty else { continue }
            rows.append(.heading(kind.title, target: kind.barScope))
            rows += fresh
            listed.formUnion(fresh.map(\.id))
        }
        // A vault with no notes opened yet would show no notes at all, or an
        // empty sheet; it lists them after whatever else is used, as Quick
        // Open always did.
        if !rows.contains(where: { if case .note = $0 { true } else { false } }) {
            let notes = quickOpenList("", entireVault: entireVault, order: .init(lead: .recent, count: 0)).all
            if !notes.isEmpty {
                rows += [.heading(BarScope.notes.title, target: .notes)] + notes.map(BarRow.note)
            }
        }
        return rows
    }

    /// Used notes, commands, scopes and tags on one scale: every store adds
    /// one per use and halves every three days, so the scores compare
    /// directly.
    private func frequentRows(entireVault: Bool) -> [BarRow] {
        let familiarity: (NoteRef) -> Double = { [noteFrecency] in
            noteFrecency?.score($0.relativePath) ?? 0
        }
        let notes = quickOpenList("", entireVault: entireVault, only: .frequent).all
            .map { (row: BarRow.note($0), score: familiarity($0)) }
        let commands = AppCommand.registry
            .filter { $0.isEnabled(on: self) && AppCommand.scopes[$0.id] == nil }
            .map { (row: BarRow.command($0), score: FrecencyStore.commands.score($0.id)) }
            .filter { $0.score > 0 }
        let scopes = BarScope.searchable
            .map { (row: BarRow.scope($0), score: FrecencyStore.commands.score($0.useKey)) }
            .filter { $0.score > 0 }
        let tags = index.allTags
            .map { (row: BarRow.tag($0, count: index.noteCount(forTag: $0)),
                    score: FrecencyStore.commands.score(BarScope.tag($0).useKey)) }
            .filter { $0.score > 0 }
        let folders = noteFolders
            .map { (row: BarRow.folder($0.path, count: $0.count),
                    score: FrecencyStore.commands.score(BarScope.folder($0.path).useKey)) }
            .filter { $0.score > 0 }
        return (notes + commands + scopes + tags + folders)
            .enumerated()
            .sorted { left, right in
                left.element.score == right.element.score
                    ? left.offset < right.offset : left.element.score > right.element.score
            }
            .map(\.element.row)
    }

    /// Something typed and no scope: notes and commands ranked together by
    /// how well they match, familiarity breaking ties within a tier, then the
    /// same words in note text offered as the last row.
    private func everythingRows(_ query: String, entireVault: Bool) -> [BarRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var rows: [BarRow] = []
        // A tag typed with its hash, which can only arrive pasted: typing the
        // hash alone has already turned into the Tags chip.
        if trimmed.hasPrefix("#"), trimmed.count > 1 {
            rows += tagRows(String(trimmed.dropFirst()), limit: 8)
        }
        if let atPath = noteAtPath(query) { rows.append(.note(atPath)) }

        let familiarity: (NoteRef) -> Double = { [noteFrecency] in
            noteFrecency?.score($0.relativePath) ?? 0
        }
        let notes = index.scoredSearch(
            query, limit: 60, familiarity: familiarity, including: folderFilter(entireVault, .notes)
        ).map { (row: BarRow.note($0.note), score: $0.score, enabled: true) }
        // The commands that only open a scope are left out: the scope's own
        // row is the same choice, listed once.
        let commands = AppCommand.registry.compactMap { command -> (row: BarRow, score: Int, enabled: Bool)? in
            guard AppCommand.scopes[command.id] == nil,
                  let tier = CommandMatch.score(
                query: query, title: command.title(on: self), terms: command.searchTerms
            ) else { return nil }
            return (.command(command), tier + Self.useBoost(command.id), command.isEnabled(on: self))
        }
        // The scopes by name or synonym, so "rec" offers Recent, and tags by
        // name without their hash. Both learn from use as commands do.
        let scopes = BarScope.searchable.compactMap { scope -> (row: BarRow, score: Int, enabled: Bool)? in
            guard let tier = CommandMatch.score(query: query, title: scope.title, terms: scope.aliases)
            else { return nil }
            return (.scope(scope), tier + Self.useBoost(scope.useKey), true)
        }
        let tags = trimmed.hasPrefix("#") ? [] : index.allTags.compactMap { tag -> (row: BarRow, score: Int, enabled: Bool)? in
            guard let tier = CommandMatch.score(query: query, title: tag, terms: "") else { return nil }
            return (
                .tag(tag, count: index.noteCount(forTag: tag)),
                tier + Self.useBoost(BarScope.tag(tag).useKey), true
            )
        }
        let folders = noteFolders.compactMap { folder -> (row: BarRow, score: Int, enabled: Bool)? in
            let scope = BarScope.folder(folder.path)
            guard let tier = CommandMatch.score(query: query, title: scope.title, terms: folder.path)
            else { return nil }
            return (.folder(folder.path, count: folder.count), tier + Self.useBoost(scope.useKey), true)
        }
        // Scopes, then commands, tags and folders, then notes on a tie: the
        // fewer there are of a kind, the likelier a tie lost is a row never
        // seen.
        let ranked = (scopes + commands + tags + folders + notes).enumerated().sorted { left, right in
            if left.element.score != right.element.score {
                return left.element.score > right.element.score
            }
            return left.offset < right.offset
        }.map(\.element)
        let listed = Set(rows.map(\.id))
        let mixed = ranked.filter { !listed.contains($0.row.id) }
        // A command that cannot run sinks, as in the palette, so the first
        // row is one Return can act on.
        rows += mixed.filter(\.enabled).prefix(60).map(\.row)
        rows += mixed.filter { !$0.enabled }.map(\.row)
        rows.append(.searchText(query))
        return rows
    }

    /// The familiarity nudge typed queries give a note, for anything else
    /// whose use is kept in the commands' store.
    private static func useBoost(_ key: String) -> Int {
        let use = FrecencyStore.commands.score(key)
        return Int(min(use / VaultIndex.wellUsed, 1) * Double(VaultIndex.boostWeight))
    }

    /// Records that the reader went into `scope`, so it ranks by use.
    func recordScopeUse(_ scope: BarScope) {
        FrecencyStore.commands.record(scope.useKey)
    }

    /// The palette's own order: what matches, by use, disabled last.
    private func commandRows(_ query: String) -> [BarRow] {
        let matching = AppCommand.registry.filter { $0.matches(query) }
        let ranked = FrecencyStore.commands.ranked(matching, by: \.id) { _, _ in false }
        return AppCommand.sinkingDisabled(ranked) { $0.isEnabled(on: self) }.map(BarRow.command)
    }

    /// Tags by how many notes carry them, as the tag list orders them.
    private func tagRows(_ query: String, limit: Int) -> [BarRow] {
        index.tags(matching: query).prefix(limit).map {
            BarRow.tag($0, count: index.noteCount(forTag: $0))
        }
    }

    /// `notes`, kept in their own order with nothing typed and ranked by
    /// name match when something is.
    private func named(_ query: String, among notes: [NoteRef], entireVault: Bool) -> [NoteRef] {
        let inScope = folderFilter(entireVault, .notes)
        let candidates = notes.filter { inScope?($0) ?? true }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return candidates }
        let allowed = Set(candidates.map(\.relativePath))
        let familiarity: (NoteRef) -> Double = { [noteFrecency] in
            noteFrecency?.score($0.relativePath) ?? 0
        }
        return index.search(
            query, limit: 200, familiarity: familiarity,
            including: { allowed.contains($0.relativePath) }
        )
    }

    private func notesElsewhere(_ query: String, entireVault: Bool, nothingFound: Bool) -> Int {
        guard scopePath != nil, !entireVault, nothingFound else { return 0 }
        return quickOpenResults(query, entireVault: true).count
    }

    private func folderFilter(_ entireVault: Bool, _ scope: BarScope) -> ((NoteRef) -> Bool)? {
        guard !entireVault, scopePath != nil, scope.followsFolderFocus else { return nil }
        return { self.isInScope($0) }
    }
}
