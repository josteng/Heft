import Foundation

/// A conversation with the reader's agent, kept so it can be read again and
/// continued.
///
/// Stored in the vault, in `.heft/chats/`, beside the pins and the
/// proposals: a chat is about these notes and goes where they go. Continuing
/// one needs the agent's own session, which lives on the Mac that ran it; on
/// another Mac a reply starts a fresh session and is handed the transcript
/// instead.
public struct AgentChat: Codable, Equatable, Identifiable, Sendable {

    public struct Turn: Codable, Equatable, Sendable {
        /// What the reader asked, as the chat shows it.
        public var question: String
        /// What the agent is sent instead, when that is longer than what the
        /// reader should see: the full instructions behind "Draft a note".
        public var instruction: String?
        public var answer: String
        /// The proposals this turn left, by id, with enough to show them
        /// after they have been accepted or rejected and are gone.
        public var proposals: [ProposalNote]
        public var denials: [AgentDenial]
        /// Why the run failed, when it did.
        public var failure: String?
        public var askedAt: Date

        public init(
            question: String, instruction: String? = nil, answer: String = "",
            proposals: [ProposalNote] = [], denials: [AgentDenial] = [],
            failure: String? = nil, askedAt: Date = Date()
        ) {
            self.question = question
            self.instruction = instruction
            self.answer = answer
            self.proposals = proposals
            self.denials = denials
            self.failure = failure
            self.askedAt = askedAt
        }

        /// Tolerant, as `Proposal` is: a stored chat is a format, and one
        /// written before a field existed must still open.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            question = try container.decode(String.self, forKey: .question)
            instruction = try container.decodeIfPresent(String.self, forKey: .instruction)
            answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
            proposals = try container.decodeIfPresent([ProposalNote].self, forKey: .proposals) ?? []
            denials = try container.decodeIfPresent([AgentDenial].self, forKey: .denials) ?? []
            failure = try container.decodeIfPresent(String.self, forKey: .failure)
            askedAt = try container.decodeIfPresent(Date.self, forKey: .askedAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    /// A proposal as the chat remembers it.
    public struct ProposalNote: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var notePath: String
        public var headline: String
        /// What became of it, when it was decided from the chat.
        public var outcome: Outcome?

        public enum Outcome: String, Codable, Sendable {
            case accepted, rejected
        }

        public init(id: String, notePath: String, headline: String, outcome: Outcome? = nil) {
            self.id = id
            self.notePath = notePath
            self.headline = headline
            self.outcome = outcome
        }
    }

    public var id: String
    /// The first question, as the chat's name in the list.
    public var title: String
    /// Vault-relative folder it was asked in; empty for the whole vault.
    public var scope: String
    public var session: String?
    /// Which Mac's agent holds `session`.
    public var host: String?
    public var turns: [Turn]
    /// Folders the reader allowed it to read after a refusal, kept for every
    /// later run of this chat, since each run is a new process.
    public var allowed: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString, question: String, instruction: String? = nil,
        scope: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.title = Self.title(for: question)
        self.scope = scope
        self.session = nil
        self.host = nil
        self.turns = [Turn(question: question, instruction: instruction, askedAt: createdAt)]
        self.allowed = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        turns = try container.decode([Turn].self, forKey: .turns)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? Self.title(for: turns.first?.question ?? "")
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        session = try container.decodeIfPresent(String.self, forKey: .session)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        allowed = try container.decodeIfPresent([String].self, forKey: .allowed) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static func title(for question: String) -> String {
        let line = question.split(separator: "\n").first.map(String.init) ?? question
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    /// What a fresh session is told when the one that held this chat is on
    /// another Mac or gone: the conversation so far, then the new question.
    public func prompt(continuing question: String) -> String {
        let earlier = turns.dropLast().map { turn in
            "Reader: \(turn.instruction ?? turn.question)\n\nYou: \(turn.answer)"
        }
        guard !earlier.isEmpty else { return question }
        return "This continues an earlier conversation about these notes.\n\n"
            + earlier.joined(separator: "\n\n") + "\n\nReader: \(question)"
    }

    /// Whether the text matches a search of the chat list.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q)
            || turns.contains { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
    }
}

public enum AgentChatStore {
    public static func directory(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".heft", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }

    /// Every chat, the latest first. One that cannot be read is skipped,
    /// not fatal.
    public static func all(in vaultRoot: URL) -> [AgentChat] {
        let folder = directory(in: vaultRoot)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(AgentChat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Written whole and atomically, as the pins are.
    public static func save(_ chat: AgentChat, in vaultRoot: URL) throws {
        let folder = directory(in: vaultRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(chat).write(to: file(chat.id, in: vaultRoot), options: .atomic)
    }

    public static func delete(_ id: String, in vaultRoot: URL) {
        try? FileManager.default.removeItem(at: file(id, in: vaultRoot))
    }

    private static func file(_ id: String, in vaultRoot: URL) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory(in: vaultRoot).appendingPathComponent("\(safe).json")
    }
}
