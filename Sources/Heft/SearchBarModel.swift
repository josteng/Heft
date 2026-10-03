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
    /// A section title, which only labels: the arrows pass over it. Some
    /// headings once led into a scope and others did not, so the arrows
    /// stopped on some and skipped others; every scope is a chip, ⌘1 to ⌘5
    /// and a name to type instead.
    case heading(String)
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
        case .heading(let title): "heading:\(title)"
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
        if case .heading = self { return false }
        return true
    }

    /// The scope choosing this row goes into, if it goes into one rather
    /// than opening or running something. Tab goes into it as well.
    var scope: BarScope? {
        switch self {
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

@MainActor
extension AppModel {

    // MARK: Presenting

    /// Opens the bar narrowed to `scope`, or narrows the one already open.
    func openBar(_ scope: BarScope?) {
        session?.reloadPins()
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
        let found = nameRows(scope: scope, query: query, entireVault: entireVault, order: nil)
            .filter { if case .searchText = $0 { false } else { true } }
        return found.count < Self.barTextThreshold
    }

    /// What the bar lists for `scope` and `query`.
    ///
    /// - Parameter text: the text search for this query, which runs off the
    ///   main thread and arrives later. It is the whole list in the text
    ///   scope, and follows the name matches in a tag or a folder.
    ///
    /// - Parameters:
    ///   - order: one order for every scope, overriding `orders`; for tests.
    ///   - orders: each scope's own recent-or-frequent order.
    ///   - start: what ⌘T lists before anything is typed.
    func barRows(
        scope: BarScope?, query: String, entireVault: Bool,
        order: QuickOpenOrder? = nil, orders: ScopeOrders = .current, start: StartList = .current,
        text: ContentSearchResult? = nil
    ) -> [BarRow] {
        let rows = nameRows(
            scope: scope, query: query, entireVault: entireVault, order: order, orders: orders,
            start: start
        )
        let hits = (text?.matches ?? []).prefix(Self.barTextRowLimit).map(BarRow.hit)
        if scope == .contents { return hits }
        if scope == nil, let text, !hits.isEmpty {
            // The first few lines under the names, and the row into the
            // text scope saying how many more there are.
            let names = rows.filter { if case .searchText = $0 { false } else { true } }
            // The heading is a way in, as Quick Open's are: the text scope,
            // carrying the query.
            return names + [.heading("Text")]
                + hits.prefix(Self.barTextPreview)
                + [.searchText(query, matches: text.totalMatches)]
        }
        guard scope?.searchesTextToo == true, !hits.isEmpty else { return rows }
        // The names stay first and unlabelled, so a note found by name is
        // still one Return away and nothing above it moves when the text
        // arrives; a "Names" heading appearing over them pushed the list down.
        return rows + [.heading("Text")] + hits
    }

    private func nameRows(
        scope: BarScope?, query: String, entireVault: Bool, order: QuickOpenOrder?,
        orders: ScopeOrders = .current,
        start: StartList = .current
    ) -> [BarRow] {
        let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
        switch scope {
        case nil:
            return typed
                ? everythingRows(query, entireVault: entireVault)
                : startRows(entireVault: entireVault, start: start)
        case .notes:
            var rows = Self.rows(quickOpenList(query, entireVault: entireVault, order: order ?? orders[.notes]))
            if typed {
                let elsewhere = notesElsewhere(query, entireVault: entireVault, nothingFound: rows.isEmpty)
                if elsewhere > 0 { rows.append(.elsewhere(elsewhere)) }
                rows.append(.searchText(query))
                return rows
            }
            return withPinned(.note, rows, order: order ?? orders[.notes], entireVault: entireVault)
        case .recent, .frequent:
            let kind: QuickOpenOrder.Lead = scope == .recent ? .recent : .frequent
            let section = quickOpenList("", entireVault: entireVault, only: kind).all
            return named(query, among: section, entireVault: entireVault).map(BarRow.note)
        case .tag(let name):
            guard typed else {
                let tagged = Set(index.notes(taggedWith: name).map(\.relativePath))
                return notesInScope(
                    order: order ?? orders[.tag], entireVault: entireVault,
                    among: { tagged.contains($0.relativePath) }
                )
            }
            return named(query, among: index.notes(taggedWith: name), entireVault: entireVault)
                .map(BarRow.note)
        case .tags:
            guard typed else {
                // By how many notes carry them when nothing else decides.
                let tags = index.allTags
                let rows = arrangedRows(
                    tags, kind: "tags", order: order ?? orders[.tags], name: { $0 },
                    key: { BarScope.tag($0).useKey }, scoreKey: { BarScope.tag($0).useKey },
                    row: { BarRow.tag($0, count: self.index.noteCount(forTag: $0)) }
                )
                return withPinned(.tag, rows, order: order ?? orders[.tags], entireVault: entireVault)
            }
            return tagRows(query, limit: 200)
        case .folder(let path):
            guard typed else {
                // A folder chosen is searched whole, whatever the window's focus.
                return notesInScope(
                    order: order ?? orders[.folder], entireVault: true,
                    among: { $0.relativePath.hasPrefix(path + "/") }
                )
            }
            return named(query, among: notes(under: path), entireVault: true).map(BarRow.note)
        case .folders:
            guard typed else {
                let rows = arrangedRows(
                    noteFolders, kind: "folders", order: order ?? orders[.folders],
                    name: { BarScope.folder($0.path).title },
                    key: { BarScope.folder($0.path).useKey }, scoreKey: { BarScope.folder($0.path).useKey },
                    row: { BarRow.folder($0.path, count: $0.count) }
                )
                return withPinned(.folder, rows, order: order ?? orders[.folders], entireVault: entireVault)
            }
            return folderRows(query, limit: 300)
        case .commands:
            guard typed else {
                // A command that cannot run sinks within its part, as it does
                // in the whole list once something is typed.
                let rows = arrangedRows(
                    AppCommand.registry, kind: "commands", order: order ?? orders[.commands],
                    name: { $0.title },
                    key: { RecentUses.commandKey($0.id) }, scoreKey: { $0.id },
                    row: { BarRow.command($0) }
                )
                return sinkingDisabledWithinParts(
                    withPinned(.command, rows, order: order ?? orders[.commands], entireVault: entireVault)
                )
            }
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

    /// A folder's or a tag's notes before anything is typed, in that scope's
    /// own order, with the pinned ones among them first.
    private func notesInScope(
        order: QuickOpenOrder, entireVault: Bool, among: @escaping (NoteRef) -> Bool
    ) -> [BarRow] {
        let arranged = quickOpenList(
            "", entireVault: entireVault, limit: .max, order: order, among: among
        )
        return withPinned(
            .note, Self.rows(arranged), order: order, entireVault: entireVault,
            among: { if case .note(let note) = $0 { among(note) } else { false } }
        )
    }

    private static func rows(_ arranged: QuickOpenOrder.Arranged) -> [BarRow] {
        arranged.rows.map {
            switch $0 {
            case .heading(let kind): BarRow.heading(kind.title)
            case .note(let note): BarRow.note(note)
            }
        }
    }

    func notes(under folder: String) -> [NoteRef] {
        index.notes.filter { $0.relativePath.hasPrefix(folder + "/") }
    }

    /// Folders by name: a folder's own name ranks, its path counts as its
    /// search terms.
    private func folderRows(_ query: String, limit: Int) -> [BarRow] {
        noteFolders.compactMap { folder -> (row: BarRow, score: Int)? in
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
    private func startRows(entireVault: Bool, start: StartList) -> [BarRow] {
        var rows: [BarRow] = []
        var listed = Set<String>()
        for (row, limit) in start.plan {
            let fresh = startCandidates(row, entireVault: entireVault, fillsRest: start.fillsRest(row))
                .filter { !listed.contains($0.id) }
                .prefix(limit)
            guard !fresh.isEmpty else { continue }
            rows.append(.heading(row.title))
            rows += fresh
            listed.formUnion(fresh.map(\.id))
        }
        // A list of rows that found nothing, or no rows at all, would open on
        // an empty sheet; it opens on the notes instead, as Quick Open did.
        if rows.isEmpty {
            let notes = allNotesByUse(entireVault: entireVault)
            if !notes.isEmpty {
                rows = [.heading(BarScope.notes.title)] + notes.map(BarRow.note)
            }
        }
        return rows
    }

    /// One start row's candidates: every kind it names, on one scale, most
    /// recent or most used first. Recent compares times, so a note opened an
    /// hour ago sits below a command run a minute ago; frequent compares use
    /// scores, which every store keeps the same way. Only what has been used
    /// is listed, except that a frequent row of notes filling the rest goes
    /// on to every other note, so the list still reaches the whole vault.
    private func startCandidates(
        _ row: StartList.Row, entireVault: Bool, fillsRest: Bool
    ) -> [BarRow] {
        if row.order == .pinned {
            // In the order pinned, across kinds, as they were pinned.
            let wanted: [Pins.Kind: StartList.Kind] = [
                .note: .notes, .command: .commands, .tag: .tags, .folder: .folders,
            ]
            var byPin: [Pins.Pin: BarRow] = [:]
            for kind in Pins.Kind.allCases where row.kinds.contains(wanted[kind]!) {
                for found in pinnedRows(kind, entireVault: entireVault) {
                    if let pin = pin(for: found) { byPin[pin] = found }
                }
            }
            return pins.items.compactMap { byPin[$0] }
        }
        let recent = row.order == .recent
        let lastUsed = RecentUses.dates()
        /// What a key ranks by: when it was last used, or how much.
        func value(_ key: String) -> Double? {
            if recent { return lastUsed[key]?.timeIntervalSince1970 }
            let score = FrecencyStore.commands.score(key)
            return score > 0 ? score : nil
        }

        var candidates: [(row: BarRow, value: Double)] = []
        if row.kinds.contains(.notes) {
            if recent {
                let notes = quickOpenList("", entireVault: entireVault, only: .recent).all
                for (offset, note) in notes.enumerated() {
                    // A history entry without a time keeps its place below
                    // the ones with one.
                    let date = session?.lastOpened(note.relativePath)?.timeIntervalSince1970
                    candidates.append((.note(note), date ?? -Double(offset)))
                }
            } else {
                for note in quickOpenList("", entireVault: entireVault, only: .frequent).all {
                    candidates.append((.note(note), noteFrecency?.score(note.relativePath) ?? 0))
                }
            }
        }
        if row.kinds.contains(.commands) {
            for command in AppCommand.registry
            where command.isEnabled(on: self) && AppCommand.scopes[command.id] == nil {
                let key = recent ? RecentUses.commandKey(command.id) : command.id
                let found = recent ? lastUsed[key]?.timeIntervalSince1970 : value(key)
                if let found { candidates.append((.command(command), found)) }
            }
        }
        if row.kinds.contains(.tags) {
            for tag in index.allTags {
                if let found = value(BarScope.tag(tag).useKey) {
                    candidates.append((.tag(tag, count: index.noteCount(forTag: tag)), found))
                }
            }
        }
        if row.kinds.contains(.folders) {
            for folder in noteFolders {
                if let found = value(BarScope.folder(folder.path).useKey) {
                    candidates.append((.folder(folder.path, count: folder.count), found))
                }
            }
        }
        if row.kinds.contains(.scopes) {
            for scope in BarScope.searchable {
                if let found = value(scope.useKey) { candidates.append((.scope(scope), found)) }
            }
        }

        // Swift's sort is not stable, so the order gathered breaks ties.
        var ordered = candidates.enumerated()
            .sorted { left, right in
                left.element.value == right.element.value
                    ? left.offset < right.offset : left.element.value > right.element.value
            }
            .map(\.element.row)
        if !recent, fillsRest, row.kinds.contains(.notes) {
            let shown = Set(ordered.map(\.id))
            ordered += allNotesByUse(entireVault: entireVault)
                .map(BarRow.note)
                .filter { !shown.contains($0.id) }
        }
        return ordered
    }

    /// Every note, most used first and then by name: what Quick Open lists.
    private func allNotesByUse(entireVault: Bool) -> [NoteRef] {
        quickOpenList(
            "", entireVault: entireVault, limit: StartList.restLimit,
            order: .init(lead: .recent, count: 0)
        ).all
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
            query, limit: 60, familiarity: familiarity, pinned: isNotePinned,
            including: folderFilter(entireVault, .notes)
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

    // MARK: Pins

    var pins: Pins { session?.pins ?? Pins() }

    /// Whether a note is pinned, read once for a whole search.
    var isNotePinned: (NoteRef) -> Bool {
        let pinned = Set(pins.values(of: .note))
        return { pinned.contains($0.relativePath) }
    }

    /// What pinning `row` would pin, if it is something that can be.
    func pin(for row: BarRow) -> Pins.Pin? {
        switch row {
        case .note(let note): Pins.Pin(.note, note.relativePath)
        // A matching line pins the note it is in.
        case .hit(let hit): Pins.Pin(.note, hit.note.relativePath)
        case .command(let command): Pins.Pin(.command, command.id)
        case .tag(let name, _): Pins.Pin(.tag, name)
        case .folder(let path, _): Pins.Pin(.folder, path)
        default: nil
        }
    }

    func isPinned(_ row: BarRow) -> Bool {
        pin(for: row).map(pins.contains) ?? false
    }

    @discardableResult
    func togglePin(_ pin: Pins.Pin) -> Bool {
        session?.togglePin(pin) ?? false
    }

    /// The pinned things of one kind as rows, in the order pinned, leaving
    /// out what no longer exists or cannot be shown here.
    func pinnedRows(_ kind: Pins.Kind, entireVault: Bool) -> [BarRow] {
        let values = pins.values(of: kind)
        guard !values.isEmpty else { return [] }
        switch kind {
        case .note:
            let inScope = folderFilter(entireVault, .notes)
            let byPath = Dictionary(index.notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            return values.compactMap { byPath[$0] }.filter { inScope?($0) ?? true }.map(BarRow.note)
        case .command:
            let byID = Dictionary(AppCommand.registry.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return values.compactMap { byID[$0] }.map(BarRow.command)
        case .tag:
            let tags = Set(index.allTags)
            return values.filter(tags.contains).map { BarRow.tag($0, count: index.noteCount(forTag: $0)) }
        case .folder:
            let counts = Dictionary(noteFolders.map { ($0.path, $0.count) }, uniquingKeysWith: { a, _ in a })
            return values.compactMap { path in counts[path].map { BarRow.folder(path, count: $0) } }
        }
    }

    /// A scope's list with what is pinned first, under its own heading, and
    /// taken out of the rest. With nothing pinned the list is unchanged; with
    /// pins and a list that had no headings, the rest is headed by its order.
    private func withPinned(
        _ kind: Pins.Kind, _ rows: [BarRow], order: QuickOpenOrder, entireVault: Bool,
        among: ((BarRow) -> Bool)? = nil
    ) -> [BarRow] {
        let pinned = pinnedRows(kind, entireVault: entireVault).filter { among?($0) ?? true }
        guard !pinned.isEmpty else { return rows }
        let taken = Set(pinned.map(\.id))
        var rest = rows.filter { !taken.contains($0.id) }
        // A heading left with nothing under it once the pins are out goes too.
        rest = rest.enumerated().filter { offset, row in
            guard case .heading = row else { return true }
            let next = rest.indices.contains(offset + 1) ? rest[offset + 1] : nil
            if case .heading = next { return false }
            return next != nil
        }.map(\.element)
        let headed = rest.contains { if case .heading = $0 { true } else { false } }
        if !headed, !rest.isEmpty {
            rest.insert(.heading(order.mode.heading), at: 0)
        }
        return [.heading("Pinned")] + pinned + rest
    }

    /// Records that the reader went into `scope`, so it ranks by use.
    func recordScopeUse(_ scope: BarScope) {
        FrecencyStore.commands.record(scope.useKey)
        RecentUses.record(scope.useKey)
    }

    /// Commands, tags or folders with nothing typed, the way Quick Open lists
    /// notes: one order first and the other after, as the scope's setting
    /// says, headed by order; or one order alone, without headings.
    private func arrangedRows<Item>(
        _ items: [Item], kind: String, order: QuickOpenOrder, name: (Item) -> String,
        key: (Item) -> String, scoreKey: (Item) -> String, row: (Item) -> BarRow
    ) -> [BarRow] {
        let lastUsed = RecentUses.dates()
        let arranged = order.arrangeItems(
            items, name: name,
            lastUsed: { lastUsed[key($0)]?.timeIntervalSince1970 },
            useScore: { FrecencyStore.commands.score(scoreKey($0)) }
        )
        guard let heading = arranged.heading else {
            return (arranged.lead + arranged.rest).map(row)
        }
        // The order alone, as Notes heads its own: the chip already says
        // what kind of thing is listed.
        return [.heading(heading.title)] + arranged.lead.map(row)
            + [.heading(heading.other.title)] + arranged.rest.map(row)
    }

    /// Commands that cannot run moved to the end of whichever part they are
    /// in, so the first row of each is one Return can act on.
    private func sinkingDisabledWithinParts(_ rows: [BarRow]) -> [BarRow] {
        var result: [BarRow] = []
        var part: [BarRow] = []
        func flush() {
            result += AppCommand.sinkingDisabled(part) { row in
                if case .command(let command) = row { return command.isEnabled(on: self) }
                return true
            }
            part = []
        }
        for row in rows {
            if case .heading = row { flush(); result.append(row) } else { part.append(row) }
        }
        flush()
        return result
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
            query, limit: 200, familiarity: familiarity, pinned: isNotePinned,
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
