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
        "capture", "search", "chats",
    ]

    /// The folder an agent asked from Heft's search bar is limited to,
    /// vault-relative, set by Heft in the agent's environment. Reading,
    /// searching and proposing stay inside it; outside, a note does not
    /// exist as far as the agent can tell.
    public static let scopeVariable = "HEFT_AGENT_SCOPE"

    /// Set by Heft for a run asked from its search bar, where every change
    /// is a card in the chat: a capture waits for review there, whatever
    /// the setting says for agents run by hand.
    public static let askVariable = "HEFT_AGENT_ASK"

    static var isAsked: Bool { ProcessInfo.processInfo.environment[askVariable] == "1" }

    /// Who a proposal is from when `--agent` does not say: the chat that
    /// asked, when Heft's search bar ran it, so its proposals are told apart
    /// from another chat's running at the same time.
    public static let agentNameVariable = "HEFT_AGENT_NAME"

    static var defaultAgent: String {
        let named = ProcessInfo.processInfo.environment[agentNameVariable] ?? ""
        return named.isEmpty ? "claude-code" : named
    }

    static var agentScope: String? {
        guard let scope = ProcessInfo.processInfo.environment[scopeVariable] else { return nil }
        let cleaned = NewNoteLocation.normalised(scope)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Whether a vault-relative path is inside `scope`; everything is when
    /// there is none. A `..` anywhere is outside: `Work/../Home` starts with
    /// the folder and climbs out of it.
    public static func isInScope(_ relative: String, scope: String?) -> Bool {
        guard let scope else { return true }
        guard !relative.split(separator: "/").contains("..") else { return false }
        return relative == scope || relative.hasPrefix(scope + "/")
    }

    private static func requireInScope(_ relative: String, root: URL) {
        guard !isVisible(relative, in: root) else { return }
        fail("\(relative) is outside \(agentScope ?? "the vault"), "
            + "the \(agentScope == nil ? "vault" : "folder") this question is limited to")
    }

    /// The vault an agent asked from Heft is limited to, set beside the
    /// scope. Without it every verb took whatever vault it was handed, so a
    /// run could read any folder on the disk by naming it as a vault.
    public static let vaultVariable = "HEFT_AGENT_VAULT"

    static var pinnedVault: URL? {
        guard let path = ProcessInfo.processInfo.environment[vaultVariable], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// The real path a pinned run is kept inside: its folder, or its vault.
    /// Nil when nothing is pinned.
    public static var pinnedBoundary: String? {
        guard let vault = pinnedVault else { return nil }
        return realPath(agentScope.map { vault.appendingPathComponent($0) } ?? vault)
    }

    /// Where a path really is: symlinks followed, `/var` as `/private/var`,
    /// and the case the disk has. A part that does not exist yet keeps its
    /// spelling after the real path of the part that does.
    public static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + missing.reversed()).joined(separator: "/")
            }
            guard existing.path != "/" else { return url.standardizedFileURL.path }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
    }

    static func isInside(_ path: String, boundary: String) -> Bool {
        path == boundary || path.hasPrefix(boundary == "/" ? "/" : boundary + "/")
    }

    /// Whether a vault-relative path is one this run may see: inside its
    /// scope by name, and, when pinned, inside it on disk, so a symlink in
    /// the folder that points out of it does not carry a read there.
    public static func isVisible(_ relative: String, in root: URL) -> Bool {
        guard isInScope(relative, scope: agentScope) else { return false }
        guard let boundary = pinnedBoundary else { return true }
        guard !relative.split(separator: "/").contains("..") else { return false }
        return isInside(realPath(root.appendingPathComponent(relative)), boundary: boundary)
    }

    /// The arguments a run Heft pinned to a vault may go on with, or an
    /// exit. Checked before any verb runs, so no verb can forget it: the
    /// verb must be one the run's own flags allow, and the vault, however
    /// it is spelled, must be the pinned one, which then stands in for it.
    /// Unpinned, the arguments come back as they were.
    public static func pinned(_ arguments: [String]) -> [String] {
        guard let vault = pinnedVault, let verb = arguments.first else { return arguments }
        let verbs = agentScope == nil ? AgentInvocation.heftVerbs : AgentInvocation.scopedHeftVerbs
        guard verbs.contains(verb) else {
            fail("\(verb) is not one of the verbs this question may use: "
                + verbs.joined(separator: ", "))
        }
        guard arguments.count > 1 else { return arguments }
        let named = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        guard realPath(named) == realPath(vault) else {
            fail("\(arguments[1]) is not this question's vault, \(vault.path)")
        }
        var pinned = arguments
        pinned[1] = vault.path
        return pinned
    }

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
        case "capture": capture(root: root, arguments: rest)
        case "search": search(root: root, arguments: rest)
        case "chats": chats(root: root, arguments: rest)
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
            fail("usage: heft propose <vault> <note.md> [--summary s] [--agent a] [--from file]"
                + "\n       heft propose <vault> <path> --delete [--summary s]"
                + "\n       heft propose <vault> <path> --move <new path> [--summary s]"
                + "\n       heft propose <vault> <note.md> --replacing <id> …")
        }
        let options = Options(arguments.dropFirst())
        let relative = normalized(notePath)
        requireInScope(relative, root: root)
        // Accepting writes the vault root joined with this path, so a `..`
        // part would write outside the vault, scope or no scope.
        guard !relative.split(separator: "/").contains("..") else {
            fail("\(relative) climbs out of the vault: a note path stays inside the vault")
        }
        if let destination = options["move"] {
            requireInScope(NewNoteLocation.normalised(destination), root: root)
        }

        // Deleting and moving are facts about the tree rather than about a
        // note's text, so neither reads a body and neither has hunks to
        // answer. They are here rather than under verbs of their own because
        // `propose` is the one word for "ask, do not do", and an agent that
        // has learnt it should not have to learn two more.
        if options.flag("delete") || options["move"] != nil {
            proposeStructural(root: root, path: notePath, options: options)
        }

        // Before stdin is read, so a collision costs nothing to discover.
        let replaced = replacement(for: relative, root: root, options: options)

        var body: String
        if let from = options["from"] {
            let source = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
            // Read by `heft`, not by the agent, so the agent's own limits
            // never saw it: `--from ../Home/Secret.md` and then `diff`
            // printed a file from outside the folder, or the disk.
            if let boundary = pinnedBoundary, !isInside(realPath(source), boundary: boundary) {
                fail("\(from) is outside \(agentScope ?? "the vault"), what this question is limited to")
            }
            guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                fail("cannot read \(from)")
            }
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
                edits = try AnchoredEdit.parse(body)
            } catch {
                // Naming the parse failure, not only the shape it wanted.
                // "expects JSON" reads as "you sent the wrong fields" when
                // what actually happened is that the payload was not JSON at
                // all, and the usual cause is a shell: zsh's `echo` expands a
                // \n inside single quotes into a real newline, and JSON has no
                // literal newlines inside strings. So the guide's own one-liner
                // breaks the moment an anchor spans two lines.
                fail("""
                    --replace could not parse its edits: \(error.localizedDescription)
                    It expects [{"old": "…", "new": "…"}], or plain blocks: a line \
                    `\(AnchoredEdit.oldMarker)`, the text, a line `\(AnchoredEdit.newMarker)`, its replacement.
                    If an anchor spans lines, `echo` is the usual culprit: it turns \\n \
                    inside the string into a real newline, which JSON does not allow. \
                    Write the JSON to a file and pipe it in, or use a quoted heredoc.
                    """)
            }
            guard !edits.isEmpty else { fail("--replace was given no edits") }
            do {
                body = try AnchoredEdit.apply(edits, to: existing)
            } catch {
                fail(error.localizedDescription)
            }
            current = existing
        }

        // A whole body arrives in `\n` from an agent, so in a Windows note
        // every line would read as changed and accepting it would rewrite
        // the note. `--replace` has done this edit by edit already.
        if !options.flag("replace"), let current, !current.isEmpty {
            body = LineEnding(of: current).applied(to: body)
        }

        if let current, current == body {
            print("no change: \(relative) already reads that way")
            exit(0)
        }

        // A full-body proposal replaces the note, so it is only safe if the
        // agent saw the note it is replacing. `--replace` is exempt: its
        // anchors resolve against the note as it is now and fail if the text
        // it named has moved, which is a stricter check than this one.
        if !options.flag("replace") {
            let formatter = ISO8601DateFormatter()
            switch ReadLog.shared.freshness(
                vault: root, relativePath: relative, current: current
            ) {
            case let .stale(readAt):
                fail("""
                    \(relative) has changed since you read it at \(formatter.string(from: readAt)).
                    Proposing the whole body now would revert whatever was typed in between.
                    Run `heft changes "\(root.path)" "\(relative)"` to see what moved, \
                    then read it again.
                    """)
            // Never read at all, and there is something there to lose. The
            // refusal is the same one as for a stale read and for the same
            // reason: a whole body replaces every line, including the ones
            // that were never seen. A note that does not exist yet, or one
            // that is empty, has nothing to lose and is left alone.
            case .unread where !(current ?? "").isEmpty:
                fail("""
                    \(relative) has not been read, and a whole-body proposal replaces \
                    every line of it.
                    Run `heft read "\(root.path)" "\(relative)"` first, \
                    or send anchored edits with --replace, which are checked \
                    against the note as it is now.
                    """)
            case .unread, .fresh:
                break
            }
        }

        let summary = options["summary"]
        let proposal = Proposal(
            id: ProposalStore.identifier(
                summary: summary,
                noteName: (relative as NSString).lastPathComponent,
                taken: taken(in: root, freeing: replaced)
            ),
            notePath: relative,
            base: current,
            body: body,
            agent: options["agent"] ?? defaultAgent,
            summary: summary ?? ProposalStore.defaultSummary,
            kind: current == nil ? .create : .edit,
            group: options["group"].map { Proposal.Group(summary: $0) }
        )
        do {
            try ProposalStore.write(proposal, in: root)
        } catch {
            fail("could not write the proposal: \(error.localizedDescription)")
        }
        retire(replaced, replacedBy: proposal, in: root)

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
        print("change:  +\(diff.addedLines) -\(diff.removedLines) in \(diff.hunks.count) hunk\(VaultOperations.plural(diff.hunks.count))")
        print("Waiting for review in Heft.")
        exit(0)
    }

    /// A delete or a move. Neither reads stdin: there is no new body to give.
    private static func proposeStructural(root: URL, path: String, options: Options) {
        let existing = VaultScanner.scan(root: root).flattened()
        // Anything in the vault, not only notes: an attachment is as much a
        // thing to move as a note is, and `rename` already treats them alike.
        guard let item = existing.first(where: {
            $0.relativePath == path || $0.relativePath == normalized(path)
        }) else {
            fail("no such file in the vault: \(path)")
        }

        let isMove = options["move"] != nil
        var destination: String?
        if let requested = options["move"] {
            let cleaned = NewNoteLocation.normalised(requested)
            guard !cleaned.isEmpty else { fail("--move needs a destination path") }
            if existing.contains(where: { $0.relativePath == cleaned }) {
                // Taken now, but a pending move takes that file away: the
                // chain a numbered series is renamed by, v0.3 to v0.4 and
                // then v0.2 to v0.3. Accepted for review against the vault
                // as the pending moves would leave it; the review centre
                // refuses to apply it while the path is still taken.
                let vacating = ProposalStore.all(in: root).first {
                    $0.kind == .move && $0.notePath == cleaned && $0.destination != nil
                }
                guard let vacating else { fail("\(cleaned) already exists") }
                print("note:    \(cleaned) is taken until \(vacating.id) is accepted; accept that move first")
            }
            // Said here as well as in the review sheet: an agent that hears
            // it while proposing can pick somewhere else, rather than a
            // person finding out while deciding.
            let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))
            if daily.leavesDailyFolder(item.relativePath, movingTo: cleaned) {
                print("note:    \(daily.departureNote(for: item.relativePath))")
            }
            destination = cleaned
        }

        let replaced = replacement(for: item.relativePath, root: root, options: options)
        let summary = options["summary"]
        let described = summary ?? (isMove
            ? Proposal.describeMove(from: item.relativePath, to: destination ?? "")
            : "Delete \(item.relativePath)")
        let proposal = Proposal(
            id: ProposalStore.identifier(
                summary: described,
                noteName: (item.relativePath as NSString).lastPathComponent,
                taken: taken(in: root, freeing: replaced)
            ),
            notePath: item.relativePath,
            base: nil,
            body: "",
            agent: options["agent"] ?? defaultAgent,
            summary: described,
            kind: isMove ? .move : .delete,
            destination: destination,
            group: options["group"].map { Proposal.Group(summary: $0) }
        )
        do {
            try ProposalStore.write(proposal, in: root)
        } catch {
            fail("could not write the proposal: \(error.localizedDescription)")
        }
        retire(replaced, replacedBy: proposal, in: root)
        MainActor.assumeIsolated {
            FrecencyStore.agentNotes(forVaultAt: root.standardizedFileURL.path)
                .record(item.relativePath)
        }
        print("proposed \(proposal.id)")
        print("change:  \(proposal.headline)")
        if let group = proposal.group { print("group:   \(group.summary)") }
        print("Waiting for review in Heft.")
        exit(0)
    }

    /// The proposals a run may see: in one limited to a folder, those for
    /// a path inside it, as a note outside does not exist to it. `diff`
    /// would otherwise print an outside note's lines as a hunk's context.
    private static func visibleProposals(in root: URL) -> [Proposal] {
        ProposalStore.all(in: root).filter { isVisible($0.notePath, in: root) }
    }

    private static func list(root: URL) {
        let pending = ProposalStore.sort(visibleProposals(in: root))
        guard !pending.isEmpty else {
            print("no proposals pending")
            exit(0)
        }
        for group in pending.groups {
            print("group \(group.id)  \(group.summary)  (\(group.proposals.count) changes)")
            for proposal in group.proposals { describe(proposal, in: root, indent: "  ") }
        }
        for proposal in pending.edits { describe(proposal, in: root, indent: "") }
        for proposal in pending.structural { describe(proposal, in: root, indent: "") }
        exit(0)
    }

    private static func describe(_ proposal: Proposal, in root: URL, indent: String) {
        guard !proposal.isStructural else {
            print("\(indent)\(proposal.id)  \(proposal.headline)  \(proposal.agent)")
            print("\(indent)    \(proposal.summary)")
            return
        }
        let current = (try? String(
            contentsOf: root.appendingPathComponent(proposal.notePath), encoding: .utf8
        )) ?? ""
        let diff = proposal.diff(against: current)
        let stale = proposal.isStale(against: current) ? "  [note changed since]" : ""
        let new = proposal.kind == .create ? " (new)" : ""
        print("\(indent)\(proposal.id)  \(proposal.notePath)\(new)  "
            + "+\(diff.addedLines) -\(diff.removedLines)  \(proposal.agent)\(stale)")
        print("\(indent)    \(proposal.summary)")
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
        // The whole id, not a prefix: this is the one verb that cannot be
        // undone, and `heft proposals` prints the id ready to copy.
        let proposal = resolve(arguments.first, in: root, verb: "drop", exactly: true)
        ProposalStore.remove(proposal.id, in: root)
        // Who left it, not only which one went. There is no ownership check
        // and there should not be: the queue is the reader's, and clearing
        // it is a fair thing to ask. But two agents can share a vault, and
        // one discarding what the other left for review should be legible in
        // the transcript rather than indistinguishable from tidying its own.
        print("dropped \(proposal.id), proposed by \(proposal.agent)")
        exit(0)
    }

    /// Reading a note by name rather than by path, the way a wikilink does, so
    /// an agent can work from what the vault calls things.
    private static func read(root: URL, arguments: [String]) {
        let options = Options(arguments[...])
        // The note, wherever it was written relative to the flags.
        guard let name = CommandLineSpec.split(arguments, forVerb: "read").positional.first else {
            fail("usage: heft read <vault> <note> [--lines N-M]")
        }
        let relative = resolveNote(named: name, in: root)
        let noteURL = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else {
            fail("could not read \(relative)")
        }

        if let asked = options["lines"] {
            let lines = NoteDiff.lines(of: text)
            guard let range = lineRange(asked, of: lines.count) else {
                fail("""
                    --lines takes a range like 40-80, or 40- for everything from there.
                    \(relative) has \(lines.count) line\(lines.count == 1 ? "" : "s").
                    """)
            }
            // Deliberately no ReadLog entry. A part is not the note, and
            // recording one would let a whole-body proposal be built on
            // having seen forty lines of four hundred, which is the exact
            // thing the read-before-propose guard exists to prevent.
            let shown = lines[range].joined(separator: "\n") + "\n"
            FileHandle.standardOutput.write(Data(shown.utf8))
            let last = range.upperBound
            if last < lines.count || range.lowerBound > 0 {
                print("""
                    — lines \(range.lowerBound + 1)-\(last) of \(lines.count). \
                    A part does not count as having read the note: `propose` still \
                    wants the whole thing read, or use --replace.
                    """)
            }
            exit(0)
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

    /// `40-80`, `40-` or `-80`, as a 0-based half-open range, or nil when it
    /// is not a range or falls outside the note.
    static func lineRange(_ text: String, of count: Int) -> Range<Int>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, count > 0 else { return nil }
        let first = parts[0].isEmpty ? 1 : Int(parts[0])
        let last = parts[1].isEmpty ? count : Int(parts[1])
        guard let first, let last, first >= 1, last >= first, first <= count else { return nil }
        return (first - 1)..<min(last, count)
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

        let index = VaultIndex.open(vaultAt: root)
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

    static let findLimit = 40

    private static func find(root: URL, arguments: [String]) {
        let options = Options(arguments[...])
        let words = CommandLineSpec.split(arguments, forVerb: "find").positional
        guard !words.isEmpty else { fail("usage: heft find <vault> <query> [--limit N]") }

        var limit = findLimit
        if let asked = options["limit"] {
            guard let value = Int(asked), value > 0 else {
                fail("--limit takes a positive whole number, not \(asked)")
            }
            limit = value
        }

        let index = VaultIndex.open(vaultAt: root)
        let result = ContentSearch.run(
            notes: index.notes.filter { isVisible($0.relativePath, in: root) },
            query: words.joined(separator: " "), limit: limit
        )
        guard !result.matches.isEmpty else {
            print("no matches")
            exit(0)
        }
        // Which notes, rather than which lines. The scan already counted this
        // for the truncation notice; without the flag it knows the answer and
        // has no way to say it, so choosing what to open meant paging through
        // matched lines and inferring.
        if options.flag("files") {
            let listed = Array(result.tallies.prefix(limit))
            if options.flag("json") {
                JSONOutput.emit(listed.map {
                    ["path": $0.path, "lines": $0.lines, "occurrences": $0.occurrences]
                })
            }
            for tally in listed {
                print("\(tally.lines)\t\(tally.occurrences)\t\(tally.path)")
            }
            if result.tallies.count > listed.count {
                print("""
                    — showing \(listed.count) of \(result.tallies.count) notes. \
                    Pass --limit \(result.tallies.count) for all of them.
                    """)
            }
            exit(0)
        }

        if options.flag("json") {
            JSONOutput.emit([
                "matches": result.matches.map {
                    [
                        "path": $0.note.relativePath, "line": $0.line,
                        "preview": $0.preview, "occurrences": $0.occurrences,
                    ]
                },
                "shown": result.matches.count,
                "total": result.totalMatches,
                "notes": result.matchedNotes,
                "truncated": result.isTruncated,
            ])
        }
        for match in result.matches {
            print("\(match.note.relativePath):\(match.line)  \(match.preview)")
        }
        // Said on stdout, and only when something was withheld. A list that
        // stops at the limit and says nothing reads as the whole answer, and
        // an agent that believes it answers confidently about the 40 it saw
        // and never learns about the other 260.
        if result.isTruncated {
            print("""
                — showing \(result.matches.count) of \(result.totalMatches) matching lines \
                in \(result.matchedNotes) notes. Narrow the query, or pass \
                --limit \(result.totalMatches).
                """)
        }
        exit(0)
    }

    /// Appends one line to the inbox note, or to today's daily note.
    ///
    /// The only verb here that writes to the vault without a proposal, and it
    /// is the same write the Spotlight extension has always made: the app's
    /// own capture calls exactly this. Adding a line at a marker touches
    /// nothing that was already there, which is the test `daily` passes and
    /// `rename` did not.
    ///
    /// It is here because it is the most frequent thing an agent has to do
    /// and was the most expensive: logging one line meant reading the whole
    /// note and proposing a whole body back, and since the read guard, having
    /// read it first as well.
    /// Notes, folders and tags by name, ranked as the search bar ranks
    /// them: a prefix above a word start above a match inside, and use and
    /// pins nudging within that. What is inside the notes is `find`.
    private static func search(root: URL, arguments: [String]) {
        let options = Options(arguments[...])
        let words = CommandLineSpec.split(arguments, forVerb: "search").positional
        let query = words.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("usage: heft search <vault> <query> [--kinds notes,folders,tags]")
        }
        let limit = options["limit"].flatMap(Int.init) ?? 30
        let kinds = Set((options["kinds"] ?? "notes,folders,tags").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let index = VaultIndex.open(vaultAt: root)
        let frecency = FrecencyStore.notes(forVaultAt: root.standardizedFileURL.path)
        let pinned = Set(Pins.load(from: root).values(of: .note))
        var found: [(kind: String, name: String, score: Int)] = []
        if kinds.contains("notes") {
            for hit in index.scoredSearch(
                query, limit: limit, familiarity: { frecency.score($0.relativePath) },
                pinned: { pinned.contains($0.relativePath) },
                including: { isVisible($0.relativePath, in: root) }
            ) {
                found.append(("note", hit.note.relativePath, hit.score))
            }
        }
        if kinds.contains("folders") {
            var folders = Set<String>()
            for note in index.notes {
                var parts = note.relativePath.split(separator: "/").dropLast()
                while !parts.isEmpty {
                    folders.insert(parts.joined(separator: "/"))
                    parts = parts.dropLast()
                }
            }
            for folder in folders where isVisible(folder, in: root) {
                let name = (folder as NSString).lastPathComponent
                if let tier = CommandMatch.score(query: query, title: name, terms: folder) {
                    found.append(("folder", folder, tier))
                }
            }
        }
        if kinds.contains("tags") {
            // Only tags a note inside the folder carries, in a scoped run.
            for tag in index.allTags
            where index.notes(taggedWith: tag).contains(where: { isVisible($0.relativePath, in: root) }) {
                if let tier = CommandMatch.score(query: query, title: tag, terms: "") {
                    found.append(("tag", "#" + tag, tier))
                }
            }
        }
        // Folders and tags before notes on a tie, as in the bar: there are
        // fewer of them, so one that loses a tie is likelier never seen.
        let order = ["folder": 0, "tag": 1, "note": 2]
        let ranked = found.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if a.element.kind != b.element.kind { return order[a.element.kind]! < order[b.element.kind]! }
            return a.offset < b.offset
        }.map(\.element).prefix(limit)
        guard !ranked.isEmpty else {
            print("no matches")
            exit(0)
        }
        if options.flag("json") {
            JSONOutput.emit(ranked.map { ["kind": $0.kind, "name": $0.name] })
        }
        for entry in ranked { print("\(entry.kind.padding(toLength: 7, withPad: " ", startingAt: 0))\(entry.name)") }
        exit(0)
    }

    /// Past Ask chats: the latest first, those mentioning the query, or one
    /// read whole. In a run limited to a folder, only chats asked inside it.
    private static func chats(root: URL, arguments: [String]) {
        let options = Options(arguments[...])
        let query = CommandLineSpec.split(arguments, forVerb: "chats").positional.joined(separator: " ")
        let scope = agentScope
        let all = AgentChatStore.all(in: root).filter { chat in
            guard let scope else { return true }
            return isInScope(chat.scope, scope: scope)
        }
        if let id = options["read"] {
            guard let chat = all.first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
                fail("no chat \(id)")
            }
            if options.flag("json") {
                JSONOutput.emit(["id": chat.id, "title": chat.title, "turns": chat.turns.map {
                    ["question": $0.question, "answer": $0.answer]
                }])
            }
            print("# \(chat.title)")
            for turn in chat.turns {
                print("\nReader: \(turn.question)\n\nAgent: \(turn.answer)")
            }
            exit(0)
        }
        let limit = options["limit"].flatMap(Int.init) ?? 20
        let listed = all.filter { $0.matches(query) }.prefix(limit)
        guard !listed.isEmpty else {
            print("no chats")
            exit(0)
        }
        if options.flag("json") {
            JSONOutput.emit(listed.map { chat -> [String: Any] in
                ["id": chat.id, "title": chat.title, "updated": ISO8601DateFormatter().string(from: chat.updatedAt),
                 "turns": chat.turns.count]
            })
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for chat in listed {
            print("\(chat.id.prefix(8))  \(day.string(from: chat.updatedAt))  \(chat.title)  (\(chat.turns.count))")
        }
        exit(0)
    }

    private static func capture(root: URL, arguments: [String]) {
        let usage = "usage: heft capture <vault> [--daily] [--to <note>] [--done] [--at <time>] [--] <text>"
        // Strictly, since this writes without review: a caller that gets
        // the flags wrong has to hear so before a line is written, not find
        // a wrong one later. A program that logs here keeps its own record
        // of what landed, and a success that wrote the wrong thing is the
        // one failure it cannot see.
        let options: [String: String]
        let switches: Set<String>
        let positional: [String]
        switch CommandLineSpec.parse(arguments, forVerb: "capture") {
        case let .success(parsed):
            (positional, switches, options) = (parsed.positional, parsed.switches, parsed.values)
        case let .failure(.unknown(flag)):
            fail("capture has no \(flag) flag. Text that starts with -- goes after a lone --.\n\(usage)")
        case let .failure(.missingValue(flag)):
            fail("\(flag) needs a value after it.\n\(usage)")
        }
        let text = positional.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { fail(usage) }
        // Read through the spec, which knows these take no value. `Options`
        // alone took `--done "text"` for an option valued "text", and the
        // line went in unticked.
        let daily = switches.contains("--daily")
        let done = switches.contains("--done")
        guard !(daily && options["--to"] != nil) else {
            fail("--daily and --to name two different notes; pick one")
        }
        var moment = Date()
        let atGiven = options["--at"] != nil
        if let asked = options["--at"] {
            guard let named = captureMoment(asked) else {
                fail("""
                    --at takes an ISO 8601 date and time: \(asked)
                    For example 2026-03-04T09:15:00+01:00, or 2026-03-04T09:15 for local time.
                    """)
            }
            moment = named
        }

        // Through the same normaliser the stored inbox note goes through,
        // which already refuses `..`, `.`, an empty segment and an absolute
        // path. Passing the argument straight to `InboxCapture` skipped all
        // of that, and `--to "../file"` appended a heading and a bullet to a
        // file outside the vault. "It only adds" is a safety property of
        // adding to a *note*; prepending Markdown to a shell profile breaks
        // it as thoroughly as overwriting would.
        var target: String?
        if let asked = options["--to"] {
            guard let cleaned = InboxNotePreference.normalised(asked) else {
                fail("""
                    --to takes a path inside the vault: \(asked)
                    No leading /, and no `.` or `..` segments.
                    """)
            }
            target = cleaned
        }

        // A run limited to a folder adds only to a note it names inside it:
        // the inbox and today's note are wherever the settings put them.
        if let scope = agentScope {
            guard let target, isInScope(target, scope: scope) else {
                fail("in \(scope), capture needs --to a note inside that folder, the one this question is limited to")
            }
        }

        // A pinned run is one Heft asked, so it is reviewed whatever else
        // the environment says.
        if AgentCaptureReviewPreference.isOn || isAsked || pinnedVault != nil {
            captureAsProposal(
                text, root: root, daily: daily, to: target, at: moment, done: done,
                inTimeOrder: atGiven)
        }

        do {
            let written: URL
            if daily {
                let settings = ObsidianSettings.load(vaultRoot: root)
                // A moment named with --at may have passed, and the note
                // may have later lines by now: file it among them in order,
                // as the inbox does below.
                written = try DailyNoteCapture(vaultRoot: root, settings: settings)
                    .capture(text, at: moment, done: done, inTimeOrder: atGiven)
            } else {
                written = try InboxCapture(vaultRoot: root, relativePath: target)
                    .capture(text, at: moment, done: done, inTimeOrder: atGiven)
            }
            // Both sides standardised, or /tmp against /private/tmp made the
            // daily note print an absolute path where the inbox printed a
            // relative one, for the same vault.
            let base = root.standardizedFileURL.path
            let full = written.standardizedFileURL.path
            let relative = full.hasPrefix(base + "/")
                ? String(full.dropFirst(base.count + 1))
                : full
            print("captured to \(relative)")
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The same line, waiting for review instead of written.
    ///
    /// Builds the note as it would be *after* the capture and stores that as
    /// an ordinary proposal, so the review sheet shows one added line and
    /// accepting it does exactly what the immediate path would have done.
    /// Both routes go through the same `contents(byCapturing:)`, or the two
    /// would drift and the preference would change more than when the write
    /// happens.
    private static func captureAsProposal(
        _ text: String, root: URL, daily: Bool, to target: String?, at now: Date, done: Bool,
        inTimeOrder: Bool
    ) -> Never {
        let relative: String
        let starting: String?
        let proposed: String
        do {
            if daily {
                let settings = ObsidianSettings.load(vaultRoot: root)
                let notes = DailyNotes(vaultRoot: root, settings: settings)
                relative = notes.relativePath(for: now)
                let title = notes.stem(for: now)
                // Refused here too, or accepting the proposal wrote there.
                let url = try notes.checkedURL(for: now)
                starting = try existingText(at: url)
                // What `ensureNote` would have written, so a proposal for a
                // day with no note yet still carries the template.
                let base = starting ?? notes.templateBody().map {
                    MomentFormat.expandTemplate(
                        $0, date: now, title: title, dateFormat: settings.dailyNoteFormat
                    )
                } ?? "# \(title)\n\n"
                proposed = try DailyNoteCapture.contents(
                    byCapturing: text, in: base, at: now, title: title,
                    timestamped: CaptureTimestampPreference.isOn, done: done,
                    inTimeOrder: inTimeOrder
                )
            } else {
                let inbox = InboxCapture(vaultRoot: root, relativePath: target)
                relative = inbox.relativePath
                starting = try existingText(at: inbox.url)
                let title = ((relative as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                proposed = try InboxCapture.contents(
                    byCapturing: text, in: starting ?? "", at: now, title: title,
                    timestamped: CaptureTimestampPreference.isOn, done: done,
                    inTimeOrder: inTimeOrder
                )
            }
        } catch {
            fail(error.localizedDescription)
        }

        // Where the line lands, settings and symlinks followed, stays inside.
        guard isVisible(relative, in: root) else {
            fail("\(relative) is outside \(agentScope ?? "the vault"), what this question is limited to")
        }

        // One note, one pending proposal, as `propose` already holds. Each
        // capture is the whole note plus its line, so a second accepted
        // after the first took the first one's line back out.
        if let waiting = ProposalStore.conflict(forNote: relative, among: ProposalStore.all(in: root)) {
            fail("""
                \(relative) already has a proposal waiting: \(waiting.id)
                Accepting a second after it would take its changes back out, \
                so review or drop that one first.
                """)
        }

        let summary = "Capture: \(text.prefix(50))"
        let proposal = Proposal(
            id: ProposalStore.identifier(
                summary: summary,
                noteName: (relative as NSString).lastPathComponent,
                taken: taken(in: root, freeing: nil)
            ),
            notePath: relative,
            base: starting,
            body: proposed,
            agent: defaultAgent,
            summary: summary,
            kind: starting == nil ? .create : .edit
        )
        do {
            try ProposalStore.write(proposal, in: root)
        } catch {
            fail("could not write the proposal: \(error.localizedDescription)")
        }
        print("proposed \(proposal.id)")
        print("note:    \(relative)")
        print("Waiting for review in Heft. Settings ▸ Capture decides this.")
        exit(0)
    }

    /// A note's text, nil when there is no note, and a refusal when there
    /// is one that cannot be read. Read as nil, a note that was not UTF-8
    /// became a proposal to create it, and accepting that replaced it.
    private static func existingText(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The moment `--at` names. ISO 8601 with an offset or `Z`, seconds and
    /// fractions optional; without an offset it is local time, the way a
    /// person typing a time means it.
    ///
    /// The shape and the calendar day are checked first, because both
    /// formatters are lenient: `02-30` rolled into March, `Z` followed by
    /// anything was read as `Z`, and a five-digit year lost a digit.
    static func captureMoment(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let shape = #/(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?(?:[Zz]|[+-]\d{2}(?::?\d{2})?)?/#
        guard let typed = text.wholeMatch(of: shape) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let day = DateComponents(
            year: Int(typed.1), month: Int(typed.2), day: Int(typed.3),
            hour: Int(typed.4), minute: Int(typed.5))
        guard day.isValidDate(in: gregorian) else { return nil }
        let zoned = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ] {
            zoned.formatOptions = options
            if let date = zoned.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = pattern
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Helpers

    /// The one proposal an id names, or an exit. `ProposalStore.match` decides;
    /// this only turns each answer into a message and a status.
    /// The proposal `--replacing` names, and a refusal when the note already
    /// has one that is not it.
    ///
    /// There is no amend verb, and this is why one is not wanted. A proposal's
    /// id is a *name*, printed in `heft proposals` and shown in the sidebar; if
    /// `remove-the-middle-image` could quietly come to mean a six-line block
    /// deletion, the review list would be lying about what it is asking. So a
    /// changed proposal is a new proposal, and `--replacing` is only the two
    /// commands that took in one, without pretending the name survived.
    ///
    /// What was missing was the refusal. `propose` twice on one note happily
    /// wrote two, each measured against the note as it is now and each blind to
    /// the other, which is a trap an agent walks into while doing exactly what
    /// it was asked.
    private static func replacement(
        for relative: String, root: URL, options: Options
    ) -> Proposal? {
        // Resolved exactly, like `drop`: this deletes something, and a prefix
        // names a different set of proposals at different times.
        let replaced = options["replacing"].map {
            resolve($0, in: root, verb: "propose --replacing", exactly: true)
        }
        guard let waiting = ProposalStore.conflict(
            forNote: relative, among: ProposalStore.all(in: root), ignoring: replaced?.id
        ) else { return replaced }

        fail("""
            \(relative) already has a proposal waiting: \(waiting.id)
            Both would be measured against the note as it is now, so accepting one \
            leaves the other asking for a note it was never rebased onto.
            Take its place with --replacing \(waiting.id), or drop it first:
              heft drop "\(root.path)" \(waiting.id)
            """)
    }

    /// The ids already spoken for, minus the one about to be taken over.
    ///
    /// Freeing it matters: re-proposing under the same summary would otherwise
    /// come back as `\(name)-2` while `\(name)` was deleted a line later,
    /// which reads as a rename nobody asked for.
    private static func taken(in root: URL, freeing replaced: Proposal?) -> Set<String> {
        var ids = Set(ProposalStore.all(in: root).map(\.id))
        if let replaced { ids.remove(replaced.id) }
        return ids
    }

    /// Removes the proposal that has just been superseded.
    ///
    /// After the new one is safely on disk, so a failed write leaves the old
    /// proposal standing rather than neither. Skipped when the ids match: the
    /// new file is already at that path, and removing it would delete what was
    /// just written.
    private static func retire(_ replaced: Proposal?, replacedBy new: Proposal, in root: URL) {
        guard let replaced else { return }
        if replaced.id != new.id { ProposalStore.remove(replaced.id, in: root) }
        print("replaced \(replaced.id)")
    }

    private static func resolve(
        _ id: String?, in root: URL, verb: String, exactly: Bool = false
    ) -> Proposal {
        let proposals = visibleProposals(in: root)
        switch ProposalStore.match(id, among: proposals, exactly: exactly) {
        case let .one(found):
            return proposals.first { $0.id == found }!
        case .missing:
            fail("usage: heft \(verb) <vault> <proposal-id>")
        case let .unknown(given):
            // A prefix that would have matched is worth saying, or "no such
            // proposal: tighten" is baffling next to a list showing
            // `tighten-the-opening`.
            let near = proposals.filter { $0.id.hasPrefix(given) }.map(\.id)
            guard !near.isEmpty else { fail("no such proposal: \(given)") }
            fail("no proposal is called \(given). \(verb) needs the whole id: "
                + near.joined(separator: ", "))
        case let .ambiguous(candidates):
            fail("that names \(candidates.count) proposals: "
                + candidates.joined(separator: ", "))
        }
    }

    /// The vault-relative path a name refers to, resolved the way a wikilink
    /// resolves: a path, or a bare note name. `read` and `changes` both go
    /// through it so that a name means the same thing to each.
    private static func resolveNote(named name: String, in root: URL) -> String {
        let index = VaultIndex.open(vaultAt: root)
        if agentScope != nil || pinnedBoundary != nil {
            // Resolved among the folder's notes alone, so a bare name finds
            // the one inside rather than failing on a likelier one outside.
            let inside = index.notes.filter { isVisible($0.relativePath, in: root) }
            guard let found = VaultIndex.match(name, among: inside) else {
                fail("no note called \(name) in \(agentScope ?? "the vault"), "
                    + "the \(agentScope == nil ? "vault" : "folder") this question is limited to")
            }
            return found.relativePath
        }
        guard let found = index.note(named: name) else {
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
