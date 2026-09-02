import Foundation

/// An edit an agent wants to make to a note, which has not been made.
///
/// The whole point is that this is *not* the note. An agent writing straight
/// into the vault is indistinguishable from the user's own typing five minutes
/// later, and there is nothing left to review. A proposal keeps the note
/// untouched and carries enough context to be judged: what the agent saw when
/// it started (`base`), what it wants instead (`body`), and why.
public struct Proposal: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Vault-relative path, e.g. `Projects/Heft.md`. May name a note that does
    /// not exist yet: that is a proposal to create one.
    public let notePath: String
    /// The note's full text as the agent read it. Nil when the agent proposed
    /// a new note, or worked without reading first.
    public let base: String?
    /// The full text the agent proposes the note should have.
    public let body: String
    /// Who is asking. Free-form, shown as-is.
    public let agent: String
    /// One line on what this change is for.
    public let summary: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        notePath: String,
        base: String?,
        body: String,
        agent: String,
        summary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.notePath = notePath
        self.base = base
        self.body = body
        self.agent = agent
        self.summary = summary
        self.createdAt = createdAt
    }

    public var noteName: String {
        let last = notePath.split(separator: "/").last.map(String.init) ?? notePath
        return last.hasSuffix(".md") ? String(last.dropLast(3)) : last
    }

    /// The diff against whatever the note says *now*, which is not necessarily
    /// what the agent read. Diffing against the live file rather than against
    /// `base` is deliberate: the user is deciding about their current note, and
    /// a hunk that no longer changes anything should not be offered.
    public func diff(against current: String) -> NoteDiff {
        NoteDiff.between(original: current, proposed: body)
    }

    /// True when the note moved on after the agent read it. Not fatal — the
    /// diff is still computed against the current text — but worth saying,
    /// because the agent's reasoning was about an older version.
    public func isStale(against current: String) -> Bool {
        guard let base else { return false }
        return base != current
    }
}

/// The proposals waiting in a vault.
///
/// One JSON file per proposal under `.heft/proposals`, rather than a single
/// index file. Two agents writing at once then cannot lose each other's work,
/// and a proposal can be inspected or deleted with `cat` and `rm` when
/// something goes wrong. `.heft` is hidden and is not `.obsidian`, so Obsidian
/// ignores it and so does the vault scanner.
public enum ProposalStore {

    public static func directory(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".heft/proposals", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public static func write(_ proposal: Proposal, in vaultRoot: URL) throws -> URL {
        let folder = directory(in: vaultRoot)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        let url = folder.appendingPathComponent("\(proposal.id).json")
        try encoder.encode(proposal).write(to: url, options: .atomic)
        return url
    }

    /// Every pending proposal, oldest first. Unreadable files are skipped
    /// rather than thrown: one corrupt proposal must not hide the others.
    public static func all(in vaultRoot: URL) -> [Proposal] {
        let folder = directory(in: vaultRoot)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Proposal? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Proposal.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public static func forNote(_ relativePath: String, in vaultRoot: URL) -> [Proposal] {
        all(in: vaultRoot).filter { $0.notePath == relativePath }
    }

    public static func remove(_ id: String, in vaultRoot: URL) {
        let url = directory(in: vaultRoot).appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Rewrites a proposal so that the hunks already dealt with are gone.
    ///
    /// Accepting some hunks and leaving others has to leave *something* behind,
    /// or the rest of the agent's work is silently dropped. What is left is a
    /// new proposal against the note as it now stands, carrying only the hunks
    /// the user has not answered yet.
    public static func settle(
        _ proposal: Proposal,
        currentText: String,
        accepted: Set<Int>,
        rejected: Set<Int>,
        in vaultRoot: URL
    ) throws -> (noteText: String, remaining: Proposal?) {
        let diff = proposal.diff(against: currentText)
        let updated = NoteDiff.apply(diff.hunks, to: currentText, accepting: accepted)

        let outstanding = Set(diff.hunks.lazy
            .filter { !accepted.contains($0.id) && !rejected.contains($0.id) }
            .map(\.id))
        guard !outstanding.isEmpty else {
            remove(proposal.id, in: vaultRoot)
            return (updated, nil)
        }

        // What is left is expressed the same way the original was: the full
        // text the agent would like. Applying the accepted *and* the untouched
        // hunks gives exactly that, and leaves out the rejected ones for good.
        // Diffed against `updated`, it comes back as the outstanding hunks and
        // nothing else.
        let stillWanted = NoteDiff.apply(
            diff.hunks, to: currentText, accepting: accepted.union(outstanding)
        )
        let remaining = Proposal(
            id: proposal.id,
            notePath: proposal.notePath,
            base: updated,
            body: stillWanted,
            agent: proposal.agent,
            summary: proposal.summary,
            createdAt: proposal.createdAt
        )
        try write(remaining, in: vaultRoot)
        return (updated, remaining)
    }
}
