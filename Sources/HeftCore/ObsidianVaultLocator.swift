import Foundation

/// Finds vaults the user already has, so first launch can offer them instead
/// of opening a file picker into an empty home folder.
public enum ObsidianVaultLocator {

    public struct Candidate: Identifiable, Hashable, Sendable {
        public let url: URL
        public let name: String
        /// True when the folder is inside an iCloud Drive container.
        public let isInICloud: Bool
        public var id: String { url.path }
    }

    /// Reads Obsidian's own vault registry. Absent Obsidian, returns whatever
    /// the iCloud scan finds.
    public static func knownVaults() -> [Candidate] {
        var seen = Set<String>()
        var results: [Candidate] = []

        for url in registryVaults() + iCloudVaults() {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted
            else { continue }
            results.append(Candidate(
                url: standardized,
                name: standardized.lastPathComponent,
                isInICloud: standardized.path.contains("/Mobile Documents/")
            ))
        }
        return results
    }

    private static func registryVaults() -> [URL] {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: registry),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]]
        else { return [] }

        // Most recently opened first: `ts` is Obsidian's last-opened timestamp.
        return vaults.values
            .compactMap { entry -> (URL, Double)? in
                guard let path = entry["path"] as? String else { return nil }
                return (URL(fileURLWithPath: path), entry["ts"] as? Double ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Folders directly inside the iCloud Obsidian container, for the case
    /// where the vault syncs to this Mac but Obsidian is not installed here.
    private static func iCloudVaults() -> [URL] {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries.filter { url in
            !url.lastPathComponent.hasPrefix(".")
            && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }
}
