import Foundation

/// The one list of what the app's keys do.
///
/// The same lesson as `CommandLineSpec`. The menu declared most of these
/// inline, six more were named in `AppCommandShortcut`, and the README kept a
/// third copy in a table nobody could check. Three copies of a list is two
/// too many: the verb list drifted the first time a verb was added, and there
/// is no reason keys would behave differently.
///
/// So the table is here, in the pure target, where `heft keys` can print it
/// without starting a window and a test can hold it against the menu that
/// uses it. It also means an agent asked "how do I capture to my inbox" has
/// something to run, rather than guessing at a shortcut it cannot see.
public enum KeyboardShortcuts {

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// macOS writes modifiers in a fixed order, and it is not the order
        /// they are usually declared in: control, option, shift, command.
        public var display: String {
            var out = ""
            if contains(.control) { out += "⌃" }
            if contains(.option) { out += "⌥" }
            if contains(.shift) { out += "⇧" }
            if contains(.command) { out += "⌘" }
            return out
        }
    }

    /// Where a shortcut lives, so `heft keys` can print it the way the menu
    /// bar reads rather than as one flat list.
    public enum Group: String, CaseIterable, Sendable {
        case file = "File"
        case edit = "Edit"
        case format = "Format"
        case find = "Find"
        case view = "View"
        case navigate = "Go"
    }

    public struct Shortcut: Sendable, Hashable {
        /// Stable identifier, for tests and for `--json`.
        public let id: String
        /// What the menu item says.
        public let title: String
        public let key: Character
        public let modifiers: Modifiers
        public let group: Group
        /// Worth printing in a README. The full list belongs behind
        /// `heft keys`: a reader scanning a page wants the dozen that change
        /// how they move around, not ⌘B for bold, which they can guess and
        /// which pads the table past the point anyone reads it.
        public let isNotable: Bool

        /// Never stored. A hand-written "⇧⌘T" beside `[.command, .shift]` is
        /// a fourth copy of the same fact, and one that goes wrong silently.
        public var display: String { modifiers.display + String(key).uppercased() }

        public init(
            id: String, title: String, key: Character,
            modifiers: Modifiers, group: Group, isNotable: Bool = false
        ) {
            self.id = id
            self.title = title
            self.key = key
            self.modifiers = modifiers
            self.group = group
            self.isNotable = isNotable
        }
    }

    public static let all: [Shortcut] = [
        .init(id: "newNote", title: "New Note", key: "n", modifiers: [.command], group: .file, isNotable: true),
        .init(id: "newWindow", title: "New Window", key: "n", modifiers: [.command, .shift], group: .file),
        .init(id: "captureInbox", title: "Capture to Inbox", key: "i", modifiers: [.command, .shift], group: .file, isNotable: true),
        .init(id: "openToday", title: "Today's Daily Note", key: "t", modifiers: [.command, .shift], group: .file, isNotable: true),
        .init(id: "openVaultInNewWindow", title: "Open Vault in New Window", key: "o", modifiers: [.command, .shift], group: .file, isNotable: true),
        .init(id: "exportPDF", title: "Export as PDF", key: "e", modifiers: [.command, .shift], group: .file, isNotable: true),
        .init(id: "save", title: "Save pending edits now", key: "s", modifiers: [.command], group: .file, isNotable: true),

        .init(id: "bold", title: "Bold", key: "b", modifiers: [.command], group: .format),
        .init(id: "italic", title: "Italic", key: "i", modifiers: [.command], group: .format),
        .init(id: "strikethrough", title: "Strikethrough", key: "x", modifiers: [.command, .shift], group: .format),
        .init(id: "highlight", title: "Highlight", key: "h", modifiers: [.command, .shift], group: .format),
        .init(id: "code", title: "Code", key: "e", modifiers: [.command], group: .format),
        .init(id: "link", title: "Link", key: "k", modifiers: [.command], group: .format),

        .init(id: "find", title: "Find in note", key: "f", modifiers: [.command], group: .find),
        .init(id: "findNext", title: "Find next", key: "g", modifiers: [.command], group: .find),
        .init(id: "findPrevious", title: "Find previous", key: "g", modifiers: [.command, .shift], group: .find),
        .init(id: "searchVault", title: "Search the vault", key: "f", modifiers: [.command, .shift], group: .find, isNotable: true),

        // Declared here like everything else, even though macOS gives it for
        // free: `heft keys` is what an agent answers "how do I change that"
        // from, and a shortcut the app has and the table does not know about
        // is exactly the drift this table exists to prevent.
        .init(id: "settings", title: "Settings", key: ",", modifiers: [.command], group: .file),

        .init(id: "quickOpen", title: "Quick open", key: "o", modifiers: [.command], group: .navigate, isNotable: true),
        .init(id: "commandPalette", title: "Command palette", key: "p", modifiers: [.command], group: .navigate, isNotable: true),
        // ⇧⌘J is Xcode's Reveal in Project Navigator, which is this exactly.
        .init(id: "revealInSidebar", title: "Show this note in the file tree", key: "j", modifiers: [.command, .shift], group: .navigate, isNotable: true),

        .init(id: "toggleSidebar", title: "Toggle sidebar", key: "s", modifiers: [.command, .shift], group: .view, isNotable: true),
        .init(id: "toggleCalendar", title: "Toggle calendar", key: "d", modifiers: [.command, .shift], group: .view, isNotable: true),
        .init(id: "toggleBacklinks", title: "Toggle backlinks", key: "b", modifiers: [.command, .option], group: .view, isNotable: true),
    ]

    public static func shortcut(_ id: String) -> Shortcut {
        guard let found = all.first(where: { $0.id == id }) else {
            preconditionFailure("no shortcut named \(id)")
        }
        return found
    }

    /// What `heft keys` prints.
    public static func rendered() -> String {
        var out: [String] = []
        for group in Group.allCases {
            let entries = all.filter { $0.group == group }
            guard !entries.isEmpty else { continue }
            out.append(group.rawValue)
            let width = entries.map(\.display.count).max() ?? 0
            for entry in entries {
                let pad = String(repeating: " ", count: width - entry.display.count)
                out.append("  \(entry.display)\(pad)  \(entry.title)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The Markdown table the README carries, so the two cannot drift.
    ///
    /// Notable ones only by default. The README is read top to bottom by
    /// someone deciding whether to try this; the exhaustive list is a
    /// reference, and references belong behind a command.
    public static func markdownTable(all everything: Bool = false) -> String {
        var rows = ["| Shortcut | Action |", "|---|---|"]
        rows += all.filter { everything || $0.isNotable }
            .map { "| \($0.display) | \($0.title) |" }
        return rows.joined(separator: "\n")
    }
}
