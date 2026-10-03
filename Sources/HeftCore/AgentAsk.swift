import Foundation

/// One question to the reader's own coding agent, run headless.
///
/// Heft never talks to a model itself. It starts the command the reader
/// already has installed and signed in to, `claude` by default, and reads
/// what it prints. That keeps the reader's login inside that tool, where its
/// terms want it, and lets Heft decide the one thing that matters here: what
/// the agent is allowed to touch.
///
/// Contained by the flags alone, so nothing in the vault can widen them:
/// - Only Read, Grep, Glob and Bash exist. No Edit or Write, so the agent
///   cannot change a file however it is asked.
/// - Bash runs the read-only commands Claude Code already trusts, plus the
///   `heft` verbs that read or propose. The verbs that write without review
///   (`rename --now`, `capture`, `daily`, `export`) are not among them.
/// - Nothing reads outside the scope: not Claude's own tools, not the shell
///   commands it trusts as read-only (`cat` would otherwise read anywhere on
///   the disk), and not `heft`, which is told the scope and keeps to it.
/// - Anything that would ask is refused, and reported back as a denial.
/// - No settings, hooks or MCP servers load from the reader's setup or the
///   vault: an allow rule there could otherwise reopen what this closes.
///   The vault's own instructions are handed over as text instead.
/// - It starts in the scope, the focused folder when there is one, and
///   reads nothing outside it without the reader allowing that folder.
public struct AgentInvocation: Equatable, Sendable {
    public var executable: URL
    public var model: String
    /// Where the agent starts and may read: the focused folder or the vault.
    public var workingDirectory: URL
    public var vaultRoot: URL
    /// A folder holding a `heft` that runs this app, put first on the PATH.
    public var heftDirectory: URL?
    public var prompt: String
    /// The agent's session to continue, for a reply.
    public var resume: String?
    /// Folders outside the scope the reader allowed it to read, from
    /// earlier denials.
    public var allowed: [String]
    /// The vault's CLAUDE.md and AGENTS.md, which the run cannot load itself.
    public var vaultInstructions: String

    public init(
        executable: URL, model: String, workingDirectory: URL, vaultRoot: URL,
        heftDirectory: URL?, prompt: String, resume: String? = nil,
        allowed: [String] = [], vaultInstructions: String = "", heftAliases: [String] = []
    ) {
        self.heftAliases = heftAliases
        self.executable = executable
        self.model = model
        self.workingDirectory = workingDirectory
        self.vaultRoot = vaultRoot
        self.heftDirectory = heftDirectory
        self.prompt = prompt
        self.resume = resume
        self.allowed = allowed
        self.vaultInstructions = vaultInstructions
    }

    /// The `heft` verbs an agent may run: everything that reads, and
    /// `propose`, `drop` and `capture`, which here only ever leave a change
    /// for review.
    public static let heftVerbs = [
        "help", "read", "find", "files", "tags", "backlinks", "links", "outline",
        "spell", "attachment", "config", "changes", "proposals", "diff", "propose", "drop",
        "capture",
    ]

    /// The verbs that keep to a folder when `heft` is told one. The others
    /// answer about the whole vault, so a run limited to a folder goes
    /// without them; its own Glob and Grep cover the folder.
    public static let scopedHeftVerbs = [
        "help", "read", "find", "config", "changes", "proposals", "diff", "propose", "drop", "capture",
    ]

    /// Other names the agent may call this app's `heft` by: a vault's guide
    /// names it by full path. Only paths that are this very binary, so an
    /// older `heft` that knows nothing of the scope is never one of them.
    public var heftAliases: [String]

    /// The scope as `heft` is told it: vault-relative, nil for the vault.
    public var scope: String? {
        let root = vaultRoot.standardizedFileURL.path
        let here = workingDirectory.standardizedFileURL.path
        guard here != root, here.hasPrefix(root + "/") else { return nil }
        return String(here.dropFirst(root.count + 1))
    }

    /// Claude Code's own rule against reading outside the working folders,
    /// which otherwise lets its read-only shell commands read anywhere.
    static let blockOutsideReads = #"{"permissions":{"blockReadsOutsideWorkingDirectories":true}}"#

    public var arguments: [String] {
        var arguments = [
            "-p", prompt,
            "--model", model,
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "Read,Grep,Glob,Bash",
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            "--setting-sources", "",
            "--settings", Self.blockOutsideReads,
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--append-system-prompt", systemPrompt,
        ]
        let verbs = scope == nil ? Self.heftVerbs : Self.scopedHeftVerbs
        let names = ["heft"] + heftAliases.filter { !$0.contains(" ") }
        arguments += ["--allowedTools"] + names.flatMap { name in verbs.map { "Bash(\(name) \($0) *)" } }
        for folder in allowed { arguments += ["--add-dir", folder] }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The process environment: the reader's, with this app's `heft` first.
    public func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["HEFT_AGENT_SCOPE"] = scope
        environment["HEFT_AGENT_ASK"] = "1"
        let path = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = [heftDirectory?.path, executable.deletingLastPathComponent().path].compactMap { $0 }
        environment["PATH"] = (extra + [path, "/opt/homebrew/bin", "/usr/local/bin"]).joined(separator: ":")
        return environment
    }

    var scopeDescription: String {
        scope.map { "the folder \($0) of the vault" } ?? "the whole vault"
    }

    var systemPrompt: String {
        var prompt = """
        You are answering inside Heft, a Markdown notes app, from its search bar. The reader \
        asked about their notes, in \(scopeDescription). The vault is at "\(vaultRoot.path)".

        Answer briefly and plainly. Name a note as a wikilink, [[Note Name]], so the reader can \
        open it. Read files with the Read tool; anything outside \(scopeDescription) is off \
        limits. If you need a file there, try to read it with the Read tool anyway: Heft shows \
        the reader what was refused with a button to allow it. Then say in one line what you \
        wanted and why. Never suggest slash commands or settings: the reader is in Heft, not \
        in Claude Code.

        You cannot write files and must not try. To change, create, move or delete a note, \
        propose it, and the reader reviews it in Heft:
        - heft read "\(vaultRoot.path)" "<path>"   reads a note (do this before replacing it)
        - heft propose "\(vaultRoot.path)" "<path>" <<'EOF'
          <the whole new body>
          EOF
        - heft propose "\(vaultRoot.path)" "<path>" --replace --summary "<one line>" <<'EOF'
          --- old
          exact text now in the note
          --- new
          its replacement
          EOF
          changes part of a note without restating it; repeat the two blocks for more \
        edits. Use this plain form, never JSON: JSON here is refused.
        - heft propose "\(vaultRoot.path)" "<path>" --delete    or    --move "<to>"
        - heft find "\(vaultRoot.path)" "<words>"   searches the text of every note
        - heft capture "\(vaultRoot.path)" "<one line>" --daily   adds a line to today's note \
        (or --to "<path>"); here it becomes a proposal too
        Paths are relative to the vault. A new note is a propose to a path that does not exist \
        yet. Call it as plain `heft`: it is on your PATH and is this app. You cannot write any \
        file here, not even in /tmp, so a command writing one is refused: always give `heft` \
        its input with a heredoc on the same command, as above, whatever the vault's own \
        instructions say about files in /tmp, --from or `<`. Say in one line what you \
        proposed and stop; do not wait for the review.
        """
        let instructions = vaultInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            prompt += "\n\nThe vault's own instructions for agents follow.\n\n" + instructions
        }
        return prompt
    }

    /// The file without the section `heft agent-setup` writes. That guide
    /// is for an agent run in a terminal, which may write to /tmp and read
    /// from it; here no file can be written, and an agent given both
    /// followed the guide and was refused. The reader's own text stays.
    static func withoutHeftGuide(_ text: String) -> String {
        guard let start = text.range(of: AgentGuide.markerStart),
              let end = text.range(of: AgentGuide.markerEnd, range: start.upperBound..<text.endIndex)
        else { return text }
        return String(text[..<start.lowerBound]) + String(text[end.upperBound...])
    }

    /// What the vault tells agents, from the files a session in it would
    /// load: CLAUDE.md and AGENTS.md at its top, and in the folders down to
    /// the scope.
    public static func vaultInstructions(vaultRoot: URL, workingDirectory: URL) -> String {
        let root = vaultRoot.standardizedFileURL
        var folders = [root]
        let rootPath = root.path
        let here = workingDirectory.standardizedFileURL.path
        if here.hasPrefix(rootPath + "/") {
            var folder = root
            for part in here.dropFirst(rootPath.count + 1).split(separator: "/") {
                folder.appendPathComponent(String(part), isDirectory: true)
                folders.append(folder)
            }
        }
        var parts: [String] = []
        for folder in folders {
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let file = folder.appendingPathComponent(name)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    let own = withoutHeftGuide(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !own.isEmpty { parts.append(own) }
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Something the agent was refused, and whether the reader may allow it.
public struct AgentDenial: Codable, Equatable, Sendable, Hashable {
    public var tool: String
    /// What it was refused, in the reader's words: a path or a command.
    public var target: String
    /// The folder that would allow it on a retry, added as one the agent
    /// may read. Only reads ever get one: letting a refused command through
    /// could run anything, and an edit is a proposal or nothing.
    public var allowFolder: String?

    public init(tool: String, target: String, allowFolder: String?) {
        self.tool = tool
        self.target = target
        self.allowFolder = allowFolder
    }

    public var summary: String {
        switch tool {
        case "Read": "Read \(target)"
        case "Grep", "Glob": "Search in \(target)"
        case "Bash": "Run \(target)"
        default: "\(tool) \(target)"
        }
    }

    init(tool: String, input: [String: Any]) {
        self.tool = tool
        switch tool {
        case "Read":
            let path = input["file_path"] as? String ?? ""
            target = path
            allowFolder = path.hasPrefix("/") ? (path as NSString).deletingLastPathComponent : nil
        case "Grep", "Glob":
            let path = input["path"] as? String ?? ""
            target = path
            allowFolder = path.hasPrefix("/") ? path : nil
        case "Bash":
            target = input["command"] as? String ?? ""
            allowFolder = nil
        default:
            target = input.values.compactMap { $0 as? String }.first ?? ""
            allowFolder = nil
        }
    }
}

/// What a run reports, line by line.
public enum AgentEvent: Equatable, Sendable {
    case started(session: String)
    /// More of the answer.
    case text(String)
    /// What the agent is doing now, in a few words.
    case activity(String)
    case finished(AgentOutcome)
}

public struct AgentOutcome: Equatable, Sendable {
    public var isError: Bool
    /// The agent's own message when it failed.
    public var message: String
    public var denials: [AgentDenial]
    public var cost: Double?

    public init(isError: Bool, message: String, denials: [AgentDenial], cost: Double?) {
        self.isError = isError
        self.message = message
        self.denials = denials
        self.cost = cost
    }
}

/// Reads `--output-format stream-json` one line at a time.
///
/// The answer comes from the text deltas, so it appears as it is written;
/// tool calls come from the whole messages, which carry their input. The
/// thinking blocks and everything else are skipped.
public struct AgentStreamParser: Sendable {
    private var wroteText = false
    private var needsBreak = false

    public init() {}

    public mutating func parse(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String
            else { return [] }
            return [.started(session: session)]
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "message_start":
                // A new turn's text is a new paragraph.
                if wroteText { needsBreak = true }
                return []
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty
                else { return [] }
                let lead = needsBreak ? "\n\n" : ""
                needsBreak = false
                wroteText = true
                return [.text(lead + text)]
            default:
                return []
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String
                else { return nil }
                return .activity(Self.activity(tool: name, input: block["input"] as? [String: Any] ?? [:]))
            }
        case "result":
            let denials = (object["permission_denials"] as? [[String: Any]] ?? []).map {
                AgentDenial(tool: $0["tool_name"] as? String ?? "", input: $0["tool_input"] as? [String: Any] ?? [:])
            }
            var unique: [AgentDenial] = []
            for denial in denials where !unique.contains(denial) { unique.append(denial) }
            return [.finished(AgentOutcome(
                isError: object["is_error"] as? Bool ?? false,
                message: object["result"] as? String ?? "",
                denials: unique,
                cost: object["total_cost_usd"] as? Double
            ))]
        default:
            return []
        }
    }

    /// A tool call as the reader would say it: "Reading Plan.md".
    static func activity(tool: String, input: [String: Any]) -> String {
        func name(_ path: String) -> String {
            let last = (path as NSString).lastPathComponent
            return last.hasSuffix(".md") ? String(last.dropLast(3)) : last
        }
        switch tool {
        case "Read": return "Reading \(name(input["file_path"] as? String ?? "a note"))"
        case "Grep": return "Searching for “\(input["pattern"] as? String ?? "")”"
        case "Glob": return "Looking for files"
        case "Bash":
            let firstLine = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let words = shellWords(firstLine)
            guard words.first == "heft", words.count > 1 else { return "Running a command" }
            let note = words.count > 3 ? name(words[3]) : ""
            switch words[1] {
            case "read": return note.isEmpty ? "Reading a note" : "Reading \(note)"
            case "find": return "Searching the notes"
            case "propose": return note.isEmpty ? "Proposing a change" : "Proposing a change to \(note)"
            default: return "Asking Heft"
            }
        default: return "Working"
        }
    }

    /// A command line split as a shell would, quotes kept together.
    static func shellWords(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var inWord = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(word); word = ""; inWord = false }
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}

/// Where the reader's `claude` is. An app opened from the Dock does not get
/// the shell's PATH, so the usual places are looked in first, then the login
/// shell is asked.
public enum AgentLocator {
    public static func find(command: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let url = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }
        let places = [
            home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".claude/local"),
            home.appendingPathComponent(".npm-global/bin"), home.appendingPathComponent(".bun/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
        ]
        for place in places {
            let candidate = place.appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return fromLoginShell(command)
    }

    private static func fromLoginShell(_ command: String) -> URL? {
        guard command.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, found.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: found)
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each once.
    public func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Files and folders the reader names in a question, by path.
///
/// Naming one is the reader's consent to reading it, so it is let through
/// without a refusal first: a file as a copy in a folder of the chat's own,
/// so naming one PDF in Downloads does not open all of Downloads; a folder
/// as it is, since a folder is what was named.
public enum AgentFiles {

    /// The paths in `text` that exist: absolute, from `~`, or `file://`
    /// URLs. A path may hold spaces, as a dropped one often does, so each
    /// is taken as the longest run that names something on disk.
    public static func paths(in text: String, home: String = NSHomeDirectory()) -> [URL] {
        let characters = Array(text)
        var found: [URL] = []
        var index = 0
        while index < characters.count {
            let startsHere = index == 0 || " \t\n\"'(<[".contains(characters[index - 1])
            guard startsHere, let start = pathStart(characters, at: index) else {
                index += 1
                continue
            }
            var best: (url: URL, end: Int)?
            var end = start.body
            while end <= characters.count {
                if end == characters.count || " \t\n\"')>]".contains(characters[end]) {
                    let raw = String(characters[start.body..<end])
                    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                    if let url = resolve(trimmed, kind: start.kind, home: home),
                       FileManager.default.fileExists(atPath: url.path) {
                        best = (url, end)
                    }
                }
                end += 1
            }
            if let best {
                if !found.contains(best.url) { found.append(best.url) }
                index = best.end
            } else {
                index += 1
            }
        }
        return found
    }

    private enum Kind { case absolute, home, fileURL }

    private static func pathStart(_ characters: [Character], at index: Int) -> (body: Int, kind: Kind)? {
        let rest = String(characters[index..<min(characters.count, index + 7)])
        if rest.hasPrefix("file://") { return (index, .fileURL) }
        if characters[index] == "/" { return (index, .absolute) }
        if characters[index] == "~", index + 1 < characters.count, characters[index + 1] == "/" {
            return (index, .home)
        }
        return nil
    }

    private static func resolve(_ text: String, kind: Kind, home: String) -> URL? {
        switch kind {
        case .absolute: return text.count > 1 ? URL(fileURLWithPath: text) : nil
        case .home: return URL(fileURLWithPath: home + text.dropFirst())
        case .fileURL: return URL(string: text).flatMap { $0.isFileURL ? $0 : nil }
        }
    }

    /// Copies each file into a numbered folder of its own under `folder`,
    /// so two files with one name both arrive. Returns where each went.
    public static func stage(_ files: [URL], into folder: URL) -> [(original: URL, copy: URL)] {
        let fileManager = FileManager.default
        var staged: [(URL, URL)] = []
        for file in files {
            let slot = folder.appendingPathComponent("\(staged.count + 1)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            let copy = slot.appendingPathComponent(file.lastPathComponent)
            do {
                try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
                try fileManager.copyItem(at: file, to: copy)
                staged.append((file, copy))
            } catch {
                continue
            }
        }
        return staged
    }
}

/// Whether typed text reads as a question or a request rather than words to
/// find, by the signs a search box goes by: a question mark, a question or
/// request word first, or the length of a sentence. No model is asked: the
/// answer has to be instant, the same every time, and wrong only visibly.
public enum QuestionShape {
    /// First words that make a question or an ask, English and German.
    static let openers: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "whose", "whom",
        "can", "could", "should", "would", "will", "is", "are", "was", "were",
        "do", "does", "did", "has", "have", "explain", "summarize", "summarise",
        "tell", "list", "compare", "write", "draft", "help", "give", "make", "create",
        "add", "change", "rewrite", "translate", "suggest",
        "wie", "warum", "wieso", "weshalb", "wann", "wo", "wer", "welche", "welcher",
        "welches", "kannst", "könntest", "gibt", "fasse", "erkläre", "schreib", "schreibe",
    ]

    public static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        // Three words are as likely a note's name, "What I learned", as a
        // question; four with a question word first rarely are.
        guard words.count >= 4 else { return false }
        let first = words[0].lowercased().trimmingCharacters(in: .punctuationCharacters)
        return openers.contains(first) || words.count >= 7
    }
}
