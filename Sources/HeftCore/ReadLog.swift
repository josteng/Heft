import Foundation

/// What an agent was last handed for a note.
///
/// `propose` takes the complete new body, which is only safe if the agent has
/// seen the note it is replacing. Nothing checked that: `base` was read at
/// propose time, so a note the user typed into between the agent's read and
/// its proposal looked untouched, and the proposal quietly reverted their
/// edit. It showed up in the diff, but as an ordinary hunk among the agent's
/// own, with nothing to say the agent had never seen the line it was removing.
///
/// So `read` records what it handed over and `propose` holds the note to it.
/// The same record answers the other question an agent could not ask before —
/// what moved since I last looked — which is `heft changes`.
///
/// One snapshot per note, replaced on every read, which is what both questions
/// are about: the *last* thing the agent saw. A history would be a second way
/// to be out of date.
///
/// It lives in Application Support rather than in `.heft/` beside the
/// proposals. A proposal is addressed to the reader and belongs with their
/// vault; a read snapshot is scratch state belonging to one machine's agent,
/// and writing one into an iCloud vault on every `heft read` would sync a file
/// per note read, for nobody's benefit. It is also the difference between a
/// vault kept in git carrying this and not.
public struct ReadLog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let relativePath: String
        /// The note's full text, exactly as `heft read` wrote it.
        public let text: String
        public let readAt: Date

        public init(relativePath: String, text: String, readAt: Date) {
            self.relativePath = relativePath
            self.text = text
            self.readAt = readAt
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `HEFT_READ_LOG` moves the store, the way `HEFT_DEFAULTS_SUITE` moves the
    /// preferences: a test drives the real binary as a subprocess, and must not
    /// write into the reader's own Application Support to do it.
    public static let shared = ReadLog(directory: {
        if let override = ProcessInfo.processInfo.environment["HEFT_READ_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Heft/Reads", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Heft/Reads")
    }())

    /// A snapshot nothing has asked about for this long is swept on the next
    /// write. An agent that has not looked at a note in a week is not about to
    /// propose against what it saw then, and the folder would otherwise grow
    /// one file per note ever read.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// One file per note, named from the vault and note path.
    ///
    /// Hashed for the reason `DraftStore` hashes: a note path can hold any
    /// character a filesystem allows, and a name built by substitution
    /// collides the moment two notes differ only in a character that had to be
    /// replaced.
    func url(vault: URL, relativePath: String) -> URL {
        let identity = "\(vault.standardizedFileURL.path)\u{0}\(relativePath)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(identity.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.json", hash))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func record(_ text: String, vault: URL, relativePath: String, at now: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Entry(relativePath: relativePath, text: text, readAt: now)
        try? Self.encoder.encode(entry).write(
            to: url(vault: vault, relativePath: relativePath), options: .atomic
        )
        sweep(now: now)
    }

    public func last(vault: URL, relativePath: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(vault: vault, relativePath: relativePath)) else {
            return nil
        }
        return try? Self.decoder.decode(Entry.self, from: data)
    }

    public func forget(vault: URL, relativePath: String) {
        try? FileManager.default.removeItem(at: url(vault: vault, relativePath: relativePath))
    }

    /// Drops every snapshot past its retention. Cheap enough to run on each
    /// write: the folder holds one small file per note an agent has read.
    public func sweep(now: Date = Date()) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in contents where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? Self.decoder.decode(Entry.self, from: data)
            else { continue }
            if now.timeIntervalSince(entry.readAt) > Self.retention {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - The question propose asks

    /// Whether a proposal built from the last read may be trusted.
    public enum Freshness: Equatable, Sendable {
        /// Nothing was recorded: the agent proposed without reading, which is
        /// its own business. Nothing to be stale against.
        case unread
        case fresh
        /// The note moved on after the agent read it.
        case stale(readAt: Date)
    }

    public func freshness(vault: URL, relativePath: String, current: String?) -> Freshness {
        guard let entry = last(vault: vault, relativePath: relativePath) else { return .unread }
        return entry.text == (current ?? "") ? .fresh : .stale(readAt: entry.readAt)
    }
}
