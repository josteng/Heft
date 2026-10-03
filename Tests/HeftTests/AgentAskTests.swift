import Foundation
import HeftCore
import Testing

/// How Heft runs the reader's agent: what it may touch, and what it reports.
@Suite("Agent invocation")
struct AgentInvocationTests {

    private func invocation(scope: String = "/vault/Work", allowed: [String] = []) -> AgentInvocation {
        // Folders, as the reader allowed them; nothing allowed by default.
        AgentInvocation(
            executable: URL(fileURLWithPath: "/tools/bin/claude"), model: "haiku",
            workingDirectory: URL(fileURLWithPath: scope, isDirectory: true),
            vaultRoot: URL(fileURLWithPath: "/vault", isDirectory: true),
            heftDirectory: URL(fileURLWithPath: "/support/agent-bin"),
            prompt: "What is due Friday?", allowed: allowed,
            vaultInstructions: "Answer in German."
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    /// Containment rests on these flags and nothing else, so each one is
    /// pinned: a tool list without Edit or Write, nothing that asks, and
    /// none of the reader's or the vault's settings, hooks or servers.
    @Test("Only reading tools exist, nothing asks, and no settings load")
    func contained() {
        let arguments = invocation().arguments
        #expect(value(after: "--tools", in: arguments) == "Read,Grep,Glob,Bash")
        #expect(value(after: "--permission-mode", in: arguments) == "dontAsk")
        #expect(value(after: "--permission-prompts", in: arguments) == "none")
        #expect(value(after: "--setting-sources", in: arguments) == "")
        #expect(value(after: "--settings", in: arguments)?.contains(#""blockReadsOutsideWorkingDirectories":true"#) == true)
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(value(after: "--mcp-config", in: arguments) == #"{"mcpServers":{}}"#)
        #expect(value(after: "--model", in: arguments) == "haiku")
        #expect(value(after: "-p", in: arguments) == "What is due Friday?")
        #expect(!arguments.contains("--resume"))
    }

    @Test("The heft verbs that write without review are not allowed")
    func heftVerbs() {
        let whole = invocation(scope: "/vault").arguments.filter { $0.hasPrefix("Bash(") }
        #expect(whole.contains("Bash(heft propose *)"))
        #expect(whole.contains("Bash(heft read *)"))
        #expect(whole.contains("Bash(heft backlinks *)"))
        for verb in ["rename", "daily", "export", "agent-setup"] {
            #expect(!whole.contains { $0.hasPrefix("Bash(heft \(verb)") }, "\(verb)")
        }
        // Capture is let through because Heft tells it to propose instead.
        #expect(whole.contains("Bash(heft capture *)"))
        #expect(invocation().environment(base: [:])[AgentCLI.askVariable] == "1")
        #expect(!invocation().arguments.contains { $0.contains("Edit") || $0.contains("Write") })
        // Limited to a folder, only the verbs that keep to one.
        let scoped = invocation().arguments.filter { $0.hasPrefix("Bash(") }
        #expect(scoped.contains("Bash(heft read *)") && scoped.contains("Bash(heft propose *)"))
        #expect(!scoped.contains("Bash(heft backlinks *)") && !scoped.contains("Bash(heft files *)"))
    }

    /// A vault's guide names `heft` by its full path, and the agent follows
    /// it; that has to be allowed too, or every proposal is refused.
    @Test("heft is allowed by its full paths as well, unless a path has a space")
    func aliases() {
        var asked = invocation(scope: "/vault")
        asked.heftAliases = ["/Applications/Heft.app/Contents/MacOS/Heft", "/Volumes/My Apps/Heft"]
        let rules = asked.arguments.filter { $0.hasPrefix("Bash(") }
        #expect(rules.contains("Bash(/Applications/Heft.app/Contents/MacOS/Heft propose *)"))
        #expect(rules.contains("Bash(heft propose *)"))
        #expect(rules.contains("Bash(heft capture *)") && rules.contains("Bash(heft config *)"))
        #expect(!rules.contains { $0.contains("My Apps") })
    }

    @Test("A reply resumes the session, and an allowed read joins the rules")
    func resumeAndAllow() {
        var asked = invocation(allowed: ["/vault/Home"])
        asked.resume = "session-1"
        let arguments = asked.arguments
        #expect(value(after: "--resume", in: arguments) == "session-1")
        #expect(value(after: "--add-dir", in: arguments) == "/vault/Home")
    }

    @Test("The agent learns its scope, the vault, and the vault's own instructions")
    func systemPrompt() {
        let prompt = value(after: "--append-system-prompt", in: invocation().arguments) ?? ""
        #expect(prompt.contains("the folder Work of the vault"))
        #expect(prompt.contains("\"/vault\""))
        #expect(prompt.contains("Answer in German."))
        #expect(prompt.contains("heft propose"))
        let whole = value(after: "--append-system-prompt", in: invocation(scope: "/vault").arguments) ?? ""
        #expect(whole.contains("the whole vault"))
    }

    @Test("This app's heft comes first on the PATH, and is told the scope")
    func path() {
        let environment = invocation().environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/home/reader"])
        #expect(environment["PATH"]?.hasPrefix("/support/agent-bin:/tools/bin:/usr/bin:/bin") == true)
        #expect(environment["HOME"] == "/home/reader")
        #expect(environment[AgentCLI.scopeVariable] == "Work")
        let whole = invocation(scope: "/vault").environment(base: [AgentCLI.scopeVariable: "Stale"])
        #expect(whole[AgentCLI.scopeVariable] == nil, "the whole vault, whatever was inherited")
    }

    @Test("The vault's instructions come from its top and every folder down to the scope")
    func vaultInstructions() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("Work/Thesis", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "top claude".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "top agents".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "thesis rules".write(to: work.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "elsewhere".write(
            to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8
        )
        let found = AgentInvocation.vaultInstructions(vaultRoot: root, workingDirectory: work)
        #expect(found == "top claude\n\ntop agents\n\nthesis rules")
        let atTop = AgentInvocation.vaultInstructions(vaultRoot: root, workingDirectory: root)
        #expect(atTop == "top claude\n\ntop agents")

        // Heft's own guide is left out, the reader's words around it kept.
        try """
        My conventions.
        \(AgentGuide.markerStart)
        Write the body to /tmp/new.md first.
        \(AgentGuide.markerEnd)
        After the guide.
        """.write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let guided = AgentInvocation.vaultInstructions(vaultRoot: root, workingDirectory: root)
        #expect(guided.contains("My conventions.") && guided.contains("After the guide."))
        #expect(!guided.contains("/tmp/new.md"))
    }
}

@Suite("Agent stream")
struct AgentStreamTests {

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func delta(_ text: String) -> String {
        json(["type": "stream_event", "event": [
            "type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": text],
        ]])
    }

    private var messageStart: String {
        json(["type": "stream_event", "event": ["type": "message_start", "message": [:]]])
    }

    private func toolUse(_ name: String, _ input: [String: Any]) -> String {
        json(["type": "assistant", "message": ["content": [
            ["type": "thinking", "thinking": "hidden"],
            ["type": "tool_use", "name": name, "input": input],
        ]]])
    }

    @Test("The answer streams from text deltas; a new turn starts a paragraph")
    func answer() {
        var parser = AgentStreamParser()
        var events: [AgentEvent] = []
        for line in [
            json(["type": "system", "subtype": "init", "session_id": "s-1"]),
            messageStart, delta("Looking"), delta(" now."),
            toolUse("Read", ["file_path": "/vault/Work/Plan.md"]),
            messageStart, delta("Friday."),
            json(["type": "stream_event", "event": [
                "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "x"],
            ]]),
            "not json",
        ] {
            events += parser.parse(line)
        }
        #expect(events == [
            .started(session: "s-1"), .text("Looking"), .text(" now."),
            .activity("Reading Plan"), .text("\n\nFriday."),
        ])
    }

    @Test("The result reports failure, cost, and each refusal once")
    func result() {
        var parser = AgentStreamParser()
        let denied: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": "/vault/Home/Secret.md"]]
        let events = parser.parse(json([
            "type": "result", "is_error": false, "result": "Done.", "total_cost_usd": 0.01,
            "permission_denials": [
                denied, denied,
                ["tool_name": "Bash", "tool_input": ["command": "rm Ideas.md"]],
            ],
        ]))
        guard case .finished(let outcome) = events.first else {
            Issue.record("no outcome: \(events)")
            return
        }
        #expect(!outcome.isError && outcome.message == "Done." && outcome.cost == 0.01)
        #expect(outcome.denials == [
            AgentDenial(tool: "Read", target: "/vault/Home/Secret.md", allowFolder: "/vault/Home"),
            AgentDenial(tool: "Bash", target: "rm Ideas.md", allowFolder: nil),
        ])
    }

    /// Only a read can be allowed after the fact. A refused command could be
    /// anything, `rm` included, and an edit is a proposal or nothing.
    @Test("Only reads can be allowed after a refusal")
    func allowRules() {
        var parser = AgentStreamParser()
        let events = parser.parse(json([
            "type": "result", "is_error": false, "result": "",
            "permission_denials": [
                ["tool_name": "Grep", "tool_input": ["pattern": "x", "path": "/vault/Home"]],
                ["tool_name": "Read", "tool_input": ["file_path": "Home/Relative.md"]],
                ["tool_name": "Edit", "tool_input": ["file_path": "/vault/Work/Plan.md"]],
            ],
        ]))
        guard case .finished(let outcome) = events.first else { return }
        #expect(outcome.denials.map(\.allowFolder) == ["/vault/Home", nil, nil])
        #expect(outcome.denials[0].summary == "Search in /vault/Home")
    }

    @Test("A tool call reads as what it is doing")
    func activities() {
        func activity(_ command: String) -> AgentEvent? {
            var parser = AgentStreamParser()
            return parser.parse(toolUse("Bash", ["command": command])).first
        }
        #expect(activity(#"heft propose "/vault" "Work/Weekly Plan.md" <<'EOF'"# + "\nbody\nEOF")
            == .activity("Proposing a change to Weekly Plan"))
        #expect(activity(#"heft read "/vault" Work/Plan.md"#) == .activity("Reading Plan"))
        #expect(activity(#"heft find "/vault" "due""#) == .activity("Searching the notes"))
        #expect(activity("ls -la") == .activity("Running a command"))
        var parser = AgentStreamParser()
        #expect(parser.parse(toolUse("Grep", ["pattern": "due"])) == [.activity("Searching for “due”")])
    }
}

@Suite("Agent chats")
struct AgentChatTests {

    @Test("A chat is stored in the vault, read back, and listed latest first")
    func storage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-chats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var older = AgentChat(question: "What is due?", scope: "Work", createdAt: Date(timeIntervalSince1970: 100))
        older.turns[0].answer = "The parser."
        older.turns[0].proposals = [.init(id: "plan", notePath: "Work/Plan.md", headline: "Proposed edit")]
        let newer = AgentChat(question: "Summarise Ideas", scope: "", createdAt: Date(timeIntervalSince1970: 200))
        try AgentChatStore.save(older, in: root)
        try AgentChatStore.save(newer, in: root)
        try "{ broken".write(
            to: AgentChatStore.directory(in: root).appendingPathComponent("bad.json"),
            atomically: true, encoding: .utf8
        )
        let read = AgentChatStore.all(in: root)
        #expect(read.map(\.id) == [newer.id, older.id])
        #expect(read.last == older)
        AgentChatStore.delete(newer.id, in: root)
        #expect(AgentChatStore.all(in: root).map(\.id) == [older.id])
    }

    @Test("A fresh session is handed the conversation so far")
    func continuing() {
        var chat = AgentChat(question: "What is due?", scope: "")
        chat.turns[0].answer = "The parser, Friday."
        #expect(chat.prompt(continuing: "What is due?") == "What is due?", "a first question goes as it is")
        chat.turns.append(.init(question: "And after?"))
        let prompt = chat.prompt(continuing: "And after?")
        #expect(prompt.contains("Reader: What is due?\n\nYou: The parser, Friday."))
        #expect(prompt.hasSuffix("Reader: And after?"))
    }

    @Test("The title is the first line, cut; search reads questions and answers")
    func titleAndSearch() {
        var chat = AgentChat(question: String(repeating: "a", count: 100) + "\nsecond line", scope: "")
        #expect(chat.title.count == 80 && chat.title.hasSuffix("…"))
        chat.turns[0].answer = "Mentions the Parser."
        #expect(chat.matches("parser") && chat.matches("") && !chat.matches("sidebar"))
    }
}

@Suite("Named files")
struct AgentFilesTests {

    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-named-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Some Folder"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("Some Folder/the draft.pdf"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// A dropped path keeps its spaces, so the longest run that exists wins.
    @Test("Paths are found with spaces, from ~, as file URLs, and without trailing punctuation")
    func found() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = root.appendingPathComponent("Some Folder/the draft.pdf")
        let notes = root.appendingPathComponent("notes.md")

        #expect(AgentFiles.paths(in: "Summarise \(draft.path) for me") == [draft])
        #expect(AgentFiles.paths(in: "Compare \(draft.path) and \(notes.path).") == [draft, notes])
        #expect(AgentFiles.paths(in: "Look at \(draft.absoluteString)").map(\.path) == [draft.path])
        let home = root.path
        #expect(AgentFiles.paths(in: "Read ~/notes.md please", home: home).map(\.path) == [notes.path])
        #expect(AgentFiles.paths(in: "Look in \"\(root.appendingPathComponent("Some Folder").path)\"").count == 1, "a folder too")
    }

    @Test("Text that only looks like a path is not one")
    func notFound() {
        #expect(AgentFiles.paths(in: "Is 1/2 of the plan done?").isEmpty)
        #expect(AgentFiles.paths(in: "the and/or question, and /nowhere/at/all.md").isEmpty)
        #expect(AgentFiles.paths(in: "a lone / slash").isEmpty)
    }

    @Test("Each file is copied into its own folder, so equal names both arrive")
    func staged() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "z".write(to: other.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let into = root.appendingPathComponent("Lent", isDirectory: true)
        let copies = AgentFiles.stage([root.appendingPathComponent("notes.md"), other.appendingPathComponent("notes.md")], into: into)
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.copy.path)).count == 2)
        #expect(copies.allSatisfy { $0.copy.path.hasPrefix(into.path + "/") })
        #expect(try String(contentsOf: copies[1].copy, encoding: .utf8) == "z")
    }
}

@Suite("Anchored edits, plain form")
struct AnchoredEditPlainTests {

    @Test("Plain blocks read as edits, lines kept together, several in a row")
    func plain() throws {
        let edits = try AnchoredEdit.parse("""
        --- old
        Ship the parser
        on Friday.
        --- new
        Ship the parser on Monday.
        --- old
        [[Ideas]]
        --- new
        [[Ideas]], {and, more}

        """)
        #expect(edits == [
            AnchoredEdit(old: "Ship the parser\non Friday.", new: "Ship the parser on Monday."),
            // The heredoc's last newline ends the last line; it is not text.
            AnchoredEdit(old: "[[Ideas]]", new: "[[Ideas]], {and, more}"),
        ])
    }

    /// JSON keeps working for every agent already taught it.
    @Test("JSON still reads, and a broken plain form says what is wrong")
    func jsonAndErrors() throws {
        #expect(try AnchoredEdit.parse(#"[{"old": "a", "new": "b"}]"#) == [AnchoredEdit(old: "a", new: "b")])
        #expect(throws: AnchoredEdit.PlainFormError.self) { try AnchoredEdit.parse("stray\n--- old\na\n--- new\nb") }
        #expect(throws: AnchoredEdit.PlainFormError.self) { try AnchoredEdit.parse("--- old\na") }
        #expect(try AnchoredEdit.parse("").isEmpty)
    }
}

@Suite("Question or search")
struct QuestionShapeTests {

    @Test("Questions and requests read as asks")
    func questions() {
        for text in [
            "what did I write this week", "When is the parser due?", "summarise my thesis notes",
            "wie war das meeting gestern", "draft a note about the sidebar", "parser?",
            "notes from the meeting with the design group last tuesday",
        ] {
            #expect(QuestionShape.isQuestion(text), "\(text)")
        }
    }

    /// A few words are a search, whatever they start with: "what i learned"
    /// is as likely a note's name as a question.
    @Test("A few keywords are a search")
    func searches() {
        for text in ["plan", "v0.7", "parser deadline", "what i learned", "meeting notes friday", ""] {
            #expect(!QuestionShape.isQuestion(text), "\(text)")
        }
    }
}
