import Foundation
import HeftCore
import Testing

/// How Heft runs the reader's agent: what it may touch, and what it reports.
@Suite("Agent invocation")
struct AgentInvocationTests {

    private func invocation(scope: String = "/vault/Work", allowed: [String] = []) -> AgentInvocation {
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
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(value(after: "--mcp-config", in: arguments) == #"{"mcpServers":{}}"#)
        #expect(value(after: "--model", in: arguments) == "haiku")
        #expect(value(after: "-p", in: arguments) == "What is due Friday?")
        #expect(!arguments.contains("--resume"))
    }

    @Test("The heft verbs that write without review are not allowed")
    func heftVerbs() {
        let arguments = invocation().arguments
        let allowed = arguments.filter { $0.hasPrefix("Bash(") }
        #expect(allowed.contains("Bash(heft propose *)"))
        #expect(allowed.contains("Bash(heft read *)"))
        for verb in ["rename", "capture", "daily", "export"] {
            #expect(!allowed.contains { $0.hasPrefix("Bash(heft \(verb)") }, "\(verb)")
        }
        #expect(!arguments.contains { $0.contains("Edit") || $0.contains("Write") })
    }

    @Test("A reply resumes the session, and an allowed read joins the rules")
    func resumeAndAllow() {
        var asked = invocation(allowed: ["Read(//vault/Home/Plan.md)"])
        asked.resume = "session-1"
        let arguments = asked.arguments
        #expect(value(after: "--resume", in: arguments) == "session-1")
        #expect(arguments.contains("Read(//vault/Home/Plan.md)"))
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

    @Test("This app's heft comes first on the PATH")
    func path() {
        let environment = invocation().environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/home/reader"])
        #expect(environment["PATH"]?.hasPrefix("/support/agent-bin:/tools/bin:/usr/bin:/bin") == true)
        #expect(environment["HOME"] == "/home/reader")
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
            AgentDenial(tool: "Read", target: "/vault/Home/Secret.md", allowRule: "Read(//vault/Home/Secret.md)"),
            AgentDenial(tool: "Bash", target: "rm Ideas.md", allowRule: nil),
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
        #expect(outcome.denials.map(\.allowRule) == ["Read(//vault/Home/**)", nil, nil])
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
