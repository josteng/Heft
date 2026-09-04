import Foundation

/// An edit an agent wants to make to a note, which has not been made.
///
/// The whole point is that this is *not* the note. An agent writing straight
/// into the vault is indistinguishable from the user's own typing five minutes
/// later, and there is nothing left to review. A proposal keeps the note
/// untouched and carries enough context to be judged: what the agent saw when
/// it started (`base`), what it wants instead (`body`), and why.
public struct Proposal: Codable, Sendable, Equatable, Identifiable {

    /// What kind of change this is.
    ///
    /// It used to be implied: a proposal carried a body, so it was an edit,
    /// and a nil `base` meant the note did not exist yet. That left two holes.
    /// A proposal for a note that does not exist has no note to draw a banner
    /// above, so it could not be reviewed at all — found by proposing this
    /// vault's own TODO note and then having to write it by hand. And deleting
    /// or moving a file was not proposable in any form, which is why
    /// `heft rename` applies immediately with no review.
    ///
    /// Creating, deleting and moving are facts about the *tree* rather than
    /// about one note's text, and a banner anchored to a note is the wrong
    /// place to decide them. Naming the kind is what lets the review centre
    /// list them somewhere that is not a note.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case edit
        case create
        case delete
        case move
    }

    /// The change several proposals belong to.
    ///
    /// "Rename this concept across twelve notes" was twelve unrelated
    /// proposals: accepting seven left the vault half-changed, and nothing
    /// recorded that they belonged together.
    ///
    /// Carried on each proposal rather than kept in a file of its own, so
    /// there is one format to read and nothing to keep in step. The id is the
    /// slug of the summary, which is what lets an agent join a group by
    /// repeating the same words rather than by passing an id around.
    public struct Group: Codable, Sendable, Equatable, Hashable {
        public let id: String
        public let summary: String

        public init(id: String, summary: String) {
            self.id = id
            self.summary = summary
        }

        public init(summary: String) {
            self.summary = summary
            self.id = ProposalStore.slug(summary).isEmpty
                ? "group" : ProposalStore.slug(summary)
        }
    }

    public let id: String
    /// Vault-relative path, e.g. `Projects/Heft.md`. May name a note that does
    /// not exist yet: that is a proposal to create one.
    public let notePath: String
    /// The note's full text as the agent read it. Nil when the agent proposed
    /// a new note, or worked without reading first.
    public let base: String?
    /// The full text the agent proposes the note should have. Empty for a
    /// delete or a move, which say nothing about a note's contents.
    public let body: String
    /// Who is asking. Free-form, shown as-is.
    public let agent: String
    /// One line on what this change is for.
    public let summary: String
    public let createdAt: Date
    public let kind: Kind
    /// Where a `.move` puts the file, vault-relative. Nil for every other kind.
    public let destination: String?
    public let group: Group?

    public init(
        id: String = UUID().uuidString,
        notePath: String,
        base: String?,
        body: String,
        agent: String,
        summary: String,
        createdAt: Date = Date(),
        kind: Kind = .edit,
        destination: String? = nil,
        group: Group? = nil
    ) {
        self.id = id
        self.notePath = notePath
        self.base = base
        self.body = body
        self.agent = agent
        self.summary = summary
        self.createdAt = createdAt
        self.kind = kind
        self.destination = destination
        self.group = group
    }

    /// Hand-written, because the synthesised one requires every field: adding
    /// `kind`, `destination` and `group` would have made every proposal
    /// written before them undecodable, and the failure mode is a proposal
    /// that silently disappears from the list. Same lesson as
    /// `PDFExportOptions` and `TypingSettings`: a stored file is a format, and
    /// a format has to tolerate being older than the code reading it.
    ///
    /// A proposal from before kinds existed carried a body, so it is an edit —
    /// or a create when it had no base to edit against, which is exactly what
    /// nil `base` used to mean.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        notePath = try container.decode(String.self, forKey: .notePath)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? "agent"
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
            ?? ProposalStore.defaultSummary
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? (base == nil ? .create : .edit)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        group = try container.decodeIfPresent(Group.self, forKey: .group)
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

    /// Whether this is a change to the tree rather than to a note's text.
    ///
    /// The line that matters for review: an edit is answered hunk by hunk, and
    /// a structural change has no hunks to answer — it happens or it does not.
    public var isStructural: Bool {
        kind == .delete || kind == .move
    }

    /// One line naming what would happen, for a list that has no note to sit
    /// above and so cannot rely on context to say what it is about.
    public var headline: String {
        switch kind {
        case .edit: "Edit \(noteName)"
        case .create: "New note \(notePath)"
        case .delete: "Delete \(notePath)"
        case .move: "Move \(notePath) to \(destination ?? "?")"
        }
    }
}

/// A set of proposals made together, with the change they belong to.
public struct ProposalGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String
    public let proposals: [Proposal]

    public init(id: String, summary: String, proposals: [Proposal]) {
        self.id = id
        self.summary = summary
        self.proposals = proposals
    }

    public var agent: String { proposals.first?.agent ?? "" }
    public var createdAt: Date { proposals.map(\.createdAt).min() ?? Date() }
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

    /// ISO8601 to the millisecond, and the reason the fraction is there.
    ///
    /// The plain `.iso8601` strategy writes whole seconds, and one agent run
    /// proposing five notes lands them all inside one. Every proposal in the
    /// run then had the same `createdAt`, the id tiebreak in `all` decided the
    /// order, and a group came back alphabetically: Short, Callout, Long,
    /// Index, Links, for a run proposed Index first. The order an agent worked
    /// in is information, and it was being thrown away by rounding.
    ///
    /// The tiebreak stays. It is what stops the list reshuffling between two
    /// reads, and two proposals can still share a millisecond.
    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp.string(from: date))
        }
        return encoder
    }

    /// Reads both spellings, because the vault already holds the old one.
    ///
    /// A proposal written before this change has no fraction, and a decoder
    /// that insisted on one would make every pending proposal in the vault
    /// undecodable — which is somebody's change silently vanishing from the
    /// list. Same lesson as `Proposal.init(from:)` and `PDFExportOptions`: a
    /// stored file is a format, and a format has to tolerate being older than
    /// the code reading it.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = timestamp.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "not an ISO8601 date: \(text)"
                ))
            }
            return date
        }
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
        let text = described ?? (plain.isEmpty ? noteName : plain)
        var base = slug(text)
        if base.isEmpty { base = "proposal" }
        guard taken.contains(base) else { return base }

        // A collision is the moment the name most needs to say which of the
        // two it is, and truncation had thrown exactly that away: five
        // summaries written in one batch share a long opening and differ at
        // the end, so `add-a-sample-note-for-checking` and its `-2` carried
        // none of what distinguished them.
        //
        // So give back the words the cut took, one at a time, and stop at the
        // first name that is free. Short ids stay short, and a name only grows
        // where growing is what makes it a name.
        let words = slug(text, limit: .max).split(separator: "-").map(String.init)
        for count in words.indices {
            let candidate = words.prefix(count + 1).joined(separator: "-")
            if candidate.count > base.count, !taken.contains(candidate) { return candidate }
        }

        // Two genuinely identical summaries have nothing left to tell apart.
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

    static func slug(_ text: String, limit: Int = slugLimit) -> String {
        var out = ""
        var word = ""
        /// False once a word will not fit, which ends the name. Skipping that
        /// word and taking the next one that happens to be short enough reads
        /// as a typo rather than a truncation.
        func flush() -> Bool {
            guard !word.isEmpty else { return true }
            let joined = out.isEmpty ? word : out + "-" + word
            word = ""
            if joined.count <= limit {
                out = joined
                return true
            }
            // One word longer than the whole limit has no boundary to cut on,
            // so it is cut anyway rather than leaving nothing.
            if out.isEmpty { out = String(joined.prefix(limit)) }
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

    /// - Parameter exactly: require the whole id rather than a prefix.
    ///
    ///   True for anything destructive. A prefix names a *different* set of
    ///   proposals at different times: `tighten-the-o` uniquely names one
    ///   today, and next week — that one gone, "tighten the outline" arrived —
    ///   the same command deletes something else without ever being
    ///   ambiguous. The ambiguity check only sees collisions that exist at the
    ///   moment it runs.
    ///
    ///   Prefixes existed because nobody can type a UUID. Now that an id is
    ///   the words of its summary, and `heft proposals` prints it ready to
    ///   copy, that reason is gone for the one verb that cannot be undone.
    ///   `diff` keeps them, because reading the wrong proposal costs nothing.
    public static func match(
        _ id: String?, among proposals: [Proposal], exactly: Bool = false
    ) -> Match {
        guard let id, !id.isEmpty else { return .missing }
        let hits = proposals
            .filter { exactly ? $0.id == id : $0.id.hasPrefix(id) }
            .map(\.id)
        guard let first = hits.first else { return .unknown(id) }
        return hits.count == 1 ? .one(first) : .ambiguous(hits)
    }

    public static func forNote(_ relativePath: String, in vaultRoot: URL) -> [Proposal] {
        all(in: vaultRoot).filter { $0.notePath == relativePath }
    }

    /// A proposal already waiting on this note, which a new one would collide
    /// with. Pure, so `propose` can refuse without a vault to ask.
    ///
    /// Two proposals on one note is not two changes, it is two answers to the
    /// same question, each written as though the other did not exist. Both are
    /// diffed against the note *as it is now*, so accepting one leaves the
    /// other proposing the note it was never rebased onto, and the hunks read
    /// as an agent trying to undo work you just accepted.
    ///
    /// `ignoring` is the id `--replacing` names: the one being taken the place
    /// of is not a collision with itself.
    public static func conflict(
        forNote relativePath: String, among proposals: [Proposal], ignoring: String? = nil
    ) -> Proposal? {
        proposals.first { $0.notePath == relativePath && $0.id != ignoring }
    }

    /// What is waiting, sorted into the three things a review list shows:
    /// groups, single edits to one note, and structural changes.
    ///
    /// A group of one is not a group. An agent that names a change while
    /// touching a single note has described that one proposal, and listing it
    /// under a heading of its own would be a fold with nothing inside it.
    public struct Pending: Sendable, Equatable {
        public var groups: [ProposalGroup] = []
        public var edits: [Proposal] = []
        public var structural: [Proposal] = []

        public init() {}

        public var isEmpty: Bool {
            groups.isEmpty && edits.isEmpty && structural.isEmpty
        }

        public var count: Int {
            groups.reduce(0) { $0 + $1.proposals.count } + edits.count + structural.count
        }
    }

    public static func pending(in vaultRoot: URL) -> Pending {
        sort(all(in: vaultRoot))
    }

    /// Pure, so the sorting can be asked for without a vault.
    public static func sort(_ proposals: [Proposal]) -> Pending {
        var result = Pending()
        var grouped: [String: [Proposal]] = [:]
        var order: [String] = []

        for proposal in proposals {
            guard let group = proposal.group else { continue }
            if grouped[group.id] == nil { order.append(group.id) }
            grouped[group.id, default: []].append(proposal)
        }

        let realGroups = Set(order.filter { (grouped[$0]?.count ?? 0) > 1 })
        for id in order where realGroups.contains(id) {
            let members = grouped[id] ?? []
            result.groups.append(ProposalGroup(
                id: id,
                summary: members.first?.group?.summary ?? id,
                proposals: members
            ))
        }

        for proposal in proposals {
            if let group = proposal.group, realGroups.contains(group.id) { continue }
            if proposal.isStructural { result.structural.append(proposal) }
            else { result.edits.append(proposal) }
        }
        return result
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
