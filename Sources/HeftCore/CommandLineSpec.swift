import Foundation

/// The one description of Heft's command line.
///
/// Everything that needs to know what verbs exist reads this: `heft help`,
/// `heft help --json` for an agent, and the shell wrapper `install.sh`
/// generates, which forwards known verbs and treats anything else as a path
/// to open.
///
/// That last one is why this exists rather than a hand-written help text.
/// The wrapper's list was a second copy of the dispatch, and it drifted the
/// first time a verb was added: `heft export` became `heft open export` and
/// reported "no such file or folder: export" from a binary that handled the
/// verb perfectly well. A help text would have been a third copy and would
/// have rotted the same way.
public enum CommandLineSpec {

    public struct Flag: Sendable, Equatable, Codable {
        public let name: String
        /// A placeholder for the flag's argument, or nil when it is a switch.
        public let value: String?
        public let summary: String

        public init(_ name: String, value: String? = nil, _ summary: String) {
            self.name = name
            self.value = value
            self.summary = summary
        }

        public var usage: String { value.map { "\(name) \($0)" } ?? name }
    }

    public struct Verb: Sendable, Equatable, Codable {
        public let name: String
        /// Positional arguments, as they are written in usage.
        public let arguments: String
        public let summary: String
        public let flags: [Flag]
        /// True when the verb only reads, so it is safe against a live vault.
        public let isReadOnly: Bool
        /// True for verbs that report on Heft's internals rather than on the
        /// vault. They are listed apart, because `render` describing layout
        /// fragments and reserved heights means nothing to someone who just
        /// wants their notes, and putting it beside `export` and `find`
        /// implies it is for them.
        public let isDiagnostic: Bool

        public init(
            _ name: String, _ arguments: String, _ summary: String,
            flags: [Flag] = [], isReadOnly: Bool = true, isDiagnostic: Bool = false
        ) {
            self.name = name
            self.arguments = arguments
            self.summary = summary
            self.flags = flags
            self.isReadOnly = isReadOnly
            self.isDiagnostic = isDiagnostic
        }

        public var usage: String {
            "heft \(name)\(arguments.isEmpty ? "" : " \(arguments)")"
        }
    }

    public static let verbs: [Verb] = [
        Verb("open", "<path>", "Open a vault, folder or note. The default for a bare path.",
             isReadOnly: false),
        Verb("help", "[--json]", "This list. `--json` is the machine-readable form."),

        // Reading a vault
        Verb("files", "<vault>", "Every note, vault-relative.", flags: [
            Flag("--by-use", "Most-used first, the order Quick Open opens on."),
            Flag("--by-agent", "What an agent has proposed changes to."),
            Flag("--scores", "Show each note's score."),
            Flag("--limit", value: "N", "Stop after N."),
        ]),
        Verb("find", "<vault> <query>", "Full-text search across the vault."),
        Verb("read", "<vault> <note>", "A note's source."),
        Verb("outline", "<vault> <note>", "The note's headings, with their lines."),
        Verb("links", "<vault> <note>", "Links out of a note, resolved and unresolved."),
        Verb("backlinks", "<vault> <note>", "Notes linking to this one, with context."),
        Verb("tags", "<vault> [tag]", "Tags with counts, or the notes carrying one."),
        Verb("config", "<vault>", "The vault's settings, as JSON."),
        Verb("stats", "<vault>", "Index report: counts, timings, link resolution.",
             isDiagnostic: true),

        // Proposing changes
        Verb("propose", "<vault> <note>", "Propose a new body for a note, from stdin.", flags: [
            Flag("--summary", value: "s", "What the change is for."),
            Flag("--agent", value: "a", "Who is proposing. Defaults to claude-code."),
            Flag("--from", value: "file", "Read the body from a file instead of stdin."),
            Flag("--replace", "Take anchored old/new pairs as JSON instead of a whole body."),
        ], isReadOnly: false),
        Verb("proposals", "<vault>", "What is waiting for review."),
        Verb("diff", "<vault> <id>", "What one proposal would change."),
        Verb("drop", "<vault> <id>", "Discard a proposal.", isReadOnly: false),

        // Producing things
        Verb("export", "<vault> <note> <out.pdf>", "The rendered note as a PDF.", flags: [
            Flag("--text-size", value: "N", "Body size in points on the page. Default 12."),
            Flag("--paper", value: "a4|letter|legal|tabloid", "Page size. Default a4."),
            Flag("--landscape", "Turn the page sideways."),
            Flag("--margin", value: "narrow|normal|wide", "White space around the text."),
            Flag("--title", "Put the note's name at the top."),
        ], isReadOnly: false),
        Verb("daily", "<vault> [YYYY-MM-DD]", "Create a daily note from the template.",
             isReadOnly: false),
        Verb("rename", "<vault> <path> <new>",
             "Rename a note, attachment or folder, repointing the links into it.", flags: [
            Flag("--dry-run", "Say what would change, and change nothing."),
        ], isReadOnly: false),
        Verb("render", "<vault> <note> [caret]",
             "What the live surface would draw, fragment by fragment.",
             isDiagnostic: true),
        Verb("agent-setup", "<vault>", "Teach an agent in that vault to propose.",
             isReadOnly: false),
    ]

    public static func verb(named name: String) -> Verb? {
        verbs.first { $0.name == name }
    }

    /// Whether these arguments are asking for help.
    ///
    /// **Never for no arguments at all.** That is how the Dock, Finder and
    /// `open` launch a Mac app, and treating it as a help request made the
    /// app print usage to a stdout nobody was reading and exit — one bounce
    /// in the Dock and no window. It shipped that way.
    ///
    /// A bare `heft` in a terminal does not reach this: the installed wrapper
    /// sends anything that is not a verb through `open`, so it arrives as
    /// `heft open` and starts the app, the way `code .` does.
    public static func wantsHelp(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first == "help" || first == "--help" || first == "-h"
    }

    /// Newline-separated verb names. What `install.sh` bakes into the wrapper,
    /// so the wrapper cannot fall behind the binary.
    public static var verbNames: String {
        verbs.map(\.name).joined(separator: "\n")
    }

    public static func helpText() -> String {
        var lines = [
            "heft — a native macOS editor for a Markdown vault.",
            "",
            "  heft <path>                    open a vault, folder or note",
            "  heft help [--json]             this list",
            "",
        ]
        // Summaries all start in one column, flags included: a flag's line
        // begins six spaces in, so it needs that much less padding.
        let column = max(verbs.map(\.usage.count).max() ?? 0, 34)

        func describe(_ verb: Verb) {
            let usage = verb.usage.padding(toLength: column, withPad: " ", startingAt: 0)
            lines.append("  \(usage)  \(verb.summary)")
            for flag in verb.flags {
                let pad = String(repeating: " ", count: max(1, column - flag.usage.count - 2))
                lines.append("      \(flag.usage)\(pad)\(flag.summary)")
            }
        }

        for verb in verbs
        where verb.name != "open" && verb.name != "help" && !verb.isDiagnostic {
            describe(verb)
        }
        let diagnostics = verbs.filter(\.isDiagnostic)
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("Diagnostics — about Heft's rendering rather than about your notes:")
            diagnostics.forEach(describe)
        }
        lines.append("")
        lines.append("Verbs marked read-only in `heft help --json` are safe against a live vault.")
        return lines.joined(separator: "\n")
    }

    public static func helpJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(verbs),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
