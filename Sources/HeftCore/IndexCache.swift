import Foundation

/// What each note parsed to, kept on disk between runs.
///
/// The index already re-reads only files whose size or date changed within a
/// process; this carries that across processes, so a `heft` verb and a cold
/// start read only what changed since the last one instead of every note.
/// Nothing here is trusted beyond the fingerprint: a note whose file differs
/// is read again, and a file the cache cannot decode is ignored.
///
/// Application Support rather than the vault, for the reason `ReadLog` gives:
/// this is one machine's scratch state, and a file in an iCloud vault would
/// sync for nobody's benefit. `HEFT_INDEX_CACHE` moves it for tests.
public final class IndexCache: @unchecked Sendable {
    public let directory: URL

    /// Whether this is the user's own store rather than one a test pointed
    /// at. The user's store does not persist vaults under the temporary
    /// directory: those are disposable, made by tests in this process, and
    /// would otherwise leave a file each behind.
    private let isUserStore: Bool

    public init(directory: URL) {
        self.directory = directory
        isUserStore = false
    }

    private init(userStore directory: URL) {
        self.directory = directory
        isUserStore = true
    }

    public static let shared: IndexCache = {
        if let override = ProcessInfo.processInfo.environment["HEFT_INDEX_CACHE"], !override.isEmpty {
            return IndexCache(directory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Heft/Index", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Heft/Index")
        return IndexCache(userStore: directory)
    }()

    private func persists(_ vault: URL) -> Bool {
        guard isUserStore else { return true }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return !vault.resolvingSymlinksInPath().path.hasPrefix(temporary)
    }

    /// Bumped when what a note parses to changes shape, so an older file is
    /// ignored rather than decoded into something wrong.
    static let version = 1

    /// A vault nothing has opened for this long is swept on the next write.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    struct File: Codable {
        let version: Int
        let notes: [String: ParsedNote]
    }

    /// One file per vault, named from its path.
    func url(for vault: URL) -> URL {
        let identity = vault.standardizedFileURL.path
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(identity.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.json", hash))
    }

    /// The last build's parses for `vault`, as an index a build can reuse, or
    /// nil when there is none worth reusing.
    public func load(vault: URL) -> VaultIndex? {
        guard let data = try? Data(contentsOf: url(for: vault)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == Self.version
        else { return nil }
        return VaultIndex.fromCache(parsed: file.notes)
    }

    /// Writes what `index` parsed, and forgets vaults not seen in a month.
    public func save(_ index: VaultIndex, vault: URL) {
        guard persists(vault) else { return }
        let file = File(version: Self.version, notes: index.parsed)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: vault), options: .atomic)
        sweep()
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let modified = try? file.resourceValues(forKeys: keys).contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension VaultIndex {
    /// The index for the vault at `root`, read from its files, reusing the
    /// on-disk parse cache and refreshing it. What every headless verb wants.
    public static func open(vaultAt root: URL, cache: IndexCache = .shared) -> VaultIndex {
        let tree = VaultScanner.scan(root: root)
        return open(tree: tree, vaultAt: root, cache: cache)
    }

    /// The same, for a caller that has already scanned.
    public static func open(tree: VaultItem, vaultAt root: URL, cache: IndexCache = .shared) -> VaultIndex {
        let index = build(root: tree, reusing: cache.load(vault: root))
        if index.notesRead > 0 { cache.save(index, vault: root) }
        return index
    }
}
