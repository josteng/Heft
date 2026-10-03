import Foundation

/// What ⌘T lists before anything is typed: rows in the reader's order, each
/// naming an order, the kinds of thing it lists and how many, the last row
/// filling the rest.
///
/// Its own setting, apart from Quick Open's. ⌘O switches notes and has two
/// sensible orders, which two controls cover; ⌘T is a start page that can
/// hold notes, commands, tags, folders and scopes. Five fixed sections were
/// tried first and read as presets with names that hid what they did ("All
/// notes" was frequent notes and then the rest); the two things every one of
/// them chose between, which order and which kinds, are the row itself now.
public struct StartList: Codable, Equatable, Sendable {

    /// Recent and frequent are different questions for anything: what was
    /// used last, and what is used most.
    public enum Order: String, Codable, CaseIterable, Sendable, Identifiable {
        case recent
        case frequent
        /// What the reader pinned, in the order they pinned it.
        case pinned

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recent: "Recent"
            case .frequent: "Frequent"
            case .pinned: "Pinned"
            }
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
        case notes
        case commands
        case tags
        case folders
        /// The bar's own scopes: Notes, Commands, Text and the rest.
        case scopes

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .notes: "Notes"
            case .commands: "Commands"
            case .tags: "Tags"
            case .folders: "Folders"
            case .scopes: "Scopes"
            }
        }

        public static func < (left: Kind, right: Kind) -> Bool {
            allCases.firstIndex(of: left)! < allCases.firstIndex(of: right)!
        }
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var order: Order
        public var kinds: Set<Kind>
        public var count: Int

        public init(id: UUID = UUID(), _ order: Order, _ kinds: Set<Kind>, count: Int) {
            self.id = id
            self.order = order
            self.kinds = kinds
            self.count = count.clamped(to: StartList.countRange)
        }

        /// The kinds in a fixed order, for showing and storing.
        public var sortedKinds: [Kind] { kinds.sorted() }

        /// What the row's heading in the bar says: the order and the kinds it
        /// lists, "Frequent notes and commands", up to three; past that a
        /// heading becomes a sentence, so it says the order alone.
        public var title: String {
            let names = sortedKinds.map { $0.title.lowercased() }
            switch names.count {
            case 1...2: return "\(order.title) \(names.joined(separator: " and "))"
            case 3: return "\(order.title) \(names[0]), \(names[1]) and \(names[2])"
            default: return order.title
            }
        }

        /// The kinds as a short phrase, for the settings row's menu.
        public var kindsSummary: String {
            if kinds.isEmpty { return "Nothing" }
            if kinds.count == Kind.allCases.count { return "Everything" }
            return sortedKinds.map(\.title).joined(separator: ", ")
        }
    }

    public var rows: [Row]

    public static let countRange = 1...30
    /// What the row filling the rest may hold at most, so a vault of
    /// thousands of notes is not laid out before anything is typed.
    public static let restLimit = 200

    /// What ⌘T listed before it could be configured: the notes opened last,
    /// what is used most of anything, then every note by use and name.
    ///
    /// A constant, so its rows keep their ids: built afresh on every read,
    /// no row of it was ever the last row of itself.
    public static let standard = StartList(rows: [
        // Empty until something is pinned, and then what was pinned first.
        Row(.pinned, Set(Kind.allCases), count: 10),
        Row(.recent, [.notes], count: 5),
        Row(.frequent, Set(Kind.allCases), count: 12),
        Row(.frequent, [.notes], count: 10),
    ])

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// The rows that list anything, in order, with how many each may list.
    /// The last has no count of its own: it fills the rest.
    public var plan: [(row: Row, limit: Int)] {
        let listing = rows.filter { !$0.kinds.isEmpty }
        return listing.enumerated().map { offset, row in
            (row, offset == listing.count - 1 ? Self.restLimit : row.count)
        }
    }

    /// Whether `row` fills the rest, so its count is not asked for.
    public func fillsRest(_ row: Row) -> Bool {
        rows.last(where: { !$0.kinds.isEmpty })?.id == row.id
    }

    /// Equal by content, so Reset is offered only when something differs,
    /// whatever ids the rows were given.
    public func matches(_ other: StartList) -> Bool {
        rows.count == other.rows.count && zip(rows, other.rows).allSatisfy {
            $0.order == $1.order && $0.kinds == $1.kinds && $0.count == $1.count
        }
    }

    // MARK: - Storage

    public static let defaultsKey = "dev.stenglein.Heft.searchBar.startRows"

    public static var current: StartList { current(in: HeftDefaults.shared) }

    public static func current(in defaults: UserDefaults) -> StartList {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return standard }
        // An order or a kind a later version added is dropped one by one
        // rather than failing the whole list.
        return StartList(rows: stored.rows.compactMap { raw in
            guard let order = Order(rawValue: raw.order) else { return nil }
            return Row(order, Set(raw.kinds.compactMap(Kind.init(rawValue:))), count: raw.count)
        })
    }

    public func save(in defaults: UserDefaults) {
        let stored = Stored(rows: rows.map {
            .init(order: $0.order.rawValue, kinds: $0.sortedKinds.map(\.rawValue), count: $0.count)
        })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }

    private struct Stored: Codable {
        struct Raw: Codable {
            var order: String
            var kinds: [String]
            var count: Int
        }
        var rows: [Raw]
    }
}

/// When things other than notes were last used: commands, tags, folders and
/// scopes, by the same keys their use scores are kept under.
///
/// The history beside the scores, as `recentPaths` is beside the notes'. A
/// score cannot say what was used last; a time can, and a time is what lets
/// a Recent row mix notes and commands in the order they were actually used.
public enum RecentUses {
    public static let defaultsKey = "dev.stenglein.Heft.recentUses"
    public static let limit = 60

    /// Every remembered key with when it was last used.
    public static func dates(in defaults: UserDefaults = HeftDefaults.shared) -> [String: Date] {
        let raw = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The remembered keys, last used first.
    public static func keys(in defaults: UserDefaults = HeftDefaults.shared) -> [String] {
        dates(in: defaults).sorted { $0.value > $1.value }.map(\.key)
    }

    public static func record(
        _ key: String, at now: Date = Date(), in defaults: UserDefaults = HeftDefaults.shared
    ) {
        var dates = dates(in: defaults)
        dates[key] = now
        if dates.count > limit {
            let kept = dates.sorted { $0.value > $1.value }.prefix(limit)
            dates = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        defaults.set(dates.mapValues(\.timeIntervalSince1970), forKey: defaultsKey)
    }

    /// The key a command's last use is kept under: prefixed, since the
    /// commands' scores are kept by bare id beside the scopes' prefixed keys.
    public static func commandKey(_ id: String) -> String { "command:\(id)" }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
