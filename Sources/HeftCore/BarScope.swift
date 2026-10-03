import Foundation

/// What the search bar is narrowed to, shown as a chip at the start of its
/// field. No scope at all is the bar ⌘T opens: notes and commands together.
///
/// One bar with scopes rather than a sheet per kind of thing, so that ⌘O, ⌘P
/// and ⇧⌘F are ways *into* the same place and a reader who opened the wrong
/// one does not have to close it and remember another key. The browsers all
/// settled on this shape: a scope is entered by a symbol or a choice, shown
/// as a chip, and left with Backspace in an empty field.
public enum BarScope: Hashable, Sendable {
    /// Note names: what ⌘O opens.
    case notes
    /// What ⌘P opens.
    case commands
    /// Text inside notes: what ⇧⌘F opens.
    case contents
    case tags
    /// One tag's notes, searched by name and by text.
    case tag(String)
    case folders
    /// Everything under one folder, vault-relative, searched by name and by
    /// text.
    case folder(String)
    /// The opening history alone, in full.
    case recent
    /// Every note with any use, most used first.
    case frequent

    /// The field's prompt with no scope. Short, since the chips under it and
    /// the keys beside each scope say the rest.
    public static let unscopedPlaceholder = "Search anything"

    /// The scopes a reader can pick from a list, in the order offered.
    public static let offered: [BarScope] = [.notes, .commands, .tags, .contents]

    /// Every scope that can be found by name in the bar with no scope:
    /// typing "rec" offers Recent, and Space or Tab makes it the chip.
    public static let searchable: [BarScope] = offered + [.folders, .recent, .frequent]

    /// Other words a scope answers to, the way a command has search terms.
    public var aliases: String {
        switch self {
        // Including the titles of the commands each one replaces in the bar
        // with no scope, so "quick open" and "search the vault" still find them.
        case .notes: "notes files names open quick open switcher jump go to"
        case .commands: "commands actions palette run command palette"
        case .contents: "text contents inside full search grep search the vault workspace"
        case .tags: "tags hashtags labels"
        case .tag: "tag"
        case .folders: "folders directories"
        case .folder: "folder"
        case .recent: "recent history last opened"
        case .frequent: "frequent most used often popular"
        }
    }

    /// The key a scope's use is recorded under, beside the commands' own,
    /// so the scopes a reader enters rank among what they use.
    public var useKey: String {
        if case .tag(let name) = self { return "tag:\(name.lowercased())" }
        if case .folder(let path) = self { return "folder:\(path)" }
        return "scope:\(title.lowercased())"
    }

    /// Whether Space after `query` should enter this scope rather than type a
    /// space: the query is the start of its name or of one of its words. A
    /// query that only matched a synonym, or a word in the middle, is still
    /// being typed, as Chrome's keyword mode wants the keyword itself.
    public func isNamed(byPrefix query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        let name = title.lowercased()
        return name.hasPrefix(q) || name.split(separator: " ").contains { $0.hasPrefix(q) }
    }

    public var title: String {
        switch self {
        case .notes: "Notes"
        case .commands: "Commands"
        // Short, as a chip should be; the placeholder says where.
        case .contents: "Text"
        case .tags: "Tags"
        // The chip draws the hash as its symbol.
        case .tag(let name): name
        case .folders: "Folders"
        // The chip shows the folder's own name; the placeholder its path.
        case .folder(let path): path.split(separator: "/").last.map(String.init) ?? path
        case .recent: "Recent"
        case .frequent: "Frequent"
        }
    }

    /// An SF Symbol name; HeftCore does not draw it.
    public var symbol: String {
        switch self {
        case .notes: "doc.text"
        case .commands: "chevron.right.2"
        case .contents: "text.magnifyingglass"
        case .tags, .tag: "number"
        case .folders, .folder: "folder"
        case .recent: "clock"
        case .frequent: "star"
        }
    }

    public var placeholder: String {
        switch self {
        case .notes: "Search notes, or paste a path"
        case .commands: "Search commands"
        case .contents: "Search text in notes"
        case .tags: "Search tags"
        case .tag(let name): "Search notes tagged #\(name)"
        case .folders: "Search folders"
        case .folder(let path): "Search in \(path)"
        case .recent: "Search recent notes"
        case .frequent: "Search frequent notes"
        }
    }

    /// The character that enters this scope when typed alone into the bar
    /// with no scope.
    ///
    /// Symbols rather than letters, since a letter would collide with every
    /// note that starts with it. Alone and typed, not merely leading: a
    /// pasted `/Users/…` path is still a path, because it arrives whole.
    public var trigger: Character? {
        switch self {
        // As a page or a tab is mentioned in Notion, Linear and Dia.
        case .notes: "@"
        case .commands: ">"
        case .tags: "#"
        case .contents: "/"
        default: nil
        }
    }

    /// The scope a query typed into the bar with no scope asks for, if it is
    /// exactly one trigger.
    public static func entered(byTyping query: String) -> BarScope? {
        guard query.count == 1, let typed = query.first else { return nil }
        return offered.first { $0.trigger == typed }
    }

    /// Where Backspace in an empty field goes: a tag back to the list of
    /// tags it was chosen from, anything else back to the bar with no scope.
    public var parent: BarScope? {
        if case .tag = self { return .tags }
        if case .folder = self { return .folders }
        return nil
    }

    /// Whether typing here also searches the text inside the notes, below
    /// the name matches. Only where the notes are a chosen few: across the
    /// whole vault, text hits mixed in made jumping by name slower.
    public var searchesTextToo: Bool {
        switch self {
        case .tag, .folder: true
        default: false
        }
    }

    /// Whether the window's focused folder narrows this scope, as it does
    /// Quick Open and vault search. Commands and tags are vault-wide.
    public var followsFolderFocus: Bool {
        switch self {
        // A chosen folder is explicit, so it outranks the window's focus.
        case .commands, .tags, .folders, .folder: false
        default: true
        }
    }
}

/// How well a command's title and search terms answer a query, on the same
/// scale as `VaultIndex.scoredSearch`, so a bar that lists both can rank
/// them against each other.
///
/// A title beats the hidden search terms at every level: "Bold" typed finds
/// the Bold command above anything that merely lists "bold" as a synonym.
public enum CommandMatch {
    public static func score(query: String, title: String, terms: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        // The trailing ellipsis of "Quick Open…" is not part of its name.
        let name = title.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        if name == q { return 400 }
        if name.hasPrefix(q) { return 300 }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 250 }
        if name.contains(q) { return 200 }
        // Every typed word somewhere in the title or the terms: the
        // palette's old yes-or-no, kept as the lowest tier so nothing it
        // used to find goes missing.
        let haystack = "\(name) \(terms.lowercased())"
        let typed = q.split(separator: " ")
        if typed.allSatisfy({ haystack.contains($0) }) { return 150 }
        return nil
    }
}
