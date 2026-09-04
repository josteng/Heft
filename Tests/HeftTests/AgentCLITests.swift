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

    /// Dropping takes the **whole** id, and reading takes a prefix.
    ///
    /// A prefix names a different set of proposals at different times, and the
    /// ambiguity check only sees collisions that exist while it runs: a
    /// prefix that is unique today deletes something else next week, without
    /// ever being reported as ambiguous. That is a fine trade for `diff`,
    /// where the cost of the wrong one is reading it, and not for `drop`.
    @Test("Dropping needs the whole id; diffing does not")
    func dropIsExactAndDiffIsNot() throws {
        let root = try vault(["Note.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ProposalStore.write(
            Proposal(
                id: "tighten-the-opening", notePath: "Note.md",
                base: "body\n", body: "new\n", agent: "t", summary: "Tighten the opening"
            ),
            in: root
        )

        // Reading by prefix, as before.
        #expect(try run(["diff", root.path, "tighten"]).status == 0)

        // Dropping by prefix, no longer. And it says what the whole id is,
        // rather than "no such proposal" beside a list that plainly shows one.
        let refused = try run(["drop", root.path, "tighten"])
        #expect(refused.status != 0)
        #expect(refused.error.contains("tighten-the-opening"))
        #expect(ProposalStore.all(in: root).count == 1)

        #expect(try run(["drop", root.path, "tighten-the-opening"]).status == 0)
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
        // Exactly: a prefix names nothing, however unambiguous it looks.
        #expect(ProposalStore.match("abcd", among: all, exactly: true) == .unknown("abcd"))
        #expect(ProposalStore.match("abcdef", among: all, exactly: true) == .one("abcdef"))
        #expect(ProposalStore.match("", among: all, exactly: true) == .missing)
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

    // MARK: - One proposal per note

    @Test("A second proposal on the same note is refused, and says how to replace it")
    func secondProposalIsRefused() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try run(["propose", root.path, "Note.md", "--summary", "widen the intro"],
                            stdin: "one\ntwo\nthree\n")
        #expect(first.status == 0)

        let second = try run(["propose", root.path, "Note.md", "--summary", "something else"],
                             stdin: "one\nfour\n")
        #expect(second.status != 0)
        let complaint = second.error
        // Names the one in the way, and both ways out of it.
        #expect(complaint.contains("widen-the-intro"))
        #expect(complaint.contains("--replacing"))
        #expect(complaint.contains("heft drop"))

        // Nothing was written: refusing has to mean refusing.
        #expect(ProposalStore.forNote("Note.md", in: root).count == 1)
    }

    @Test("`--replacing` swaps one proposal for another in a single command")
    func replacingSwapsTheProposal() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Note.md", "--summary", "remove the image"],
                        stdin: "one\n").status == 0)
        let old = try #require(ProposalStore.all(in: root).first)

        let output = try run(
            ["propose", root.path, "Note.md", "--replacing", old.id,
             "--summary", "remove the whole quote block"],
            stdin: "\n"
        )
        #expect(output.status == 0)
        #expect(output.text.contains("replaced \(old.id)"))

        // One proposal on the note, and it is the new one under its own name.
        let pending = ProposalStore.forNote("Note.md", in: root)
        #expect(pending.count == 1)
        #expect(pending.first?.id == "remove-the-whole-quote-block")
        #expect(pending.first?.summary == "remove the whole quote block")
    }

    @Test("Replacing under the same summary keeps the name rather than numbering it")
    func replacingReusesTheName() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Note.md", "--summary", "tighten the opening"],
                        stdin: "one\n").status == 0)
        #expect(try run(["propose", root.path, "Note.md", "--replacing", "tighten-the-opening",
                         "--summary", "tighten the opening"],
                        stdin: "two\n").status == 0)

        let pending = ProposalStore.all(in: root)
        #expect(pending.count == 1)
        // Not `tighten-the-opening-2` beside a deleted `tighten-the-opening`.
        #expect(pending.first?.id == "tighten-the-opening")
        #expect(pending.first?.body == "two\n")
    }

    @Test("A proposal on another note is not a collision")
    func otherNotesAreUnaffected() throws {
        let root = try vault(["A.md": "a\n", "B.md": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "A.md", "--summary", "change a"],
                        stdin: "a2\n").status == 0)
        #expect(try run(["propose", root.path, "B.md", "--summary", "change b"],
                        stdin: "b2\n").status == 0)
        #expect(ProposalStore.all(in: root).count == 2)
    }

    @Test("A delete cannot be stacked on a pending edit to the same note either")
    func structuralProposalsCollideToo() throws {
        let root = try vault(["Note.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Note.md", "--summary", "rewrite it"],
                        stdin: "two\n").status == 0)
        let delete = try run(["propose", root.path, "Note.md", "--delete",
                              "--summary", "drop the note"])
        #expect(delete.status != 0)
        #expect(delete.error.contains("rewrite-it"))
        #expect(ProposalStore.all(in: root).count == 1)
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

        // One rule, spelled the one way the check reads. A deny rule Claude
        // Code cannot match is worse than none: it warns and then sets the
        // whole file aside.
        #expect(AgentPermissions.deny == ["Edit(**)"])
        #expect(!AgentPermissions.deny.contains(where: AgentPermissions.superseded.contains))
    }

    @Test("Setup takes out the rules an earlier Heft wrote that Claude Code rejects")
    func supersededPermissionsAreRemoved() throws {
        // What `heft agent-setup` wrote up to guide version 10, plus a rule of
        // the user's that has to survive.
        let root = try vault([
            "Note.md": "body\n",
            ".claude/settings.json": """
                {"permissions": {"allow": ["Bash(heft:*)"], "deny": \
                ["Edit(**)", "Write(**)", "NotebookEdit(**)", "Bash(rm:*)"]}}
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try String(
            contentsOf: root.appendingPathComponent(AgentPermissions.path), encoding: .utf8
        )
        // Every rule Heft wants is already there, and the file is still not
        // satisfied: this is what makes setup rewrite it rather than skip it.
        #expect(!AgentPermissions.isSatisfied(by: before))

        #expect(try run(["agent-setup", root.path]).status == 0)
        let text = try String(
            contentsOf: root.appendingPathComponent(AgentPermissions.path), encoding: .utf8
        )
        #expect(AgentPermissions.isSatisfied(by: text))

        let permissions = try #require(
            AgentPermissions.parsed(text)?["permissions"] as? [String: Any]
        )
        let denied = try #require(permissions["deny"] as? [String])
        #expect(denied.contains("Edit(**)"))
        for rule in AgentPermissions.superseded { #expect(!denied.contains(rule)) }
        // Removing ours must not take theirs with it.
        #expect(denied.contains("Bash(rm:*)"))
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

    // MARK: - Names rather than numbers

    @Test("A proposal is named after what it is for")
    func proposalsAreNamed() {
        func name(_ summary: String?, note: String = "Before Release.md",
                  taken: Set<String> = []) -> String {
            ProposalStore.identifier(summary: summary, noteName: note, taken: taken)
        }

        #expect(name("Tighten the opening") == "tighten-the-opening")
        // Punctuation and case are not part of a name.
        #expect(name("Add a “Next” section!") == "add-a-next-section")

        // No summary means the note, without its extension: the default
        // summary is the same words every time, so `proposed-edit-7` would
        // name nothing at all.
        #expect(name(nil) == "before-release")
        #expect(name(ProposalStore.defaultSummary) == "before-release")
        #expect(name("   ") == "before-release")

        // Nothing usable at all still has to produce a filename.
        #expect(name("…!!!", note: "§.md") == "proposal")

        // Cut between words, not mid-word.
        let long = name("Tighten the opening and add a Next section about naming")
        #expect(long.count <= ProposalStore.slugLimit)
        #expect(long == "tighten-the-opening-and-add-a-next")

        // Two proposals for the same thing are numbered, not hashed.
        #expect(name("Tighten the opening", taken: ["tighten-the-opening"])
            == "tighten-the-opening-2")
        #expect(name("Tighten the opening",
                     taken: ["tighten-the-opening", "tighten-the-opening-2"])
            == "tighten-the-opening-3")
    }

    @Test("A name is safe to use as a filename")
    func namesAreSafeFilenames() {
        // The id is the filename under `.heft/proposals`, so anything that
        // could climb out of it must be impossible to produce.
        for summary in ["../../etc/passwd", "..", "/", "a/b/c", ".", ""] {
            let id = ProposalStore.identifier(
                summary: summary, noteName: "N.md", taken: []
            )
            #expect(!id.isEmpty)
            #expect(!id.contains("/"))
            #expect(!id.contains("."))
        }
    }

    @Test("A named proposal round-trips through the store and its verbs")
    func namedProposalRoundTrip() throws {
        let root = try vault(["Note.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let proposed = try run(
            ["propose", root.path, "Note.md", "--summary", "Tighten the opening"],
            stdin: "two\n"
        )
        #expect(proposed.text.contains("proposed tighten-the-opening"))
        #expect(ProposalStore.all(in: root).first?.id == "tighten-the-opening")

        // The point of a readable id is that a person can type it, and read
        // it back from `heft proposals` to hand to another verb.
        #expect(try run(["diff", root.path, "tighten"]).status == 0)
        #expect(try run(["drop", root.path, "tighten-the-opening"]).status == 0)
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    // MARK: - Kinds and groups

    @Test("A proposal from before kinds existed still loads")
    func oldProposalsStillDecode() throws {
        let root = try vault(["Note.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: ProposalStore.directory(in: root), withIntermediateDirectories: true
        )
        // Exactly the shape Heft wrote before `kind`, `destination` and
        // `group`: the synthesised Codable would have rejected all of these,
        // and the failure mode is a proposal silently vanishing from the list.
        try #"""
            {
              "agent" : "claude-code",
              "base" : "one\n",
              "body" : "two\n",
              "createdAt" : "2026-01-01T00:00:00Z",
              "id" : "old-one",
              "notePath" : "Note.md",
              "summary" : "An older proposal"
            }
            """#.write(
                to: ProposalStore.directory(in: root).appendingPathComponent("old-one.json"),
                atomically: true, encoding: .utf8
            )

        let loaded = try #require(ProposalStore.all(in: root).first)
        #expect(loaded.id == "old-one")
        #expect(loaded.kind == .edit, "it carried a base, so it was an edit")
        #expect(loaded.group == nil)
        #expect(loaded.destination == nil)
    }

    @Test("A proposal for a note that did not exist reads as a create")
    func oldNewNoteProposalIsACreate() throws {
        let root = try vault(["Other.md": "x\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: ProposalStore.directory(in: root), withIntermediateDirectories: true
        )
        try #"""
            {
              "agent" : "claude-code",
              "body" : "hello\n",
              "createdAt" : "2026-01-01T00:00:00Z",
              "id" : "old-new",
              "notePath" : "Fresh.md",
              "summary" : "A note that was not there"
            }
            """#.write(
                to: ProposalStore.directory(in: root).appendingPathComponent("old-new.json"),
                atomically: true, encoding: .utf8
            )
        // Nil `base` is exactly what "the note does not exist yet" used to mean.
        #expect(ProposalStore.all(in: root).first?.kind == .create)
    }

    @Test("Deleting and moving are proposable, and read no body")
    func structuralProposals() throws {
        let root = try vault(["Old/C.md": "x\n", "Keep.md": "y\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Old/C.md", "--move", "New/C.md"]).status == 0)
        #expect(try run(["propose", root.path, "Keep.md", "--delete"]).status == 0)

        let all = ProposalStore.all(in: root)
        let move = try #require(all.first { $0.kind == .move })
        #expect(move.destination == "New/C.md")
        #expect(move.isStructural)
        #expect(move.headline == "Move Old/C.md to New/C.md")
        let remove = try #require(all.first { $0.kind == .delete })
        #expect(remove.isStructural)
        #expect(remove.body.isEmpty)

        // Nothing happened to the vault: it is a proposal.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Old/C.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Keep.md").path))
    }

    @Test("A structural proposal is refused when it cannot be carried out")
    func structuralProposalsAreChecked() throws {
        let root = try vault(["A.md": "x\n", "B.md": "y\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Better to fail at the command than at review time, which is the same
        // rule --replace follows for its anchors.
        #expect(try run(["propose", root.path, "Nope.md", "--delete"]).status != 0)
        #expect(try run(["propose", root.path, "A.md", "--move", "B.md"]).status != 0)
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("Repeating the same words joins one change")
    func groupsJoinByTheirWords() throws {
        let root = try vault(["A.md": "one\n", "B.md": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        for note in ["A.md", "B.md"] {
            #expect(try run(
                ["propose", root.path, note, "--group", "Rename the concept"],
                stdin: "two\n"
            ).status == 0)
        }
        let pending = ProposalStore.pending(in: root)
        #expect(pending.groups.count == 1)
        #expect(pending.groups.first?.summary == "Rename the concept")
        #expect(pending.groups.first?.proposals.count == 2)
        #expect(pending.edits.isEmpty)
    }

    @Test("What a review list shows: groups, edits, and structural changes")
    func sortingPending() {
        func edit(_ id: String, group: String? = nil) -> Proposal {
            Proposal(
                id: id, notePath: "\(id).md", base: "a", body: "b",
                agent: "t", summary: id,
                group: group.map { Proposal.Group(summary: $0) }
            )
        }
        func removal(_ id: String, group: String? = nil) -> Proposal {
            Proposal(
                id: id, notePath: "\(id).md", base: nil, body: "",
                agent: "t", summary: id, kind: .delete,
                group: group.map { Proposal.Group(summary: $0) }
            )
        }

        let sorted = ProposalStore.sort([
            edit("one", group: "rename it"),
            edit("two", group: "rename it"),
            removal("three", group: "rename it"),
            edit("four"),
            removal("five"),
            // A group of one is not a group: an agent that names a change
            // while touching a single note has described that proposal, and a
            // heading with one row under it is a fold with nothing in it.
            edit("six", group: "a lone change"),
        ])

        #expect(sorted.groups.count == 1)
        #expect(sorted.groups.first?.proposals.map(\.id) == ["one", "two", "three"])
        #expect(sorted.edits.map(\.id) == ["four", "six"])
        #expect(sorted.structural.map(\.id) == ["five"])
        #expect(sorted.count == 6)
    }
}
