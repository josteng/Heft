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
            // By id where the timestamps tie, which they do: the dates are
            // encoded to the second, and two proposals from one agent run land
            // inside one. Without it the list reorders itself between reads.
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    /// A readable id for a proposal.
    ///
    /// It was a bare UUID, which nobody can read, say out loud or type: `heft
    /// diff` and `heft drop` took a string that had to be copied, and a review
    /// centre listing several would have shown a column of hex. The summary is
    /// already one line on what the change is for, so it is the name.
    ///
    /// The note's name stands in when there is no summary, because the default
    /// one is the same words every time and `proposed-edit-7` names nothing.
    ///
    /// Collisions get a number rather than a hash: two proposals to tighten the
    /// same opening genuinely are `tighten-the-opening` and
    /// `tighten-the-opening-2`, and a prefix long enough to tell them apart is
    /// still short enough to type. Nothing here can produce `/`, `.` or an
    /// empty string, which matters because the id is also the filename.
    public static func identifier(
        summary: String?, noteName: String, taken: Set<String>
    ) -> String {
        let described = (summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty || $0 == defaultSummary ? nil : $0
        }
        // Without the extension: `before-release-md` reads as a mistake.
        let plain = (noteName as NSString).deletingPathExtension
        var base = slug(described ?? (plain.isEmpty ? noteName : plain))
        if base.isEmpty { base = "proposal" }
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// What `propose` calls a change nobody described.
    public static let defaultSummary = "Proposed edit"

    /// Long enough to be recognisable, short enough to type, and cut between
    /// words: `tighten-the-opening-and-add-a-next-secti` reads as a mistake
    /// where `tighten-the-opening-and-add-a-next` reads as a name.
    static let slugLimit = 40

    static func slug(_ text: String) -> String {
        var out = ""
        var word = ""
        /// False once a word will not fit, which ends the name. Skipping that
        /// word and taking the next one that happens to be short enough reads
        /// as a typo rather than a truncation.
        func flush() -> Bool {
            guard !word.isEmpty else { return true }
            let joined = out.isEmpty ? word : out + "-" + word
            word = ""
            if joined.count <= slugLimit {
                out = joined
                return true
            }
            // One word longer than the whole limit has no boundary to cut on,
            // so it is cut anyway rather than leaving nothing.
            if out.isEmpty { out = String(joined.prefix(slugLimit)) }
            return false
        }
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !flush() {
                return out
            }
        }
        _ = flush()
        return out
    }

    /// Which proposal an id names.
    ///
    /// Prefix matching is the point — nobody types a whole id — but an empty
    /// string is a prefix of everything, so `heft drop <vault> ""` used to
    /// delete whichever proposal happened to be first, and report success. A
    /// shell that expanded a variable to nothing was enough to lose one.
    ///
    /// An ambiguous prefix is refused rather than resolved to the first match,
    /// for the same reason: the caller meant one of them and there is no way
    /// to know which.
    public enum Match: Equatable, Sendable {
        case one(String)
        /// No id was given at all.
        case missing
        case unknown(String)
        case ambiguous([String])
    }

    public static func match(_ id: String?, among proposals: [Proposal]) -> Match {
        guard let id, !id.isEmpty else { return .missing }
        let hits = proposals.filter { $0.id.hasPrefix(id) }.map(\.id)
        guard let first = hits.first else { return .unknown(id) }
        return hits.count == 1 ? .one(first) : .ambiguous(hits)
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
