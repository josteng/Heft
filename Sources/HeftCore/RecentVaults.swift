import Foundation

/// The list behind File ▸ Open Recent.
///
/// Kept here, and pure, because the two things that make such a menu good or
/// annoying are both list arithmetic: what order it ends up in, and what the
/// entries are called when several vaults share a folder name. Neither needs a
/// filesystem to decide.
public enum RecentVaults {

    /// How many vaults are remembered. Long enough to hold the handful anyone
    /// actually alternates between, short enough that the menu stays readable.
    public static let limit = 10

    /// `existing` with `path` moved to the front.
    ///
    /// Reopening a vault promotes it rather than adding a second entry, so the
    /// order is genuinely "most recently used" and the pair someone switches
    /// between stays at the top.
    public static func recording(_ path: String, in existing: [String]) -> [String] {
        var updated = existing.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > limit { updated.removeLast(updated.count - limit) }
        return updated
    }

    /// What each path is called in the menu.
    ///
    /// A vault's folder name is normally enough. It stops being enough exactly
    /// when someone keeps a test copy of a vault beside the real one, which is
    /// the case this menu exists to serve: two entries both reading
    /// "PersonalVault" would be worse than useless. Those get their parent
    /// folder appended, and only those, so the common case stays short.
    public static func labels(for paths: [String]) -> [String] {
        let names = paths.map { name(of: $0) }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }

        return zip(paths, names).map { path, name in
            guard counts[name, default: 0] > 1 else { return name }
            let parent = self.name(of: parentPath(of: path))
            return parent.isEmpty ? name : "\(name) — \(parent)"
        }
    }

    private static func name(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private static func parentPath(of path: String) -> String {
        var parts = path.split(separator: "/")
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }
}
