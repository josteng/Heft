import Foundation

/// How often something is used, discounted by how long ago.
///
/// One number rather than two lists. A use adds 1 to an item's score, and the
/// score halves every `halfLife`; reading it applies the decay owed since the
/// last write. That is algebraically the same as summing `0.5 ^ (age /
/// halfLife)` over every past use, but it needs one Double and one date per
/// item instead of a history, and no pruning.
///
/// The alternatives were both worse. Pure recency (an MRU list, which is what
/// `VaultSession.recentPaths` already keeps for the sidebar) puts a note you
/// opened once by accident above one you open every morning. Pure frequency
/// never lets go of what you worked on last year. This is the model Firefox
/// named "frecency" and zoxide approximates with time buckets; the continuous
/// form is used here because it has no cliff edges — nothing is reordered
/// merely by a clock passing midnight.
public struct Frecency: Codable, Equatable, Sendable {

    /// How long a use takes to count half as much.
    ///
    /// Three days. Long enough that the note you were on yesterday still
    /// outranks a stranger, short enough that finishing a project lets it fall
    /// away within a fortnight. A week felt sticky in use; a day made the list
    /// thrash.
    public static let halfLife: TimeInterval = 3 * 24 * 60 * 60

    private struct Entry: Codable, Equatable {
        var score: Double
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Records one use of `key`.
    public mutating func record(_ key: String, at now: Date = Date()) {
        let decayed = decayedScore(for: key, at: now)
        entries[key] = Entry(score: decayed + 1, lastUsed: now)
        prune()
    }

    /// The score for `key` right now. Zero for anything never used.
    public func score(_ key: String, at now: Date = Date()) -> Double {
        decayedScore(for: key, at: now)
    }

    public func hasRecord(of key: String) -> Bool { entries[key] != nil }

    /// Orders `keys` by score, highest first, and breaks ties with `tiebreak`
    /// so the result is stable rather than dependent on dictionary order.
    ///
    /// Anything with no record scores 0 and therefore keeps `tiebreak`'s
    /// order among itself, which is what makes an untouched vault open the
    /// switcher alphabetically rather than at random.
    public func ranked<Key>(
        _ keys: [Key],
        at now: Date = Date(),
        by identity: (Key) -> String,
        tiebreak: (Key, Key) -> Bool
    ) -> [Key] {
        keys.enumerated()
            .map { (offset: $0.offset, key: $0.element, score: score(identity($0.element), at: now)) }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if tiebreak(left.key, right.key) { return true }
                if tiebreak(right.key, left.key) { return false }
                return left.offset < right.offset
            }
            .map(\.key)
    }

    private func decayedScore(for key: String, at now: Date) -> Double {
        guard let entry = entries[key] else { return 0 }
        let age = now.timeIntervalSince(entry.lastUsed)
        // A clock that has gone backwards must not inflate a score.
        guard age > 0 else { return entry.score }
        return entry.score * pow(0.5, age / Self.halfLife)
    }

    /// Forgets what has decayed to nothing, so the store cannot grow without
    /// bound in a vault used for years.
    private mutating func prune(limit: Int = 400) {
        guard entries.count > limit else { return }
        let now = Date()
        let keep = entries
            .map { ($0.key, decayedScore(for: $0.key, at: now)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit / 2)
            .map(\.0)
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: - Storage

    public init(decoding data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            self = Frecency()
            return
        }
        self = decoded
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }
}
