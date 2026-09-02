import Foundation
import HeftCore

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
enum AgentCLI {

    static let verbs: Set<String> = ["propose", "proposals", "diff", "drop", "read", "find"]

    /// Returns true when it handled the arguments (and has exited).
    static func run(_ arguments: [String]) -> Bool {
        guard let verb = arguments.first, verbs.contains(verb) else { return false }
        guard arguments.count > 1 else {
            fail("usage: heft \(verb) <vault> …")
        }
        let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        let rest = Array(arguments.dropFirst(2))

        switch verb {
        case "propose": propose(root: root, arguments: rest)
        case "proposals": list(root: root)
        case "diff": showDiff(root: root, arguments: rest)
        case "drop": drop(root: root, arguments: rest)
        case "read": read(root: root, arguments: rest)
        case "find": find(root: root, arguments: rest)
        default: return false
        }
        return true
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

        let body: String
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
        let current = try? String(contentsOf: noteURL, encoding: .utf8)

        if let current, current == body {
            print("no change: \(relative) already reads that way")
            exit(0)
        }

        let proposal = Proposal(
            notePath: relative,
            base: current,
            body: body,
            agent: options["agent"] ?? "claude-code",
            summary: options["summary"] ?? "Proposed edit"
        )
        do {
            try ProposalStore.write(proposal, in: root)
        } catch {
            fail("could not write the proposal: \(error.localizedDescription)")
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
        guard let id = arguments.first else { fail("usage: heft diff <vault> <proposal-id>") }
        guard let proposal = ProposalStore.all(in: root).first(where: { $0.id.hasPrefix(id) }) else {
            fail("no such proposal: \(id)")
        }
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
        guard let id = arguments.first else { fail("usage: heft drop <vault> <proposal-id>") }
        guard let proposal = ProposalStore.all(in: root).first(where: { $0.id.hasPrefix(id) }) else {
            fail("no such proposal: \(id)")
        }
        ProposalStore.remove(proposal.id, in: root)
        print("dropped \(proposal.id)")
        exit(0)
    }

    /// Reading a note by name rather than by path, the way a wikilink does, so
    /// an agent can work from what the vault calls things.
    private static func read(root: URL, arguments: [String]) {
        guard let name = arguments.first else { fail("usage: heft read <vault> <note>") }
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        let wanted = normalized(name)
        guard let note = index.notes.first(where: {
            $0.relativePath == wanted || $0.name == name || $0.name == note(name)
        }) else {
            fail("no such note: \(name)")
        }
        print((try? String(contentsOf: note.url, encoding: .utf8)) ?? "")
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

        init(_ arguments: ArraySlice<String>) {
            var iterator = Array(arguments).makeIterator()
            while let token = iterator.next() {
                guard token.hasPrefix("--") else { continue }
                values[String(token.dropFirst(2))] = iterator.next()
            }
        }

        subscript(key: String) -> String? { values[key] }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
