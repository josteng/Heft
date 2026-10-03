import Foundation

/// How Quick Open orders its list while nothing is typed: a short block of
/// one kind first, then every other note ordered the other way.
///
/// Frecency alone was slow to admit a new note: one opened once today scored
/// below one opened ten times last week, so the note just made was the one
/// the switcher could not find. Obsidian answers with recency alone, which
/// loses the notes opened every morning. A short block of one above the rest
/// in the other keeps both, and the block is the reader's to size or turn
/// off, because how many recent notes are worth a row is a matter of habit.
/// Typed queries are untouched: match quality ranks them, as before.
public struct QuickOpenOrder: Equatable, Sendable {

    public enum Lead: String, CaseIterable, Identifiable, Sendable {
        /// Last opened first; the rest by frecency.
        case recent
        /// Most used first; the rest by when they were last opened.
        case frequent

        public var id: String { rawValue }

        /// The order the rest of the list follows when this one leads.
        public var other: Lead { self == .recent ? .frequent : .recent }

        public var title: String {
            switch self {
            case .recent: "Recent"
            case .frequent: "Frequent"
            }
        }
    }

    /// A list in one plain order instead of by use: by name, or for notes
    /// by when the file was last written. "Recent" is when a note was last
    /// opened, which is not the same thing.
    public enum Sort: String, CaseIterable, Sendable {
        case alphabetical, lastEdited
    }

    public var lead: Lead
    /// How many notes the leading block holds. Zero leaves only the second
    /// order, without headings.
    public var count: Int
    /// Overrides the lead and count while set; they are kept, so going back
    /// to an order by use finds the block as it was.
    public var sort: Sort?

    /// The ways the setting is offered: one order first and the other
    /// after, one order alone, or a plain sort. "Alone" is a leading block of
    /// none, which is how it has always been stored, so the settings read
    /// the same.
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case recentFirst, frequentFirst, recentOnly, frequentOnly, alphabetical, lastEdited

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recentFirst: "Recent first"
            case .frequentFirst: "Frequent first"
            case .recentOnly: "Recent only"
            case .frequentOnly: "Frequent only"
            case .alphabetical: "Alphabetical"
            case .lastEdited: "Last edited"
            }
        }

        /// What the list is headed when something is pinned above it.
        public var heading: String {
            switch self {
            case .recentFirst, .recentOnly: "Recent"
            case .frequentFirst, .frequentOnly: "Frequent"
            case .alphabetical: "Alphabetical"
            case .lastEdited: "Last edited"
            }
        }

        public var isSplit: Bool { self == .recentFirst || self == .frequentFirst }

        /// The choices for a list. Only notes have a file to have been edited.
        public static func choices(lastEdited: Bool) -> [Mode] {
            lastEdited ? allCases : allCases.filter { $0 != .lastEdited }
        }
    }

    public var mode: Mode {
        switch sort {
        case .alphabetical: return .alphabetical
        case .lastEdited: return .lastEdited
        case nil: break
        }
        return switch (lead, count == 0) {
        case (.recent, false): .recentFirst
        case (.frequent, false): .frequentFirst
        // No leading block: the list is all in the other order.
        case (.recent, true): .frequentOnly
        case (.frequent, true): .recentOnly
        }
    }

    /// This order in `mode`, keeping the count where it still applies.
    public func with(mode: Mode) -> QuickOpenOrder {
        let kept = count == 0 ? Self.standard.count : count
        switch mode {
        case .alphabetical: return QuickOpenOrder(lead: lead, count: count, sort: .alphabetical)
        case .lastEdited: return QuickOpenOrder(lead: lead, count: count, sort: .lastEdited)
        case .recentFirst: return QuickOpenOrder(lead: .recent, count: kept)
        case .frequentFirst: return QuickOpenOrder(lead: .frequent, count: kept)
        case .recentOnly: return QuickOpenOrder(lead: .frequent, count: 0)
        case .frequentOnly: return QuickOpenOrder(lead: .recent, count: 0)
        }
    }

    /// The same arrangement for anything with a last use and a use score:
    /// commands, tags and folders, as notes have it.
    ///
    /// - Parameters:
    ///   - fallback: every item in the order to fall back on, for ties and
    ///     for what was never used.
    ///   - name: what an alphabetical order sorts by.
    /// - Returns: the leading block, the rest, and which order leads, nil when
    ///   only one part has anything in it. A plain sort is all rest.
    public func arrangeItems<Item>(
        _ fallback: [Item], name: (Item) -> String,
        lastUsed: (Item) -> Double?, useScore: (Item) -> Double
    ) -> (lead: [Item], rest: [Item], heading: Lead?) {
        switch sort {
        case .alphabetical: return ([], Self.alphabetical(fallback, name: name), nil)
        // Only notes have an edit date; anything else stays as given.
        case .lastEdited: return ([], fallback, nil)
        case nil: break
        }
        func ranked(_ value: (Item) -> Double?) -> [Ranked] {
            var found: [Ranked] = []
            for (offset, item) in fallback.enumerated() {
                if let value = value(item) { found.append(Ranked(offset: offset, value: value)) }
            }
            // Swift's sort is not stable, so the fallback order breaks ties.
            return found.sorted { $0.value == $1.value ? $0.offset < $1.offset : $0.value > $1.value }
        }
        let byRecency: [Int] = ranked(lastUsed).map { $0.offset }
        let byUseRanked: [Ranked] = ranked { useScore($0) }
        let byUse: [Int] = byUseRanked.map { $0.offset }
        let used: [Int] = byUseRanked.filter { $0.value > 0 }.map { $0.offset }

        let leadOffsets: [Int]
        var restOffsets: [Int]
        switch lead {
        case .recent:
            leadOffsets = Array(byRecency.prefix(count))
            restOffsets = byUse
        case .frequent:
            leadOffsets = Array(used.prefix(count))
            let opened = Set(byRecency)
            restOffsets = byRecency + byUse.filter { !opened.contains($0) }
        }
        let taken = Set(leadOffsets)
        restOffsets.removeAll { taken.contains($0) }
        let leadItems = leadOffsets.map { fallback[$0] }
        let restItems = restOffsets.map { fallback[$0] }
        return (leadItems, restItems, leadItems.isEmpty || restItems.isEmpty ? nil : lead)
    }

    public static let countRange = 0...20
    public static let standard = QuickOpenOrder(lead: .recent, count: 5)

    public init(lead: Lead, count: Int, sort: Sort? = nil) {
        self.lead = lead
        self.count = count.clamped(to: Self.countRange)
        self.sort = sort
    }

    /// By name as Finder sorts, so "Note 2" comes before "Note 10"; the
    /// order given breaks ties.
    static func alphabetical<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, name: name($0.element)) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
            }
            .map(\.item)
    }

    /// The list, split where the headings go.
    public struct Arranged: Equatable, Sendable {
        public var lead: [NoteRef]
        public var rest: [NoteRef]
        /// Which order leads. Nil when there is nothing to tell apart: an
        /// empty leading block, or nothing after it.
        public var heading: Lead?

        public var all: [NoteRef] { lead + rest }

        /// Named after the order it follows, since that is what a reader
        /// would choose it for; "Other Notes" said nothing about why a note
        /// sat where it did.
        public var restHeading: Lead? { heading?.other }

        public init(lead: [NoteRef], rest: [NoteRef], heading: Lead?) {
            self.lead = lead
            self.rest = rest
            self.heading = heading
        }

        /// What the list draws, headings included. A heading is a row the
        /// arrows reach like any other, so choosing one is the same gesture
        /// as choosing a note.
        public var rows: [Row] {
            guard let heading else { return all.map(Row.note) }
            var rows = [Row.heading(heading)] + lead.map(Row.note)
            if let restHeading, !rest.isEmpty {
                rows += [.heading(restHeading)] + rest.map(Row.note)
            }
            return rows
        }

        /// Where the selection starts: on the first note, not on a heading,
        /// so Return straight away still opens the note at the top.
        public var firstNoteRow: Int {
            rows.firstIndex { if case .note = $0 { true } else { false } } ?? 0
        }
    }

    public enum Row: Hashable, Sendable {
        case heading(Lead)
        case note(NoteRef)
    }

    /// One order on its own and in full, for a heading chosen in the list:
    /// every note in the opening history, or every note with any use.
    public static func section(
        _ kind: Lead, of byUse: [NoteRef], recent: [String], limit: Int,
        isUsed: (NoteRef) -> Bool
    ) -> [NoteRef] {
        switch kind {
        case .recent:
            let byPath = Dictionary(byUse.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            return Array(recent.lazy.compactMap { byPath[$0] }.prefix(limit))
        case .frequent:
            return Array(byUse.lazy.filter(isUsed).prefix(limit))
        }
    }

    /// Orders the notes for an empty query.
    ///
    /// - Parameters:
    ///   - byUse: every note that may be listed, most used first, with
    ///     unused notes after in a stable order. What `VaultIndex.search`
    ///     returns for an empty query.
    ///   - recent: vault-relative paths, last opened first. Paths that are
    ///     not in `byUse` are skipped, which is how scope and deleted notes
    ///     are honoured without a second filter.
    ///   - isUsed: whether a note has any use recorded, so a "Frequent"
    ///     block never pads itself with notes merely first alphabetically.
    ///   - edited: when a note's file was last written, for "Last edited".
    public func arrange(
        _ byUse: [NoteRef], recent: [String], limit: Int,
        isUsed: (NoteRef) -> Bool, edited: (NoteRef) -> Date? = { _ in nil }
    ) -> Arranged {
        switch sort {
        case .alphabetical:
            let sorted = Self.alphabetical(byUse) { $0.name }
            return Arranged(lead: [], rest: Array(sorted.prefix(limit)), heading: nil)
        case .lastEdited:
            // A note without a date last; ties keep the order given.
            let dated = byUse.enumerated().map { (offset: $0.offset, note: $0.element, date: edited($0.element)) }
            let sorted = dated.sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.offset < b.offset
                }
            }
            return Arranged(lead: [], rest: Array(sorted.prefix(limit).map(\.note)), heading: nil)
        case nil: break
        }
        let byRecency = Self.section(
            .recent, of: byUse, recent: recent, limit: .max, isUsed: isUsed
        )

        let lead: [NoteRef]
        var rest: [NoteRef]
        switch self.lead {
        case .recent:
            lead = Array(byRecency.prefix(count))
            rest = byUse
        case .frequent:
            lead = Self.section(.frequent, of: byUse, recent: recent, limit: count, isUsed: isUsed)
            // Opened notes by when, then the rest in the order they came.
            let opened = Set(byRecency.map(\.relativePath))
            rest = byRecency + byUse.filter { !opened.contains($0.relativePath) }
        }
        let taken = Set(lead.map(\.relativePath))
        rest.removeAll { taken.contains($0.relativePath) }

        let room = max(limit - lead.count, 0)
        let trimmedLead = Array(lead.prefix(limit))
        rest = Array(rest.prefix(room))
        return Arranged(
            lead: trimmedLead, rest: rest,
            heading: trimmedLead.isEmpty || rest.isEmpty ? nil : self.lead
        )
    }

    // MARK: - Storage

    public static let leadKey = "dev.stenglein.Heft.quickOpen.lead"
    public static let countKey = "dev.stenglein.Heft.quickOpen.count"

    public static var current: QuickOpenOrder { current(in: HeftDefaults.shared) }

    public static let sortKey = "dev.stenglein.Heft.quickOpen.sort"

    public static func current(in defaults: UserDefaults) -> QuickOpenOrder {
        load(in: defaults, keys: (leadKey, countKey, sortKey))
    }

    public func save(in defaults: UserDefaults) {
        save(in: defaults, keys: (Self.leadKey, Self.countKey, Self.sortKey))
    }

    typealias Keys = (lead: String, count: String, sort: String)

    static func load(in defaults: UserDefaults, keys: Keys) -> QuickOpenOrder {
        QuickOpenOrder(
            lead: defaults.string(forKey: keys.lead).flatMap(Lead.init(rawValue:)) ?? standard.lead,
            count: defaults.object(forKey: keys.count) == nil
                ? standard.count : defaults.integer(forKey: keys.count),
            sort: defaults.string(forKey: keys.sort).flatMap(Sort.init(rawValue:))
        )
    }

    func save(in defaults: UserDefaults, keys: Keys) {
        defaults.set(lead.rawValue, forKey: keys.lead)
        defaults.set(count, forKey: keys.count)
        if let sort {
            defaults.set(sort.rawValue, forKey: keys.sort)
        } else {
            defaults.removeObject(forKey: keys.sort)
        }
    }
}

/// Recent or frequent first, or a plain sort, chosen for each scope on its
/// own: one reader wants the notes they opened last and the commands they
/// run most, and a folder's notes by name.
///
/// Notes keep Quick Open's keys, so the setting made before there were more
/// scopes carries over as the notes' row.
public struct ScopeOrders: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        // One tag's or one folder's notes sit under the list they are chosen from.
        case notes, commands, tags, tag, folders, folder

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .notes: "Notes (⌘O)"
            case .folder: "A folder's notes"
            case .tag: "A tag's notes"
            case .commands: "Commands (⌘P)"
            case .tags: "Tags"
            case .folders: "Folders"
            }
        }

        /// Whether the list is of notes, which can be ordered by last edit.
        public var listsNotes: Bool { self == .notes || self == .folder || self == .tag }

        /// Drawn indented under the list it belongs to.
        public var isNested: Bool { self == .folder || self == .tag }
    }

    private var orders: [Kind: QuickOpenOrder]

    public static let standard = ScopeOrders(orders: [:])

    public init(orders: [Kind: QuickOpenOrder]) {
        self.orders = orders
    }

    public subscript(kind: Kind) -> QuickOpenOrder {
        get { orders[kind] ?? .standard }
        set { orders[kind] = newValue }
    }

    public func matches(_ other: ScopeOrders) -> Bool {
        Kind.allCases.allSatisfy { self[$0] == other[$0] }
    }

    public static var current: ScopeOrders { current(in: HeftDefaults.shared) }

    public static func current(in defaults: UserDefaults) -> ScopeOrders {
        var result = ScopeOrders.standard
        for kind in Kind.allCases {
            result[kind] = QuickOpenOrder.load(in: defaults, keys: keys(for: kind))
        }
        return result
    }

    public func save(in defaults: UserDefaults) {
        for kind in Kind.allCases {
            self[kind].save(in: defaults, keys: Self.keys(for: kind))
        }
    }

    private static func keys(for kind: Kind) -> QuickOpenOrder.Keys {
        if kind == .notes { return (QuickOpenOrder.leadKey, QuickOpenOrder.countKey, QuickOpenOrder.sortKey) }
        let prefix = "dev.stenglein.Heft.scopeOrder.\(kind.rawValue)"
        return ("\(prefix).lead", "\(prefix).count", "\(prefix).sort")
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// An item's place in the fallback order and the value it ranks by.
private struct Ranked {
    let offset: Int
    let value: Double
}
