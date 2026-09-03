import Foundation

/// The decisions behind creating, renaming, moving and deleting things in a
/// vault, with nothing that needs a window.
///
/// `VaultRename` already owns the hard part — which files move and what the
/// notes pointing at them should say. What was left over is smaller and was
/// worse for it: the rules for cleaning a typed name, for putting `.md` back
/// on a note that displays without it, for finding a free `Untitled 3`, and
/// for deciding that a folder cannot be dropped inside itself. Those lived in
/// `AppModel` as `guard` statements interleaved with writes to `status`, so
/// the only way to reach one was through a running window, and the command
/// line re-derived the two it needed by hand — including the `.md` rule, in a
/// slightly different form.
///
/// So a refusal is a value here rather than a string assigned on the way out.
/// The window turns it into `status`, the command line prints it to stderr,
/// and a test can ask what a name would do without either.
public enum VaultOperations {

    // MARK: - Names

    /// Cleans a name typed into a prompt or passed on the command line.
    ///
    /// `/` and `:` are the two characters a person reasonably types into a
    /// note title that a filesystem will not take: `/` would silently make a
    /// folder level, and `:` is what the Finder still shows as `/`. Both
    /// become a dash rather than being stripped, so `Notes: 2026` keeps its
    /// shape instead of closing up to `Notes 2026`.
    public static func sanitise(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// The filename a typed name should become, or nil when nothing was typed.
    ///
    /// Markdown notes are shown without their extension everywhere — the
    /// sidebar, the switcher, a wikilink — so the extension must not appear in
    /// the field and has to be put back afterwards. Someone who types it
    /// anyway is not given `Note.md.md`.
    public static func filename(for entered: String, isMarkdown: Bool) -> String? {
        let cleaned = sanitise(entered)
        guard !cleaned.isEmpty else { return nil }
        guard isMarkdown, !cleaned.lowercased().hasSuffix(".md") else { return cleaned }
        return cleaned + ".md"
    }

    /// A name not already taken, as `Untitled`, `Untitled 1`, `Untitled 2`, …
    ///
    /// Takes the existence test as a closure rather than reaching for
    /// `FileManager`, which is what lets the numbering be tested against a set
    /// of names instead of against a temporary directory.
    public static func uniqueName(
        base: String, extension ext: String, isTaken: (String) -> Bool
    ) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = base + suffix
        var counter = 1
        while isTaken(candidate) {
            candidate = "\(base) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }

    /// Where an item lands when renamed to `entered`.
    ///
    /// A bare name keeps the item where it is; anything holding a `/` is a
    /// move as well as a rename. That is the command line's spelling of a
    /// rename and the reason one function can serve both: the sidebar simply
    /// never passes a path.
    public static func destination(
        for item: VaultItem, named entered: String
    ) -> String? {
        guard let cleanedName = filename(
            for: entered.contains("/")
                ? (entered as NSString).lastPathComponent
                : entered,
            isMarkdown: item.isMarkdown
        ) else { return nil }

        let parent: String = if entered.contains("/") {
            (entered.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString)
                .deletingLastPathComponent
        } else {
            (item.relativePath as NSString).deletingLastPathComponent
        }
        return parent.isEmpty ? cleanedName : parent + "/" + cleanedName
    }

    /// A URL's path relative to the vault root, or its own name when it lies
    /// outside. Symlinks are resolved on both sides, because a vault reached
    /// through one would otherwise never match its own contents.
    public static func relativePath(of url: URL, in vaultRoot: URL) -> String {
        let root = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        if candidate == root { return "" }
        guard candidate.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(candidate.dropFirst(root.count + 1))
    }

    // MARK: - Refusals

    /// Why an operation will not happen, in terms of the vault rather than of
    /// a particular window.
    ///
    /// It conforms to `Error` only because that is what `Result` asks of a
    /// failure type. Nothing throws one and nothing should: none of these is
    /// exceptional — every one is an ordinary answer to "can this happen?",
    /// most often reached by a drag that ended somewhere it could not go, and
    /// a `throw` would make the call sites read as though something had gone
    /// wrong.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing was typed, or only whitespace was.
        case emptyName
        /// Something is already at the destination.
        case alreadyExists(name: String)
        /// A drop carried something from outside the vault.
        case outsideVault(name: String)
        /// A folder dropped into itself or into its own descendant. The move
        /// would delete it.
        case intoItself(name: String)
        /// Already in that folder, so there is nothing to do.
        case alreadyThere(name: String)
        /// The vault is still being scanned, so the item's contents are not
        /// known and a folder move cannot be planned.
        case stillLoading(name: String)

        /// What to tell the reader. One wording, so the sidebar's status line
        /// and the command line's stderr cannot drift apart.
        public var message: String {
            switch self {
            case .emptyName:
                "The new name is empty"
            case .alreadyExists(let name):
                "\(name) already exists"
            case .outsideVault(let name):
                "\(name) is outside the vault"
            case .intoItself(let name):
                "Cannot move \(name) inside itself"
            case .alreadyThere(let name):
                "\(name) is already there"
            case .stillLoading(let name):
                "Wait for the vault to finish loading before moving \(name)"
            }
        }
    }

    // MARK: - Preflight

    /// What a validated operation resolved to: where the item is going, and
    /// the name it will have when it gets there.
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
        public var name: String { (to as NSString).lastPathComponent }

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Whether `item` can be renamed to `entered`, and where that puts it.
    ///
    /// `exists` answers for a vault-relative path. Renaming something to the
    /// name it already has is allowed and reported as a `Move` that goes
    /// nowhere, because the caller's honest answer to "did that work" is yes:
    /// refusing would make Return on an unchanged field look like a failure.
    public static func planRename(
        _ item: VaultItem, to entered: String, exists: (String) -> Bool
    ) -> Result<Move, Refusal> {
        guard let destination = destination(for: item, named: entered) else {
            return .failure(.emptyName)
        }
        guard destination != item.relativePath else {
            return .success(Move(from: item.relativePath, to: item.relativePath))
        }
        guard !exists(destination) else {
            return .failure(.alreadyExists(name: (destination as NSString).lastPathComponent))
        }
        return .success(Move(from: item.relativePath, to: destination))
    }

    /// Whether `path` can be moved into `folder`, both vault-relative.
    ///
    /// The order of these checks is what they say, and one of them is load
    /// bearing: a folder dropped onto itself is rejected before the
    /// destination is tested for existence, because the destination *is* the
    /// folder and reporting "already exists" would be true and useless.
    public static func planMove(
        _ path: String, into folder: String, isFolder: Bool, exists: (String) -> Bool
    ) -> Result<Move, Refusal> {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != folder else { return .failure(.alreadyThere(name: name)) }
        guard !isFolder || !(folder == path || folder.hasPrefix(path + "/")) else {
            return .failure(.intoItself(name: name))
        }
        let destination = folder.isEmpty ? name : folder + "/" + name
        guard !exists(destination) else { return .failure(.alreadyExists(name: name)) }
        return .success(Move(from: path, to: destination))
    }

    /// Whether a URL a drop carried is somewhere this vault may move it from.
    ///
    /// A drop can carry anything Finder had on the pasteboard. Pulling a file
    /// in from elsewhere would take it out of wherever the reader keeps it,
    /// which is not what dragging something onto a note list should mean.
    public static func isInside(_ url: URL, vaultRoot: URL) -> Bool {
        let root = vaultRoot.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    // MARK: - Summaries

    /// The sentence a finished rename or move adds about the links it fixed.
    ///
    /// Empty when nothing was repointed, so a caller can append it to its own
    /// message unconditionally. Both the sidebar's status line and `heft
    /// rename` said this in their own words before, and the two had already
    /// drifted in tense and punctuation.
    public static func repointSummary(_ summary: VaultRename.Summary) -> String {
        var parts: [String] = []
        if summary.links > 0 {
            parts.append(
                "repointed \(summary.links) link\(plural(summary.links))"
                + " in \(summary.notes) note\(plural(summary.notes))"
            )
        }
        if summary.skipped > 0 {
            parts.append(
                "\(summary.skipped) note\(plural(summary.skipped))"
                + " changed concurrently and \(summary.skipped == 1 ? "was" : "were")"
                + " left untouched"
            )
        }
        return parts.joined(separator: "; ")
    }

    public static func plural(_ count: Int) -> String { count == 1 ? "" : "s" }
}
