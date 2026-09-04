import Foundation
import Testing
@testable import HeftCore

/// Checks that run the command line as a command line.
///
/// The pure decisions are tested directly, but two of the bugs these cover
/// lived in the *plumbing* — `print` adding a newline, an empty argument
/// matching every id — where nothing pure was wrong. Only the built binary can
/// answer for those, so it is run as a subprocess the way the Vim suite runs
/// Neovim.
@Suite("Agent command line")
struct AgentCLITests {

    // MARK: - Running it

    private static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        let candidates = ["debug/Heft", "release/Heft"].map { build.appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private struct Output {
        let standard: Data
        let error: String
        let status: Int32

        var text: String { String(decoding: standard, as: UTF8.self) }
    }

    private func run(
        _ arguments: [String], stdin: String? = nil, readLog: URL? = nil
    ) throws -> Output {
        guard let binary = Self.binary else {
            throw CLIUnavailable()
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Never the reader's own Application Support: these run the real
        // binary, and a test must not leave read snapshots behind in it.
        environment["HEFT_READ_LOG"] = (readLog ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")).path
        process.environment = environment
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
        try? input.fileHandleForWriting.close()
        let standard = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            standard: standard,
            error: String(decoding: errors, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    private struct CLIUnavailable: Error {}

    private func vault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLITests-\(UUID().uuidString)")
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: url)
        }
        return root
    }

    // MARK: - read

    @Test("`heft read` hands back the file's bytes and adds nothing")
    func readIsByteExact() throws {
        // Three shapes, because the bug was `print`: a note ending in a
        // newline came back with two, one ending without a newline gained
        // one, and every read/propose round trip therefore grew the note.
        for body in ["one\ntwo\n", "no trailing newline", "trailing blank line\n\n"] {
            let root = try vault(["Note.md": body])
            defer { try? FileManager.default.removeItem(at: root) }

            let output = try run(["read", root.path, "Note.md"])
            #expect(output.status == 0)
            #expect(output.standard == Data(body.utf8))
        }
    }

    @Test("A read that round-trips through propose is no change at all")
    func readFeedsProposeUnchanged() throws {
        let root = try vault(["Note.md": "# Title\n\nBody.\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let read = try run(["read", root.path, "Note.md"])
        let proposed = try run(["propose", root.path, "Note.md"], stdin: read.text)
        #expect(proposed.text.contains("no change"))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    // MARK: - drop

    @Test("An empty proposal id drops nothing")
    func emptyIdDropsNothing() throws {
        let root = try vault(["Note.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ProposalStore.write(
            Proposal(notePath: "Note.md", base: "body\n", body: "new\n", agent: "t", summary: "s"),
            in: root
        )

        let output = try run(["drop", root.path, ""])
        #expect(output.status != 0)
        #expect(ProposalStore.all(in: root).count == 1)
    }

    @Test("A proposal id that names nothing is refused, and drops nothing")
    func unknownIdDropsNothing() throws {
        let root = try vault(["Note.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ProposalStore.write(
            Proposal(notePath: "Note.md", base: "body\n", body: "new\n", agent: "t", summary: "s"),
            in: root
        )

        #expect(try run(["drop", root.path, "nonsense"]).status != 0)
        #expect(ProposalStore.all(in: root).count == 1)
    }

    @Test("A real id still drops by prefix")
    func prefixStillWorks() throws {
        let root = try vault(["Note.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = Proposal(
            notePath: "Note.md", base: "body\n", body: "new\n", agent: "t", summary: "s"
        )
        try ProposalStore.write(proposal, in: root)

        #expect(try run(["drop", root.path, String(proposal.id.prefix(6))]).status == 0)
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    // MARK: - Matching, without a process

    @Test("Which proposal an id names")
    func matching() {
        let a = Proposal(id: "abcdef", notePath: "A.md", base: nil, body: "", agent: "t", summary: "")
        let b = Proposal(id: "abc123", notePath: "B.md", base: nil, body: "", agent: "t", summary: "")
        let all = [a, b]

        #expect(ProposalStore.match("abcd", among: all) == .one("abcdef"))
        #expect(ProposalStore.match("abcdef", among: all) == .one("abcdef"))
        // The empty string is a prefix of everything, which is exactly how a
        // shell expanding a variable to nothing deleted a real proposal.
        #expect(ProposalStore.match("", among: all) == .missing)
        #expect(ProposalStore.match(nil, among: all) == .missing)
        #expect(ProposalStore.match("zz", among: all) == .unknown("zz"))
        #expect(ProposalStore.match("abc", among: all) == .ambiguous(["abcdef", "abc123"]))
        // Nothing to match against is "no such proposal", not "give me one".
        #expect(ProposalStore.match("abc", among: []) == .unknown("abc"))
    }

    // MARK: - Reading before proposing

    @Test("A note that changed since the agent read it refuses a whole-body proposal")
    func staleReadIsRefused() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }

        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)
        // The reader types a line while the agent is thinking.
        try Data("one\ntwo\nthe user typed this\n".utf8)
            .write(to: root.appendingPathComponent("Note.md"))

        let refused = try run(
            ["propose", root.path, "Note.md"], stdin: "one\ntwo revised\n", readLog: log
        )
        #expect(refused.status != 0)
        #expect(refused.error.contains("changed since you read it"))
        #expect(ProposalStore.all(in: root).isEmpty)

        // Reading again is the way through, and nothing else had to change.
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)
        let accepted = try run(
            ["propose", root.path, "Note.md"],
            stdin: "one\ntwo revised\nthe user typed this\n", readLog: log
        )
        #expect(accepted.status == 0)
        #expect(ProposalStore.all(in: root).count == 1)
    }

    @Test("An agent that never read the note is not held to a read it never made")
    func unreadNoteProposesFreely() throws {
        let root = try vault(["Note.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Note.md"], stdin: "two\n").status == 0)
        #expect(ProposalStore.all(in: root).count == 1)
    }

    @Test("--replace is exempt, because its anchors are checked against the note now")
    func replaceIsExempt() throws {
        let root = try vault(["Note.md": "alpha\nbeta\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }

        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)
        try Data("alpha\nbeta\ngamma\n".utf8).write(to: root.appendingPathComponent("Note.md"))

        let output = try run(
            ["propose", root.path, "Note.md", "--replace"],
            stdin: #"[{"old": "beta", "new": "BETA"}]"#, readLog: log
        )
        #expect(output.status == 0)
        // The line the reader added survives, because the anchor resolved
        // against the note as it is now.
        #expect(ProposalStore.all(in: root).first?.body == "alpha\nBETA\ngamma\n")
    }

    // MARK: - changes

    @Test("`heft changes` shows what moved since the last read")
    func changesSinceRead() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }

        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)
        #expect(try run(["changes", root.path, "Note.md"], readLog: log).text
            .contains("no change since you read"))

        try Data("one\ntwo and a half\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        let output = try run(["changes", root.path, "Note.md"], readLog: log)
        #expect(output.text.contains("-two"))
        #expect(output.text.contains("+two and a half"))
    }

    @Test("`heft changes` on a note nobody read says so, rather than diffing against nothing")
    func changesWithoutARead() throws {
        let root = try vault(["Note.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try run(["changes", root.path, "Note.md"])
        #expect(output.status != 0)
        #expect(output.error.contains("nothing recorded"))
    }

    // MARK: - The store itself

    @Test("A read snapshot is one per note, replaced, and swept when it goes cold")
    func readLogRetention() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftReadLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ReadLog(directory: directory)
        let vaultURL = URL(fileURLWithPath: "/tmp/somevault")

        log.record("first\n", vault: vaultURL, relativePath: "A.md")
        #expect(log.last(vault: vaultURL, relativePath: "A.md")?.text == "first\n")

        // The last read is what both questions are about, so a second read
        // replaces the first rather than accumulating.
        log.record("second\n", vault: vaultURL, relativePath: "A.md")
        #expect(log.last(vault: vaultURL, relativePath: "A.md")?.text == "second\n")

        #expect(log.freshness(vault: vaultURL, relativePath: "A.md", current: "second\n") == .fresh)
        #expect(log.freshness(vault: vaultURL, relativePath: "B.md", current: "x") == .unread)
        if case .stale = log.freshness(vault: vaultURL, relativePath: "A.md", current: "third\n") {
        } else {
            Issue.record("a note that moved on should read as stale")
        }

        // A note read a fortnight ago is swept by the next write.
        let cold = Date().addingTimeInterval(-ReadLog.retention - 60)
        log.record("old\n", vault: vaultURL, relativePath: "C.md", at: cold)
        log.record("new\n", vault: vaultURL, relativePath: "D.md")
        #expect(log.last(vault: vaultURL, relativePath: "C.md") == nil)
        #expect(log.last(vault: vaultURL, relativePath: "D.md")?.text == "new\n")

        // Two vaults with the same note path do not share a snapshot.
        let other = URL(fileURLWithPath: "/tmp/othervault")
        log.record("elsewhere\n", vault: other, relativePath: "A.md")
        #expect(log.last(vault: vaultURL, relativePath: "A.md")?.text == "second\n")
    }

    // MARK: - agent-setup

    @Test("Setup writes a guide for every agent, and leaves each file's own words alone")
    func setUpWritesBothGuides() throws {
        let root = try vault([
            "Note.md": "body\n",
            // Somebody's own instructions, in one file but not the other.
            "AGENTS.md": "# My vault\n\nDrafts live in Inbox/.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["agent-setup", root.path]).status == 0)

        for name in ["CLAUDE.md", "AGENTS.md"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8
            )
            #expect(text.contains(AgentGuide.markerStart), "\(name) carries the guide")
            #expect(AgentGuide.versionStamp(in: text) == AgentGuide.version)
        }
        // The preamble that was already there survived; the file that had none
        // got the generated one rather than the other file's.
        let agents = try String(
            contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8
        )
        #expect(agents.contains("Drafts live in Inbox/."))
        let claude = try String(
            contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8
        )
        #expect(!claude.contains("Drafts live in Inbox/."))

        // Running it again is idempotent: one section per file, still.
        #expect(try run(["agent-setup", root.path]).status == 0)
        #expect(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
            .components(separatedBy: AgentGuide.markerStart).count == 2)
    }

    @Test("The oldest guide in a vault is the one a vault is judged by")
    func vaultStatusTakesTheOldest() throws {
        let root = try vault(["Note.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentGuide.status(ofVaultAt: root) == .absent)

        #expect(try run(["agent-setup", root.path]).status == 0)
        #expect(AgentGuide.status(ofVaultAt: root) == .current)

        // Whoever brought Codex is reading the stale one, so the vault is stale.
        var agents = try String(
            contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8
        )
        agents = agents.replacingOccurrences(
            of: "\(AgentGuide.versionMarker) \(AgentGuide.version) -->",
            with: "\(AgentGuide.versionMarker) 2 -->"
        )
        try agents.write(
            to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8
        )
        #expect(AgentGuide.status(ofVaultAt: root) == .outdated(found: 2))
    }

    // MARK: - Permissions

    @Test("Setup ships permission rules, and keeps whatever was already in them")
    func setUpWritesPermissions() throws {
        let root = try vault([
            "Note.md": "body\n",
            ".claude/settings.json": """
                {"permissions": {"allow": ["Bash(git status)"]}, "model": "Opus"}
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["agent-setup", root.path]).status == 0)
        let text = try String(
            contentsOf: root.appendingPathComponent(AgentPermissions.path), encoding: .utf8
        )
        #expect(AgentPermissions.isSatisfied(by: text))

        let parsed = try #require(AgentPermissions.parsed(text))
        // Their own settings survive: the file is theirs.
        #expect(parsed["model"] as? String == "Opus")
        let permissions = try #require(parsed["permissions"] as? [String: Any])
        #expect((permissions["allow"] as? [String])?.contains("Bash(git status)") == true)

        // Idempotent: running it again adds nothing twice.
        #expect(try run(["agent-setup", root.path]).status == 0)
        let reread = try #require(AgentPermissions.parsed(
            try String(contentsOf: root.appendingPathComponent(AgentPermissions.path),
                       encoding: .utf8)
        ))
        let again = try #require(reread["permissions"] as? [String: Any])
        #expect((again["deny"] as? [String])?.count == AgentPermissions.deny.count)
    }

    @Test("A settings file that is not JSON is left alone rather than overwritten")
    func brokenPermissionsAreLeftAlone() throws {
        let broken = "{ this was hand-edited and never closed"
        let root = try vault(["Note.md": "body\n", ".claude/settings.json": broken])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["agent-setup", root.path]).status == 0)
        #expect(try String(
            contentsOf: root.appendingPathComponent(AgentPermissions.path), encoding: .utf8
        ) == broken)
    }

    @Test("The rules deny writing a note and still allow a scratch file")
    func permissionRulesAreScoped() {
        // Denying the tools by name would also stop the agent writing the
        // /tmp file `heft propose --from` reads, which is the workflow the
        // guide teaches. So every deny rule carries a path.
        for rule in AgentPermissions.deny {
            #expect(rule.contains("("), "\(rule) must be scoped to a path")
        }
        #expect(AgentPermissions.allow.contains("Bash(heft:*)"))

        // A fresh vault gets a file that satisfies its own check.
        #expect(AgentPermissions.isSatisfied(by: AgentPermissions.merged(into: nil)))
        #expect(!AgentPermissions.isSatisfied(by: "{}"))
    }

    // MARK: - attachment

    @Test("`heft attachment` answers with the rules the editor pastes with")
    func attachmentDestination() throws {
        // A vault that already keeps figures beside a note, plus an
        // Attachments folder elsewhere: which one answers is exactly what an
        // agent cannot work out from `heft config`.
        let root = try vault([
            "Projects/Thing.md": "See ![[chart.png]]\n",
            "Projects/chart.png": "x",
            "Attachments/other.png": "x",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["attachment", root.path, "Projects/Thing.md", "shot.png", "--json"])
        #expect(output.status == 0)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: output.standard) as? [String: Any]
        )
        #expect(payload["note"] as? String == "Projects/Thing.md")
        // Learned from the vault: the note's own folder already holds one.
        #expect(payload["folder"] as? String == "Projects")
        #expect(payload["rule"] as? String == "learned")
        #expect(payload["file"] as? String == root.appendingPathComponent(
            "Projects/shot.png"
        ).path)
        #expect(payload["link"] as? String == "![[shot.png]]")
    }

    @Test("A vault that writes Markdown links gets a Markdown link back")
    func attachmentLinkFollowsTheVault() throws {
        let root = try vault([
            "Projects/Thing.md": "body\n",
            ".obsidian/app.json": #"{"useMarkdownLinks": true}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["attachment", root.path, "Projects/Thing.md", "shot.png"])
        #expect(output.text.contains("![](") , "got \(output.text)")
        #expect(!output.text.contains("![[shot.png]]"))
    }

    @Test("Naming no file still says where one would go")
    func attachmentWithoutAFilename() throws {
        let root = try vault(["Thing.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try run(["attachment", root.path, "Thing.md"])
        #expect(output.status == 0)
        #expect(output.text.contains("folder:"))
        #expect(!output.text.contains("link:"))
    }
}
