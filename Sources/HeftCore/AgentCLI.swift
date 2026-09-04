import Foundation

/// The headless surface an agent talks to.
///
/// Heft is already a CLI before it is a window — `Main.swift` dispatches
/// `stats`, `daily` and `render` without starting the app — so the agent
/// integration is a few more verbs on the same entry point rather than a
/// separate binary, a daemon, or a port to connect to.
///
/// The important verb is `propose`. An agent that edits notes directly is
/// indistinguishable from the user's own typing an hour later, and there is
/// nothing left to review; `propose` writes to `.heft/proposals` instead and
/// lets the editor ask.
public enum AgentCLI {

    public static let verbs: Set<String> = [
        "propose", "proposals", "diff", "drop", "read", "find", "changes", "attachment",
    ]

    /// Returns true when it handled the arguments (and has exited).
    public static func run(_ arguments: [String]) -> Bool {
        guard let verb = arguments.first, verbs.contains(verb) else { return false }
        guard arguments.count > 1 else {
            fail("usage: heft \(verb) <vault> …")
        }
        let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        let rest = Array(arguments.dropFirst(2))
        warnIfGuideOutdated(root: root)

        switch verb {
        case "propose": propose(root: root, arguments: rest)
        case "proposals": list(root: root)
        case "diff": showDiff(root: root, arguments: rest)
        case "drop": drop(root: root, arguments: rest)
        case "read": read(root: root, arguments: rest)
        case "find": find(root: root, arguments: rest)
        case "changes": changes(root: root, arguments: rest)
        case "attachment": attachment(root: root, arguments: rest)
        default: return false
        }
        return true
    }

    /// Tells an agent when the vault's instructions are older than this binary.
    ///
    /// On stderr, so it never lands in the output a verb is being read for,
    /// and only when there is a guide that is genuinely behind: a vault that
    /// has never been set up is not the business of a command that already
    /// knows the verb it was called with.
    private static func warnIfGuideOutdated(root: URL) {
        guard case let .outdated(found) = AgentGuide.status(ofVaultAt: root) else { return }
        FileHandle.standardError.write(
            Data((AgentGuide.refreshAdvice(found: found, vaultPath: root.path) + "\n").utf8)
        )
    }

    // MARK: - Verbs

    /// `heft propose <vault> <note.md> [--summary s] [--agent a] [--from file]`
    ///
    /// The proposed body arrives on stdin, which is what makes this usable from
    /// an agent: it already has the whole new text in hand and does not have to
    /// express the change as a patch that might not apply.
    private static func propose(root: URL, arguments: [String]) {
        guard let notePath = arguments.first, !notePath.hasPrefix("--") else {
            fail("usage: heft propose <vault> <note.md> [--summary s] [--agent a] [--from file]")
        }
        let options = Options(arguments.dropFirst())
        let relative = normalized(notePath)

        var body: String
        if let from = options["from"] {
            guard let text = try? String(
                contentsOf: URL(fileURLWithPath: (from as NSString).expandingTildeInPath),
                encoding: .utf8
            ) else { fail("cannot read \(from)") }
            body = text
        } else {
            var input = ""
            while let line = readLine(strippingNewline: false) { input += line }
            body = input
        }
        guard !body.isEmpty else {
            fail("nothing on stdin: pipe the proposed note body in, or pass --from <file>")
        }

        let noteURL = root.appendingPathComponent(relative)
        var current = try? String(contentsOf: noteURL, encoding: .utf8)

        // `--replace` means the input is a list of anchored edits rather than
        // the note's new text, so a long note does not have to be restated to
        // change a line of it. Resolved here, against the note as it is now,
        // so a bad anchor is an error the agent sees at once.
        if options.flag("replace") {
            guard let existing = current else {
                fail("--replace needs an existing note to anchor against: \(relative) is new")
            }
            let edits: [AnchoredEdit]
            do {
                edits = try JSONDecoder().decode([AnchoredEdit].self, from: Data(body.utf8))
            } catch {
                fail("--replace expects JSON: [{\"old\": \"…\", \"new\": \"…\"}]")
            }
            guard !edits.isEmpty else { fail("--replace was given no edits") }
            do {
                body = try AnchoredEdit.apply(edits, to: existing)
            } catch {
                fail(error.localizedDescription)
            }
            current = existing
        }

        if let current, current == body {
            print("no change: \(relative) already reads that way")
            exit(0)
        }

        // A full-body proposal replaces the note, so it is only safe if the
        // agent saw the note it is replacing. `--replace` is exempt: its
        // anchors resolve against the note as it is now and fail if the text
        // it named has moved, which is a stricter check than this one.
        if !options.flag("replace"),
           case let .stale(readAt) = ReadLog.shared.freshness(
               vault: root, relativePath: relative, current: current
           ) {
            let formatter = ISO8601DateFormatter()
            fail("""
                \(relative) has changed since you read it at \(formatter.string(from: readAt)).
                Proposing the whole body now would revert whatever was typed in between.
                Run `heft changes "\(root.path)" "\(relative)"` to see what moved, \
                then read it again.
                """)
        }

        let summary = options["summary"]
        let proposal = Proposal(
            id: ProposalStore.identifier(
                summary: summary,
                noteName: (relative as NSString).lastPathComponent,
                taken: Set(ProposalStore.all(in: root).map(\.id))
            ),
            notePath: relative,
            base: current,
            body: body,
            agent: options["agent"] ?? "claude-code",
            summary: summary ?? ProposalStore.defaultSummary
        )
        do {
            try ProposalStore.write(proposal, in: root)
        } catch {
            fail("could not write the proposal: \(error.localizedDescription)")
        }

        // Recorded in the *agent's* index, never the reader's.
        //
        // Only on `propose`, which is the moment an agent decided a note
        // needed changing. Not on `read` or `find`: an agent reads twenty
        // notes to decide about one, so counting reads would rank the vault by
        // fan-out and mean nothing. This is also the only record that outlives
        // the proposal — once it is accepted, `.heft/proposals/` forgets it.
        MainActor.assumeIsolated {
            FrecencyStore.agentNotes(forVaultAt: root.standardizedFileURL.path).record(relative)
        }

        let diff = proposal.diff(against: current ?? "")
        print("proposed \(proposal.id)")
        print("note:    \(relative)\(current == nil ? " (new)" : "")")
        print("change:  +\(diff.addedLines) -\(diff.removedLines) in \(diff.hunks.count) hunk(s)")
        print("Waiting for review in Heft.")
        exit(0)
    }

    private static func list(root: URL) {
        let proposals = ProposalStore.all(in: root)
        guard !proposals.isEmpty else {
            print("no proposals pending")
            exit(0)
        }
        for proposal in proposals {
            let current = (try? String(
                contentsOf: root.appendingPathComponent(proposal.notePath), encoding: .utf8
            )) ?? ""
            let diff = proposal.diff(against: current)
            let stale = proposal.isStale(against: current) ? "  [note changed since]" : ""
            print("\(proposal.id)  \(proposal.notePath)  +\(diff.addedLines) -\(diff.removedLines)  \(proposal.agent)\(stale)")
            print("    \(proposal.summary)")
        }
        exit(0)
    }

    /// Unified-diff-ish output, so the agent can check that what it proposed is
    /// what it meant before telling the user to go and look.
    private static func showDiff(root: URL, arguments: [String]) {
        let proposal = resolve(arguments.first, in: root, verb: "diff")
        let current = (try? String(
            contentsOf: root.appendingPathComponent(proposal.notePath), encoding: .utf8
        )) ?? ""
        let diff = proposal.diff(against: current)
        print("--- \(proposal.notePath)")
        print("+++ \(proposal.notePath)  (proposed by \(proposal.agent))")
        for hunk in diff.hunks {
            print("@@ line \(hunk.originalRange.lowerBound + 1) @@")
            for line in hunk.leading { print(" \(line)") }
            for line in hunk.removed { print("-\(line)") }
            for line in hunk.added { print("+\(line)") }
            for line in hunk.trailing { print(" \(line)") }
        }
        exit(0)
    }

    private static func drop(root: URL, arguments: [String]) {
        let proposal = resolve(arguments.first, in: root, verb: "drop")
        ProposalStore.remove(proposal.id, in: root)
        print("dropped \(proposal.id)")
        exit(0)
    }

    /// Reading a note by name rather than by path, the way a wikilink does, so
    /// an agent can work from what the vault calls things.
    private static func read(root: URL, arguments: [String]) {
        guard let name = arguments.first else { fail("usage: heft read <vault> <note>") }
        let relative = resolveNote(named: name, in: root)
        let noteURL = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else {
            fail("could not read \(relative)")
        }
        // Recorded before it is written, so what `propose` later holds the
        // agent to is exactly the bytes the agent was given.
        ReadLog.shared.record(text, vault: root, relativePath: relative)

        // Written rather than printed. A note already ending in a newline came
        // back with two, so every read/propose round trip grew it by a blank
        // line — and an agent has no way to tell which newline was the file's.
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }

    /// `heft changes <vault> <note>` — what moved since this agent last read it.
    ///
    /// Nothing could answer this before. `heft diff` takes a proposal id, and
    /// re-reading gives the current text without saying which part of it is
    /// new, so an agent that had been told its proposal was stale had no way
    /// to find out what it had missed short of holding the old text itself.
    private static func changes(root: URL, arguments: [String]) {
        guard let name = arguments.first else { fail("usage: heft changes <vault> <note>") }
        let relative = resolveNote(named: name, in: root)
        guard let entry = ReadLog.shared.last(vault: root, relativePath: relative) else {
            fail("nothing recorded for \(relative): run `heft read` first")
        }
        let current = (try? String(
            contentsOf: root.appendingPathComponent(relative), encoding: .utf8
        )) ?? ""
        let diff = NoteDiff.between(original: entry.text, proposed: current)
        guard !diff.isEmpty else {
            print("no change since you read \(relative)")
            exit(0)
        }
        let formatter = ISO8601DateFormatter()
        print("--- \(relative)  (as you read it, \(formatter.string(from: entry.readAt)))")
        print("+++ \(relative)  (now)")
        for hunk in diff.hunks {
            print("@@ line \(hunk.originalRange.lowerBound + 1) @@")
            for line in hunk.leading { print(" \(line)") }
            for line in hunk.removed { print("-\(line)") }
            for line in hunk.added { print("+\(line)") }
            for line in hunk.trailing { print(" \(line)") }
        }
        exit(0)
    }

    /// `heft attachment <vault> <note> [filename]` — where a file attached to
    /// that note goes, and what to write in the note to point at it.
    ///
    /// `AttachmentRules` already decides this for a paste in the editor, and
    /// nothing on the command line could reach it: an agent handed a file had
    /// to guess. `heft config` reports the raw Obsidian setting, which is one
    /// of five rules and frequently not the one that answers — a vault that
    /// keeps figures in three differently-named folders is the case the rules
    /// exist for.
    ///
    /// It answers and does not write. Copying the file is the caller's, and a
    /// verb that moved files into a vault would be the one thing proposals
    /// exist to prevent.
    private static func attachment(root: URL, arguments: [String]) {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            fail("usage: heft attachment <vault> <note> [filename] [--json]")
        }
        let options = Options(arguments.dropFirst())
        let filename = arguments.dropFirst().first { !$0.hasPrefix("--") }

        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        let relative = resolveNote(named: name, in: root)
        let noteURL = root.appendingPathComponent(relative)
        let settings = ObsidianSettings.load(vaultRoot: root)
        let resolver = AttachmentDestination(
            rules: AttachmentPlan.stored(in: HeftDefaults.shared).rules,
            vaultRoot: root,
            settings: settings
        )
        let chosen = resolver.resolve(
            noteURL: noteURL,
            learned: index.attachmentDestination(
                near: AttachmentDestination.folder(of: noteURL, in: root)
            )
        )
        let directory = chosen.folder.isEmpty
            ? root : root.appendingPathComponent(chosen.folder, isDirectory: true)
        let target = filename.map { directory.appendingPathComponent($0) }
        let link = target.map { resolver.link(to: $0, from: noteURL) }

        if options.flag("json") {
            var payload: [String: Any] = [
                "note": relative,
                "folder": chosen.folder,
                "rule": chosen.rule.id,
                "exists": !chosen.needsCreating,
                "mayCreate": chosen.rule.mayCreate,
                "path": directory.path,
                "wikilinks": settings.useWikilinks,
            ]
            if let target { payload["file"] = target.path }
            if let link { payload["link"] = link }
            if let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }

        print("note:    \(relative)")
        print("folder:  \(chosen.folder.isEmpty ? "(vault root)" : chosen.folder)")
        print("rule:    \(chosen.rule.id)")
        print("path:    \(directory.path)")
        if chosen.needsCreating {
            print(chosen.rule.mayCreate
                ? "note:    that folder does not exist yet and would be created"
                : "note:    that folder does not exist, so the vault root would be used")
        }
        if let target { print("file:    \(target.path)") }
        if let link { print("link:    \(link)") }
        exit(0)
    }

    private static func find(root: URL, arguments: [String]) {
        guard !arguments.isEmpty else { fail("usage: heft find <vault> <query>") }
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        let result = ContentSearch.run(
            notes: index.notes, query: arguments.joined(separator: " "), limit: 40
        )
        guard !result.matches.isEmpty else {
            print("no matches")
            exit(0)
        }
        for match in result.matches {
            print("\(match.note.relativePath):\(match.line)  \(match.preview)")
        }
        exit(0)
    }

    // MARK: - Helpers

    /// The one proposal an id names, or an exit. `ProposalStore.match` decides;
    /// this only turns each answer into a message and a status.
    private static func resolve(_ id: String?, in root: URL, verb: String) -> Proposal {
        let proposals = ProposalStore.all(in: root)
        switch ProposalStore.match(id, among: proposals) {
        case let .one(found):
            return proposals.first { $0.id == found }!
        case .missing:
            fail("usage: heft \(verb) <vault> <proposal-id>")
        case let .unknown(given):
            fail("no such proposal: \(given)")
        case let .ambiguous(candidates):
            fail("that names \(candidates.count) proposals: "
                + candidates.joined(separator: ", "))
        }
    }

    /// The vault-relative path a name refers to, resolved the way a wikilink
    /// resolves: a path, or a bare note name. `read` and `changes` both go
    /// through it so that a name means the same thing to each.
    private static func resolveNote(named name: String, in root: URL) -> String {
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        let wanted = normalized(name)
        guard let found = index.notes.first(where: {
            $0.relativePath == wanted || $0.name == name || $0.name == note(name)
        }) else {
            fail("no such note: \(name)")
        }
        return found.relativePath
    }

    /// Vault-relative, always with the extension a note actually has on disk.
    private static func normalized(_ path: String) -> String {
        var value = path
        if value.hasPrefix("./") { value.removeFirst(2) }
        return value.hasSuffix(".md") ? value : value + ".md"
    }

    private static func note(_ name: String) -> String {
        name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// `--key value` pairs. Small enough not to want an argument parser, and a
    /// dependency here would be a dependency in the app.
    private struct Options {
        private var values: [String: String] = [:]
        private var flags: Set<String> = []

        init(_ arguments: ArraySlice<String>) {
            let tokens = Array(arguments)
            var index = 0
            while index < tokens.count {
                guard tokens[index].hasPrefix("--") else { index += 1; continue }
                let key = String(tokens[index].dropFirst(2))
                // A bare flag must not eat the option after it: `--replace
                // --summary x` is a flag and an option, not a flag valued
                // "--summary".
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    values[key] = tokens[index + 1]
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            }
        }

        subscript(key: String) -> String? { values[key] }
        func flag(_ key: String) -> Bool { flags.contains(key) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
