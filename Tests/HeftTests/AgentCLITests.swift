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
        _ arguments: [String], stdin: String? = nil, readLog: URL? = nil,
        defaultsSuite: String? = nil
    ) throws -> Output {
        guard let binary = Self.binary else {
            throw CLIUnavailable()
        }
        // Nor the reader's preferences: the binary reads and writes the
        // frecency stores and the capture vault through them. A throwaway
        // suite per run unless the test wants to look inside one.
        let suite = defaultsSuite ?? "HeftCLIDefaults-\(UUID().uuidString)"
        defer {
            if defaultsSuite == nil {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Never the reader's own Application Support: these run the real
        // binary, and a test must not leave read snapshots behind in it.
        environment["HEFT_READ_LOG"] = (readLog ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")).path
        environment["HEFT_INDEX_CACHE"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIIndex-\(UUID().uuidString)").path
        environment[HeftDefaults.suiteEnvironmentKey] = suite
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

    /// Said while proposing, so an agent can pick somewhere else rather than
    /// a person finding out only when they come to accept it.
    @Test("Proposing a move out of the daily folder says what it costs")
    func movingADailyNoteIsCalledOut() throws {
        let root = try vault([
            ".obsidian/daily-notes.json": #"{"folder": "Daily Notes", "format": "YYYY-MM-DD"}"#,
            "Daily Notes/2026-09-06.md": "today\n",
            "Plan.md": "plan\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let leaving = try run([
            "propose", root.path, "Daily Notes/2026-09-06.md", "--move", "Archive/2026-09-06.md",
            "--summary", "Archive it",
        ])
        #expect(leaving.text.contains(
            "note:    Daily Notes/2026-09-06.md stops being a daily note."
        ))
        #expect(leaving.text.contains("The calendar only looks in Daily Notes."))

        // An ordinary note moved anywhere, and a daily note kept in its own
        // folder, are nobody's business but the reader's.
        let ordinary = try run([
            "propose", root.path, "Plan.md", "--move", "Archive/Plan.md", "--summary", "Archive it",
        ])
        #expect(!ordinary.text.contains("daily note"))
        let renamed = try run([
            "propose", root.path, "Daily Notes/2026-09-06.md",
            "--move", "Daily Notes/2026-09-08.md", "--summary", "Shift it",
        ])
        #expect(!renamed.text.contains("daily note"))
    }

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

    /// The count on the "change:" line agrees with its noun.
    @Test("A proposal reports one hunk or two hunks")
    func hunkCountReadsRight() throws {
        let root = try vault(["Note.md": "one\ntwo\nthree\nfour\nfive\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try readLog(having: ["Note.md"], in: root)

        let single = try run(["propose", root.path, "Note.md"], stdin: "one\ntwo revised\nthree\nfour\nfive\n", readLog: log)
        #expect(single.text.contains("in 1 hunk\n"), "\(single.text)")
        // A second vault: a note with a proposal waiting refuses another.
        let other = try vault(["Note.md": "one\ntwo\nthree\nfour\nfive\n"])
        defer { try? FileManager.default.removeItem(at: other) }
        let otherLog = try readLog(having: ["Note.md"], in: other)
        let double = try run(["propose", other.path, "Note.md"], stdin: "one revised\ntwo\nthree\nfour\nfive revised\n", readLog: otherLog)
        #expect(double.text.contains("in 2 hunks\n"), "\(double.text)")
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

    /// A whole-body proposal needs the note read first. Tests whose subject
    /// is something else get their read through this, rather than each one
    /// restating a rule that has its own tests below.
    private func readLog(having notes: [String], in root: URL) throws -> URL {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        for note in notes {
            #expect(try run(["read", root.path, note], readLog: log).status == 0)
        }
        return log
    }

    // MARK: - export

    /// The output path is arbitrary and outside the vault, so this is the one
    /// verb that can destroy a file the vault knows nothing about. It did:
    /// silently, exit 0, under a blanket allow of the heft command.
    @Test("export will not silently replace a file that is already there")
    func exportRefusesToClobber() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: victim)
        }
        let precious = "IMPORTANT PRE-EXISTING CONTENT\n"
        try Data(precious.utf8).write(to: victim)

        let refused = try run(["export", root.path, "Note.md", victim.path])
        #expect(refused.status != 0)
        #expect(refused.error.contains("already exists"))
        #expect(refused.error.contains("--force"))
        // Refusing has to mean refusing.
        #expect(try String(contentsOf: victim, encoding: .utf8) == precious)
    }

    @Test("--force is how you say you meant it")
    func exportForceOverwrites() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: victim)
        }
        try Data("replace me\n".utf8).write(to: victim)

        #expect(try run(["export", root.path, "Note.md", victim.path, "--force"]).status == 0)
        let written = try Data(contentsOf: victim)
        #expect(written.starts(with: Array("%PDF".utf8)))
    }

    @Test("A path that is free still needs no flag")
    func exportToAFreePathIsUnchanged() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }

        #expect(try run(["export", root.path, "Note.md", out.path]).status == 0)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - daily

    /// A shell variable that did not expand is the usual way a bad date
    /// arrives, and guessing put a templated note in the vault on a day
    /// nobody asked about.
    @Test("daily refuses a date it cannot read rather than assuming today")
    func dailyRefusesABadDate() throws {
        let root = try vault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in ["not-a-date", "", "2026-13-45", "../../escape"] {
            let output = try run(["daily", root.path, bad])
            #expect(output.status != 0, "`heft daily . \(bad)` was accepted")
            #expect(output.error.contains("not a date"))
        }
    }

    @Test("daily still answers for today, and for a real date")
    func dailyStillWorks() throws {
        let root = try vault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["daily", root.path]).status == 0)
        let dated = try run(["daily", root.path, "2026-03-04"])
        #expect(dated.status == 0)
        #expect(dated.text.contains("2026-03-04"))
    }

    // MARK: - files

    /// The listing includes attachments on purpose, but the summary promised
    /// "every note", so the one caller who wanted Markdown only had no way to
    /// ask and no way to know they were not getting it.
    @Test("files lists everything, and --notes narrows it")
    func filesCanBeNarrowedToNotes() throws {
        let root = try vault(["Note.md": "# Note\n", "Folder/Deep.md": "# Deep\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not markdown".utf8)
            .write(to: root.appendingPathComponent("picture.png"))

        let everything = try run(["files", root.path])
        #expect(everything.status == 0)
        #expect(everything.text.contains("picture.png"))
        #expect(everything.text.contains("Note.md"))

        let markdown = try run(["files", root.path, "--notes"])
        #expect(markdown.status == 0)
        #expect(!markdown.text.contains("picture.png"))
        #expect(markdown.text.contains("Note.md"))
        #expect(markdown.text.contains("Folder/Deep.md"))
    }

    @Test("The summary says what the listing actually returns")
    func filesSummaryIsHonest() throws {
        let verb = try #require(CommandLineSpec.verb(named: "files"))
        #expect(verb.summary.contains("attachments"))
        #expect(verb.flags.contains { $0.name == "--notes" })
    }

    /// Flags in any position, because every other command line takes them
    /// that way and an agent writes them that way. Taking the output by index
    /// made `--force` the output path, and a PDF was written to a file of
    /// that name in the working directory, silently and outside the vault.
    @Test("export takes its flags before the output path too")
    func exportParsesFlagsInAnyPosition() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }
        try Data("replace me\n".utf8).write(to: out)
        // Named after the flag, in the working directory, is where the bug
        // put it. Swept either way: this suite has its defects reintroduced
        // deliberately, and a leftover would fail the run after.
        defer { try? FileManager.default.removeItem(atPath: "--force") }

        let output = try run(["export", root.path, "Note.md", "--force", out.path])
        #expect(output.status == 0)
        #expect(!output.error.contains("ignoring"))
        #expect(try Data(contentsOf: out).starts(with: Array("%PDF".utf8)))
        // The bug wrote a file named after the flag. Nowhere.
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("--force").path))
        #expect(!FileManager.default.fileExists(atPath: "--force"))
    }

    @Test("A flag's value is never mistaken for the output path")
    func exportFlagValuesAreNotPositional() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }

        defer {
            try? FileManager.default.removeItem(atPath: "letter")
            try? FileManager.default.removeItem(atPath: "--paper")
        }
        let output = try run(
            ["export", root.path, "Note.md", "--paper", "letter", out.path, "--landscape"])
        #expect(output.status == 0)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(!FileManager.default.fileExists(atPath: "letter"))
    }

    @Test("--force no longer claims it was ignored")
    func forceIsNotReportedAsIgnored() throws {
        let root = try vault(["Note.md": "# Note\n\nbody\n"])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-export-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }

        let output = try run(["export", root.path, "Note.md", out.path, "--force"])
        #expect(output.status == 0)
        #expect(!output.error.contains("ignoring"))
    }

    @Test("The split itself")
    func splitSeparatesFlagsFromPositionals() {
        let result = CommandLineSpec.split(
            ["/vault", "Note.md", "--paper", "letter", "out.pdf", "--landscape"],
            forVerb: "export"
        )
        #expect(result.positional == ["/vault", "Note.md", "out.pdf"])
        #expect(result.flags == ["--paper", "letter", "--landscape"])

        // A switch takes nothing with it.
        let switches = CommandLineSpec.split(
            ["/vault", "Note.md", "--force", "out.pdf"], forVerb: "export")
        #expect(switches.positional == ["/vault", "Note.md", "out.pdf"])
        #expect(switches.flags == ["--force"])
    }

    /// The scan already counted this for the truncation notice. The flag is
    /// only a way to ask for the number it had.
    @Test("--files answers which notes matched, not which lines")
    func findFilesListsNotes() throws {
        let root = try vault([
            "Many.md": (1...5).map { "needle \($0)" }.joined(separator: "\n") + "\n",
            "Few.md": "one needle here\nnothing\n",
            "None.md": "nothing at all\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle", "--files"])
        #expect(output.status == 0)
        let lines = output.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "\(lines)")
        // Most matches first.
        #expect(lines[0].contains("Many.md"))
        #expect(lines[0].hasPrefix("5\t5\t"))
        #expect(lines[1].contains("Few.md"))
        #expect(!output.text.contains("None.md"))
    }

    /// Counted across the whole vault, not across the page of lines shown.
    /// The tally is what tells you about the notes you are not being shown,
    /// so taking it from the truncated list would defeat the flag.
    @Test("--files counts past the line limit")
    func findFilesCountsPastTheLimit() throws {
        let big = (1...100).map { "needle \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Big.md": big, "Small.md": "needle\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle", "--files"])
        #expect(output.status == 0)
        #expect(output.text.contains("100\t100\tBig.md"))
        #expect(output.text.contains("Small.md"))
    }

    @Test("--files and --json together")
    func findFilesAsJSON() throws {
        let root = try vault(["A.md": "needle\nneedle\n", "B.md": "needle\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle", "--files", "--json"])
        #expect(output.status == 0)
        let listed = try #require(
            try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [[String: Any]])
        #expect(listed.count == 2)
        #expect(listed.first?["path"] as? String == "A.md")
        #expect(listed.first?["lines"] as? Int == 2)
    }

    @Test("--limit caps the notes as well, and says so")
    func findFilesRespectsTheLimit() throws {
        let root = try vault([
            "A.md": "needle\n", "B.md": "needle\n", "C.md": "needle\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle", "--files", "--limit", "2"])
        #expect(output.status == 0)
        #expect(output.text.contains("showing 2 of 3 notes"))
    }

    /// `outline <vault> --json "Inbox"` looked up a note called `--json`,
    /// which is a confusing way to say "put the flag last". Every other
    /// command line takes flags anywhere, so an agent writes them anywhere.
    @Test("The read verbs take their flags before the note too")
    func readVerbsTakeLeadingFlags() throws {
        let root = try vault([
            "Folder/Note.md": "# Heading\n\nneedle here\n\nsee [[Other]]\n",
            "Other.md": "# Other\n\nsee [[Folder/Note]]\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        for verb in ["outline", "links", "backlinks"] {
            let leading = try run([verb, root.path, "--json", "Folder/Note"])
            #expect(leading.status == 0, "`\(verb) --json <note>`: \(leading.error)")
            #expect(!leading.error.contains("no such"))
            let trailing = try run([verb, root.path, "Folder/Note", "--json"])
            #expect(leading.text == trailing.text, "\(verb) disagreed on flag position")
        }

        let tags = try run(["tags", root.path, "--json"])
        #expect(tags.status == 0)
    }

    @Test("read and find take a leading flag as a flag, not as the subject")
    func readAndFindTakeLeadingFlags() throws {
        let root = try vault(["Long.md": (1...20).map { "needle \($0)" }
            .joined(separator: "\n") + "\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let read = try run(["read", root.path, "--lines", "2-4", "Long.md"])
        #expect(read.status == 0, "\(read.error)")
        #expect(read.text.contains("needle 2"))
        #expect(!read.text.contains("needle 5\n"))

        let find = try run(["find", root.path, "--limit", "3", "needle"])
        #expect(find.status == 0, "\(find.error)")
        #expect(find.text.contains("showing 3 of 20"))

        let captured = try run(["capture", root.path, "--to", "Long.md", "a leading flag"])
        #expect(captured.status == 0, "\(captured.error)")
        let note = try String(
            contentsOf: root.appendingPathComponent("Long.md"), encoding: .utf8)
        #expect(note.contains("a leading flag"))
        // The flag's value must not have become part of the captured text.
        #expect(!note.contains("--to"))
        #expect(!note.contains("Long.md a leading flag"))
    }

    /// No ownership check, deliberately: the queue is the reader's and
    /// clearing it is a fair thing to ask. But two agents can share a vault,
    /// and one discarding what the other left for review should be legible
    /// rather than look like it was tidying up after itself.
    @Test("drop names who left the proposal it discarded")
    func dropNamesTheAuthor() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try readLog(having: ["Note.md"], in: root)

        #expect(try run(
            ["propose", root.path, "Note.md", "--summary", "tighten it",
             "--agent", "some-other-agent"],
            stdin: "one\n", readLog: log
        ).status == 0)

        let dropped = try run(["drop", root.path, "tighten-it"])
        #expect(dropped.status == 0)
        #expect(dropped.text.contains("some-other-agent"))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    // MARK: - capture

    /// The write is the one the Spotlight extension already makes. What is
    /// new is only that the command line can make it.
    @Test("capture appends a timestamped line to the inbox note")
    func captureAppendsToInbox() throws {
        let root = try vault(["Inbox.md": "# Inbox\n\n- 09:00 an earlier line\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["capture", root.path, "a thought worth keeping"])
        #expect(output.status == 0, "\(output.error)")
        #expect(output.text.contains("Inbox.md"))

        let inbox = try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        #expect(inbox.contains("a thought worth keeping"))
        // What was there is still there. The new line goes in under the
        // heading rather than at the end, which is the inbox's own order and
        // the same one Spotlight capture writes in.
        #expect(inbox.contains("an earlier line"))
        #expect(inbox.range(of: "a thought worth keeping")!.lowerBound
            < inbox.range(of: "an earlier line")!.lowerBound)
        #expect(inbox.hasPrefix("# Inbox"))
    }

    @Test("--to picks a different note")
    func captureToANamedNote() throws {
        let root = try vault(["Inbox.md": "# Inbox\n", "Log.md": "# Log\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["capture", root.path, "into the log", "--to", "Log.md"]).status == 0)
        let log = try String(contentsOf: root.appendingPathComponent("Log.md"), encoding: .utf8)
        #expect(log.contains("into the log"))
        let inbox = try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        #expect(!inbox.contains("into the log"))
    }

    /// The marker is the insertion cursor, so the next line lands above it and
    /// the ones after stay below.
    @Test("--daily writes to today's daily note")
    func captureDailyUsesTheMarker() throws {
        let root = try vault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["capture", root.path, "logged from the shell", "--daily"])
        #expect(output.status == 0, "\(output.error)")
        // Vault-relative, the way the inbox one reports. /tmp against
        // /private/tmp made these two disagree for the same vault.
        #expect(!output.text.contains(root.path), "the path came back absolute")
        let path = output.text.replacingOccurrences(of: "captured to ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = try String(
            contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        #expect(note.contains("logged from the shell"))
    }

    /// The promise "an agent never writes to your notes" survives a capture
    /// only if the reader can ask for one. Off by default, since adding a
    /// line cannot disturb what is already there, but the judgement is the
    /// reader's to make.
    @Test("A capture waits for review when the setting says so")
    func captureCanWaitForReview() throws {
        let root = try vault(["Inbox.md": "# Inbox\n\n- 09:00 an earlier line\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HeftCLIDefaults-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        AgentCaptureReviewPreference.set(true, in: defaults)

        let before = try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        let output = try run(
            ["capture", root.path, "held for review"], defaultsSuite: suite)
        #expect(output.status == 0, "\(output.error)")
        #expect(output.text.contains("proposed"))

        // Nothing written yet.
        #expect(try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8) == before)

        // And what waits is the note as it would be after the capture.
        let pending = try #require(ProposalStore.all(in: root).first)
        #expect(pending.notePath == "Inbox.md")
        #expect(pending.body.contains("held for review"))
        #expect(pending.body.contains("an earlier line"))
    }

    @Test("Off by default, so the line goes straight in")
    func captureWritesStraightAwayByDefault() throws {
        let root = try vault(["Inbox.md": "# Inbox\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["capture", root.path, "straight in"]).status == 0)
        #expect(ProposalStore.all(in: root).isEmpty)
        #expect(try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
            .contains("straight in"))
    }

    /// A day with no note yet still gets the template, or accepting the
    /// proposal would produce a note the immediate path never would.
    @Test("A reviewed daily capture carries the template too")
    func reviewedDailyCaptureCarriesTheTemplate() throws {
        let root = try vault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HeftCLIDefaults-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        AgentCaptureReviewPreference.set(true, in: defaults)

        let output = try run(
            ["capture", root.path, "logged", "--daily"], defaultsSuite: suite)
        #expect(output.status == 0, "\(output.error)")
        let pending = try #require(ProposalStore.all(in: root).first)
        #expect(pending.body.contains("logged"))
        // The heading ensureNote would have written.
        #expect(pending.body.hasPrefix("# "))
        #expect(pending.kind == .create)
    }

    /// `--to` names a note, and a note is inside the vault. Without this the
    /// argument went straight to the capture, so `--to "../file"` prepended a
    /// heading and a bullet to a file outside it. "It only adds" is a safety
    /// property of adding to a note; Markdown at the top of a shell profile
    /// breaks it as thoroughly as overwriting would.
    @Test("--to cannot leave the vault")
    func captureCannotEscapeTheVault() throws {
        let enclosing = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftEscape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: enclosing, withIntermediateDirectories: true)
        let root = enclosing.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: enclosing) }

        let outsider = enclosing.appendingPathComponent("victimrc")
        let precious = "export PATH=/usr/bin\n"
        try Data(precious.utf8).write(to: outsider)

        for escape in [
            "../victimrc", "../../victimrc", "Folder/../../victimrc",
            "./victimrc", "/etc/hosts", "//victimrc",
        ] {
            let refused = try run(["capture", root.path, "injected", "--to", escape])
            #expect(refused.status != 0, "`--to \(escape)` was accepted")
            #expect(refused.error.contains("inside the vault"))
        }
        // Untouched, byte for byte.
        #expect(try String(contentsOf: outsider, encoding: .utf8) == precious)
        // And nothing was created inside the vault under a mangled name.
        let inside = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(inside.isEmpty, "\(inside)")
    }

    @Test("A path inside the vault still works, extension or not")
    func captureToNestedPaths() throws {
        let root = try vault(["Inbox.md": "# Inbox\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["capture", root.path, "one", "--to", "Logs/Deep.md"]).status == 0)
        #expect(try run(["capture", root.path, "two", "--to", "Logs/NoExtension"]).status == 0)
        let deep = try String(
            contentsOf: root.appendingPathComponent("Logs/Deep.md"), encoding: .utf8)
        #expect(deep.contains("one"))
        // The normaliser adds the extension a note has.
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Logs/NoExtension.md").path))
    }

    @Test("Nothing to capture is refused, and the two targets cannot be combined")
    func captureRefusesNonsense() throws {
        let root = try vault(["Inbox.md": "# Inbox\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = try run(["capture", root.path])
        #expect(empty.status != 0)
        #expect(empty.error.contains("usage"))

        let both = try run(["capture", root.path, "text", "--daily", "--to", "Log.md"])
        #expect(both.status != 0)
        #expect(both.error.contains("pick one"))

        let unchanged = try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        #expect(unchanged == "# Inbox\n")
    }

    @Test("Several words are one line, not one capture each")
    func captureJoinsItsWords() throws {
        let root = try vault(["Inbox.md": "# Inbox\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["capture", root.path, "one", "two", "three"]).status == 0)
        let inbox = try String(
            contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        #expect(inbox.contains("one two three"))
        #expect(inbox.components(separatedBy: "\n- ").count == 2)
    }

    // MARK: - Machine-readable answers

    /// The tab-separated columns are fine to read and wrong to parse: a path
    /// can hold a quote, a colon or a tab, and nothing in the line says which.
    @Test("Every read verb can answer as JSON")
    func readVerbsAnswerAsJSON() throws {
        let root = try vault([
            "Folder/Note.md": "# Heading\n\n#tagged\n\nsee [[Other]] and [[Missing]]\n",
            "Other.md": "# Other\n\nsee [[Folder/Note]]\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        func parsed(_ arguments: [String]) throws -> Any {
            let output = try run(arguments)
            #expect(output.status == 0, "\(arguments.joined(separator: " ")): \(output.error)")
            let data = Data(output.text.utf8)
            return try #require(try? JSONSerialization.jsonObject(with: data))
        }

        let headings = try #require(try parsed(
            ["outline", root.path, "Folder/Note", "--json"]) as? [[String: Any]])
        #expect(headings.first?["text"] as? String == "Heading")
        #expect(headings.first?["line"] as? Int == 1)

        let links = try #require(try parsed(
            ["links", root.path, "Folder/Note", "--json"]) as? [[String: Any]])
        #expect(links.count == 2)
        #expect(links.contains { $0["target"] as? String == "Other" && $0["resolved"] as? Bool == true })
        #expect(links.contains { $0["target"] as? String == "Missing" && $0["resolved"] as? Bool == false })

        let backlinks = try #require(try parsed(
            ["backlinks", root.path, "Folder/Note", "--json"]) as? [[String: Any]])
        #expect(backlinks.first?["path"] as? String == "Other.md")

        let tags = try #require(try parsed(["tags", root.path, "--json"]) as? [[String: Any]])
        #expect(tags.contains { $0["tag"] as? String == "tagged" && $0["notes"] as? Int == 1 })

        let tagged = try #require(try parsed(["tags", root.path, "tagged", "--json"]) as? [[String: Any]])
        #expect(tagged.first?["path"] as? String == "Folder/Note.md")

        let files = try #require(try parsed(["files", root.path, "--json"]) as? [[String: Any]])
        #expect(files.count == 2)
    }

    /// A find in JSON has to carry the truncation, or the shape is honest and
    /// the answer still is not.
    @Test("find in JSON says what it withheld")
    func findJSONCarriesTheTruncation() throws {
        let many = (1...60).map { "needle \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Big.md": many])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle", "--json"])
        #expect(output.status == 0)
        let object = try #require(
            try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any])
        #expect(object["shown"] as? Int == 40)
        #expect(object["total"] as? Int == 60)
        #expect(object["truncated"] as? Bool == true)
        #expect((object["matches"] as? [[String: Any]])?.count == 40)
    }

    /// The reason for the flag, made concrete.
    @Test("A path with a quote in it survives the round trip")
    func awkwardPathsSurviveJSON() throws {
        let root = try vault([#"He said "hi".md"#: "# Quoted\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["files", root.path, "--json"])
        #expect(output.status == 0)
        let listed = try #require(
            try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [[String: Any]])
        #expect(listed.first?["path"] as? String == #"He said "hi".md"#)
    }

    // MARK: - Reading part of a note

    @Test("--lines returns the range asked for, and says what it is")
    func readLinesReturnsTheRange() throws {
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Long.md": body])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["read", root.path, "Long.md", "--lines", "40-45"])
        #expect(output.status == 0)
        #expect(output.text.contains("line 40\nline 41"))
        #expect(!output.text.contains("line 39\n"))
        #expect(!output.text.contains("line 46\n"))
        #expect(output.text.contains("lines 40-45 of 100"))
    }

    @Test("An open end runs to the end of the note")
    func readLinesOpenEnd() throws {
        let body = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Short.md": body])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["read", root.path, "Short.md", "--lines", "8-"])
        #expect(output.status == 0)
        #expect(output.text.contains("line 8\nline 9\nline 10"))
        #expect(!output.text.contains("line 7\n"))
    }

    @Test("A range that is not one is refused, and says the note's length")
    func readLinesRefusesNonsense() throws {
        let root = try vault(["Short.md": "a\nb\nc\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in ["abc", "10-2", "0-2", "99-200", "5"] {
            let output = try run(["read", root.path, "Short.md", "--lines", bad])
            #expect(output.status != 0, "--lines \(bad) was accepted")
            #expect(output.error.contains("has 3 lines"))
        }
    }

    /// The interaction that matters. If a part counted as a read, an agent
    /// could see forty lines of four hundred and then replace all four
    /// hundred, which is exactly what the guard exists to stop.
    @Test("A part does not count as having read the note")
    func partialReadDoesNotSatisfyTheGuard() throws {
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Long.md": body])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }

        #expect(try run(
            ["read", root.path, "Long.md", "--lines", "1-40"], readLog: log
        ).status == 0)
        let refused = try run(
            ["propose", root.path, "Long.md"], stdin: "replacement\n", readLog: log
        )
        #expect(refused.status != 0)
        #expect(refused.error.contains("has not been read"))

        // The whole note, and now it goes through.
        #expect(try run(["read", root.path, "Long.md"], readLog: log).status == 0)
        #expect(try run(
            ["propose", root.path, "Long.md"], stdin: "replacement\n", readLog: log
        ).status == 0)
    }

    @Test("The range arithmetic itself")
    func lineRangeArithmetic() {
        #expect(AgentCLI.lineRange("40-45", of: 100) == 39..<45)
        #expect(AgentCLI.lineRange("8-", of: 10) == 7..<10)
        #expect(AgentCLI.lineRange("-3", of: 10) == 0..<3)
        #expect(AgentCLI.lineRange("1-999", of: 10) == 0..<10)
        #expect(AgentCLI.lineRange("0-3", of: 10) == nil)
        #expect(AgentCLI.lineRange("5-2", of: 10) == nil)
        #expect(AgentCLI.lineRange("20-30", of: 10) == nil)
        #expect(AgentCLI.lineRange("abc", of: 10) == nil)
        #expect(AgentCLI.lineRange("5", of: 10) == nil)
    }

    // MARK: - rename

    /// The one command line verb that wrote to the vault the moment it was
    /// typed, and the widest-reaching one there is: a rename repoints every
    /// link that pointed at the old name. `propose --move` was already the
    /// reviewed form of the same operation.
    @Test("rename will not write without being asked twice")
    func renameNeedsAsking() throws {
        let root = try vault(["Note.md": "# Note\n", "Other.md": "see [[Note]]\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let refused = try run(["rename", root.path, "Note.md", "Renamed"])
        #expect(refused.status != 0)
        #expect(refused.error.contains("--move"))
        #expect(refused.error.contains("--now"))
        // Refusing has to mean refusing.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    @Test("--dry-run still reports without the extra asking")
    func renameDryRunStillWorks() throws {
        let root = try vault(["Note.md": "# Note\n", "Other.md": "see [[Note]]\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["rename", root.path, "Note.md", "Renamed", "--dry-run"])
        #expect(output.status == 0)
        #expect(output.text.contains("would rename"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    @Test("--now renames, and repoints the links as before")
    func renameNowStillRenames() throws {
        let root = try vault(["Note.md": "# Note\n", "Other.md": "see [[Note]]\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["rename", root.path, "Note.md", "Renamed", "--now"])
        #expect(output.status == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Renamed.md").path))
        let other = try String(
            contentsOf: root.appendingPathComponent("Other.md"), encoding: .utf8)
        #expect(other.contains("[[Renamed]]"))
    }

    // MARK: - Naming a note

    /// There were two resolvers, and they had drifted: `read` accepted
    /// `Folder/Note` and `outline` did not, so CLAUDE.md's own examples
    /// failed on any note that was not at the vault root.
    @Test("Every verb accepts every spelling of a note's name")
    func oneResolverForEverySpelling() throws {
        let root = try vault([
            "Folder/Note.md": "# Heading\n\nbody\n",
            "Root.md": "# Root\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        for spelling in ["Folder/Note.md", "Folder/Note", "./Folder/Note.md", "Note"] {
            for verb in ["read", "outline", "links", "backlinks"] {
                let output = try run([verb, root.path, spelling])
                #expect(output.status == 0, "`heft \(verb) . \(spelling)` was rejected")
            }
        }
    }

    @Test("A name that matches nothing is still refused")
    func unknownNamesAreStillRefused() throws {
        let root = try vault(["Root.md": "# Root\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        for spelling in ["Nope", "Nope.md", "Folder/Nope"] {
            let output = try run(["read", root.path, spelling])
            #expect(output.status != 0, "`\(spelling)` resolved to something")
        }
    }

    /// A folder path names one note; a bare name might name several. The exact
    /// spelling has to win, or adding a note somewhere else in the vault
    /// changes what an existing command resolves to.
    @Test("An exact path beats a bare name that collides with it")
    func exactPathBeatsBareName() throws {
        let root = try vault([
            "Heft/Heft.md": "# The subfolder one\n",
            "Heft.md": "# The root one\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = try run(["read", root.path, "Heft/Heft"])
        #expect(nested.status == 0)
        #expect(nested.text.contains("The subfolder one"))

        let top = try run(["read", root.path, "Heft.md"])
        #expect(top.status == 0)
        #expect(top.text.contains("The root one"))
    }

    // MARK: - find

    /// The failure this prevents is not slowness, it is confidence. A list cut
    /// at the limit with nothing said reads as the whole answer, so an agent
    /// answers about the 40 it saw and never learns of the rest.
    @Test("A truncated search says so, and says how much it withheld")
    func findSaysWhenItTruncates() throws {
        let many = (1...60).map { "needle on line \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Big.md": many])
        defer { try? FileManager.default.removeItem(at: root) }

        let capped = try run(["find", root.path, "needle"])
        #expect(capped.status == 0)
        #expect(capped.text.contains("showing 40 of 60 matching lines"))
        #expect(capped.text.contains("--limit 60"))
        #expect(capped.text.components(separatedBy: "Big.md:").count - 1 == 40)
    }

    @Test("--limit raises the ceiling, and then there is nothing to withhold")
    func findLimitRaisesTheCeiling() throws {
        let many = (1...60).map { "needle on line \($0)" }.joined(separator: "\n") + "\n"
        let root = try vault(["Big.md": many])
        defer { try? FileManager.default.removeItem(at: root) }

        let all = try run(["find", root.path, "needle", "--limit", "100"])
        #expect(all.status == 0)
        #expect(all.text.components(separatedBy: "Big.md:").count - 1 == 60)
        #expect(!all.text.contains("showing"))
    }

    @Test("A search well under the limit says nothing about limits")
    func findStaysQuietWhenComplete() throws {
        let root = try vault(["Small.md": "needle here\nand nothing else\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try run(["find", root.path, "needle"])
        #expect(output.status == 0)
        #expect(!output.text.contains("showing"))
    }

    @Test("A limit that is not a number is refused rather than ignored")
    func findRefusesNonsenseLimits() throws {
        let root = try vault(["Small.md": "needle\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in ["abc", "0", "-5"] {
            let output = try run(["find", root.path, "needle", "--limit", bad])
            #expect(output.status != 0, "--limit \(bad) was accepted")
            #expect(output.error.contains("positive whole number"))
        }
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

    /// The same hazard as a stale read, reached the other way round. Keyed on
    /// a baseline, the guard never fired here, so a whole body could replace
    /// lines the agent had never seen and nothing said a word.
    @Test("A note that was never read refuses a whole-body proposal")
    func unreadNoteIsRefused() throws {
        let root = try vault(["Note.md": "one\ntwo\nthree\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let refused = try run(["propose", root.path, "Note.md"], stdin: "replacement\n")
        #expect(refused.status != 0)
        #expect(refused.error.contains("has not been read"))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("Reading it first is the way through")
    func readingFirstAllowsIt() throws {
        let root = try vault(["Note.md": "one\ntwo\nthree\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)
        #expect(try run(
            ["propose", root.path, "Note.md"], stdin: "replacement\n", readLog: log
        ).status == 0)
        #expect(ProposalStore.all(in: root).count == 1)
    }

    /// A note with nothing in it, and a note that is not there at all, have
    /// nothing to lose. Refusing those would make creating a note impossible
    /// without first reading something that does not exist.
    @Test("A new or empty note still proposes without a read")
    func nothingToLoseProposesFreely() throws {
        let root = try vault(["Empty.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(["propose", root.path, "Empty.md"], stdin: "first words\n").status == 0)
        #expect(try run(["propose", root.path, "Brand New.md"], stdin: "a new note\n").status == 0)
        #expect(ProposalStore.all(in: root).count == 2)
    }

    /// --replace stays exempt whether or not the note was read: its anchors
    /// are resolved against the note as it is now, which is the stricter
    /// check, and requiring a read as well would make it useless for the
    /// small edit it exists for.
    @Test("--replace does not need a read either")
    func replaceNeedsNoRead() throws {
        let root = try vault(["Note.md": "alpha\nbeta\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try run(
            ["propose", root.path, "Note.md", "--replace"],
            stdin: #"[{"old": "beta", "new": "BETA"}]"#
        ).status == 0)
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

    /// Renaming a numbered series: v0.3 to v0.4, then v0.2 to v0.3. The
    /// second move's target is taken until the first is accepted, and a
    /// proposal is checked against the vault as the pending moves would
    /// leave it.
    @Test("A move into a path a pending move vacates is accepted for review; without that move it is refused")
    func chainedMoveIsAccepted() throws {
        let root = try vault(["v0.2.md": "next\n", "v0.3.md": "later\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let refused = try run(["propose", root.path, "v0.2.md", "--move", "v0.3.md"])
        #expect(refused.status != 0)
        #expect(refused.error.contains("already exists"))

        #expect(try run(["propose", root.path, "v0.3.md", "--move", "v0.4.md"]).status == 0)
        let chained = try run(["propose", root.path, "v0.2.md", "--move", "v0.3.md"])
        #expect(chained.status == 0, Comment(rawValue: chained.error))
        #expect(chained.text.contains("is taken until"))
        #expect(ProposalStore.all(in: root).filter { $0.kind == .move }.count == 2)
    }

    /// The rank belongs to the note: after `heft rename` the moved note keeps
    /// its place in `files --by-use`, and the old path has none.
    @Test("`heft rename` carries the note's rank to its new path")
    func renameCarriesTheRank() throws {
        let root = try vault(["Old.md": "x\n", "Other.md": "y\n"])
        let suite = "HeftCLIDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var seeded = Frecency()
        seeded.record("Old.md")
        seeded.record("Old.md")
        // Keyed the way the binary keys it: by the standardized vault path.
        defaults.set(seeded.encoded, forKey: "dev.stenglein.Heft.frecency.notes.\(root.standardizedFileURL.path)")
        defaults.synchronize()

        #expect(try run(["rename", root.path, "Old.md", "New.md", "--now"], defaultsSuite: suite).status == 0)
        let ranked = try run(["files", root.path, "--by-use", "--scores"], defaultsSuite: suite).text
        let lines = ranked.split(separator: "\n").map(String.init)
        #expect(lines.first?.contains("New.md") == true, Comment(rawValue: ranked))
        // Each line is a right-aligned score, two spaces, the path.
        let newScore = lines.first { $0.contains("New.md") }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? 0
        #expect(newScore > 0, Comment(rawValue: ranked))
    }

    @Test("Renaming a folder carries the rank of every note inside it")
    func folderRenameCarriesRanks() throws {
        let root = try vault(["Old/Inner.md": "x\n", "Other.md": "y\n"])
        let suite = "HeftCLIDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var seeded = Frecency()
        seeded.record("Old/Inner.md")
        defaults.set(seeded.encoded, forKey: "dev.stenglein.Heft.frecency.notes.\(root.standardizedFileURL.path)")
        defaults.synchronize()

        #expect(try run(["rename", root.path, "Old", "New", "--now"], defaultsSuite: suite).status == 0)
        let ranked = try run(["files", root.path, "--by-use", "--scores"], defaultsSuite: suite).text
        #expect(ranked.split(separator: "\n").first?.contains("New/Inner.md") == true, Comment(rawValue: ranked))
        let score = ranked.split(separator: "\n").map(String.init).first { $0.contains("New/Inner.md") }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? 0
        #expect(score > 0, Comment(rawValue: ranked))
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
        // Read, then moved away: a proposal at that path creates a note, and
        // the old read must not stand in its way.
        #expect(log.freshness(vault: vaultURL, relativePath: "A.md", current: nil) == .unread)
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

    @Test("Malformed --replace input says it could not be parsed, and why")
    func replaceReportsAParseFailure() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        // Exactly what zsh's `echo` produces from a two-line anchor: a real
        // newline inside a JSON string, which JSON does not allow.
        let broken = "[{\"old\": \"one\ntwo\", \"new\": \"x\"}]"
        let output = try run(["propose", root.path, "Note.md", "--replace"], stdin: broken)

        #expect(output.status != 0)
        // The old wording named only the shape it wanted, which reads as
        // "you sent the wrong fields" when the payload was not JSON at all.
        #expect(output.error.contains("could not parse"))
        #expect(output.error.contains("echo"))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    // MARK: - One proposal per note

    @Test("A second proposal on the same note is refused, and says how to replace it")
    func secondProposalIsRefused() throws {
        let root = try vault(["Note.md": "one\ntwo\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }
        // A whole body needs the note read first. That rule has its own test;
        // this one is about what happens once a proposal exists.
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)

        let first = try run(["propose", root.path, "Note.md", "--summary", "widen the intro"],
                            stdin: "one\ntwo\nthree\n", readLog: log)
        #expect(first.status == 0)

        let second = try run(["propose", root.path, "Note.md", "--summary", "something else"],
                             stdin: "one\nfour\n", readLog: log)
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
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }
        // A whole body needs the note read first. That rule has its own test;
        // this one is about what happens once a proposal exists.
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)

        #expect(try run(["propose", root.path, "Note.md", "--summary", "remove the image"],
                        stdin: "one\n", readLog: log).status == 0)
        let old = try #require(ProposalStore.all(in: root).first)

        let output = try run(
            ["propose", root.path, "Note.md", "--replacing", old.id,
             "--summary", "remove the whole quote block"],
            stdin: "\n", readLog: log
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
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }
        // A whole body needs the note read first. That rule has its own test;
        // this one is about what happens once a proposal exists.
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)

        #expect(try run(["propose", root.path, "Note.md", "--summary", "tighten the opening"],
                        stdin: "one\n", readLog: log).status == 0)
        #expect(try run(["propose", root.path, "Note.md", "--replacing", "tighten-the-opening",
                         "--summary", "tighten the opening"],
                        stdin: "two\n", readLog: log).status == 0)

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
        let log = try readLog(having: ["A.md", "B.md"], in: root)

        #expect(try run(["propose", root.path, "A.md", "--summary", "change a"],
                        stdin: "a2\n", readLog: log).status == 0)
        #expect(try run(["propose", root.path, "B.md", "--summary", "change b"],
                        stdin: "b2\n", readLog: log).status == 0)
        #expect(ProposalStore.all(in: root).count == 2)
    }

    @Test("A delete cannot be stacked on a pending edit to the same note either")
    func structuralProposalsCollideToo() throws {
        let root = try vault(["Note.md": "one\n"])
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeftCLIReads-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: log)
        }
        #expect(try run(["read", root.path, "Note.md"], readLog: log).status == 0)

        #expect(try run(["propose", root.path, "Note.md", "--summary", "rewrite it"],
                        stdin: "two\n", readLog: log).status == 0)
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

    @Test("A collision gives back the words the cut took, rather than a number")
    func collidingNamesGrowBackTheirTail() {
        func name(_ summary: String, taken: Set<String> = []) -> String {
            ProposalStore.identifier(summary: summary, noteName: "N.md", taken: taken)
        }

        // Five summaries written in one batch: a long shared opening, and the
        // part that says which is which past the 40-character cut.
        let first = name("Add a sample note for checking the callouts")
        #expect(first == "add-a-sample-note-for-checking-the")

        let second = name("Add a sample note for checking the tables", taken: [first])
        // Not `add-a-sample-note-for-checking-the-2`, which says nothing about
        // which of the two it is.
        #expect(second == "add-a-sample-note-for-checking-the-tables")
        #expect(!second.hasSuffix("-2"))

        // It grows by as little as it has to. A third that differs one word
        // earlier stops one word earlier.
        #expect(name("Add a sample note for checking tables", taken: [first, second])
            == "add-a-sample-note-for-checking-tables")

        // An uncollided name is untouched: growing is for collisions only.
        #expect(name("Add a sample note for checking the callouts")
            == "add-a-sample-note-for-checking-the")

        // Two identical summaries have nothing left to tell apart, so the
        // number is still the answer there.
        #expect(name("Tighten the opening", taken: ["tighten-the-opening"])
            == "tighten-the-opening-2")
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
        let log = try readLog(having: ["Note.md"], in: root)

        let proposed = try run(
            ["propose", root.path, "Note.md", "--summary", "Tighten the opening"],
            stdin: "two\n", readLog: log
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
        let log = try readLog(having: ["A.md", "B.md"], in: root)

        for note in ["A.md", "B.md"] {
            #expect(try run(
                ["propose", root.path, note, "--group", "Rename the concept"],
                stdin: "two\n", readLog: log
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
