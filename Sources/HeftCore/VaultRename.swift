import Foundation

/// Renaming a file or a folder, and repointing the links that pointed at it.
///
/// The editor has done this since early on; this is the same work with the
/// window taken out of it, so the command line can do it too. What the editor
/// keeps to itself is everything about *being* a window — which note is open in
/// which one, whose buffer is unsaved, where the sidebar is focused. What
/// belongs here is the part a vault would agree with from anywhere: which paths
/// move, which notes point at them, and what those notes should say afterwards.
public enum VaultRename {

    /// One note that needs rewriting, and what it should say.
    public struct Rewrite: Equatable, Sendable {
        public let note: NoteRef
        /// The text read before the move, so a note edited in between can be
        /// left alone rather than overwritten.
        public let original: String
        public let rewritten: String
        /// How many links inside it changed.
        public let links: Int
    }

    public struct Plan: Sendable {
        /// Vault-relative old path to new path. A folder contributes one entry
        /// per file inside it, because links point at files.
        public let changes: [String: String]
        public let rewrites: [Rewrite]
        public var linkCount: Int { rewrites.reduce(0) { $0 + $1.links } }
    }

    public struct Summary: Sendable {
        public var links = 0
        public var notes = 0
        /// Notes that changed on disk between the plan and the write, and were
        /// left as they are.
        public var skipped = 0

        public init(links: Int = 0, notes: Int = 0, skipped: Int = 0) {
            self.links = links
            self.notes = notes
            self.skipped = skipped
        }
    }

    public enum Failure: Error, Equatable {
        case noSuchItem(String)
        case alreadyExists(String)
        case emptyName
        case unreadable(String)
    }

    // MARK: - Planning

    /// Which files move when `item` is renamed or moved to `newPath`.
    ///
    /// A folder is expanded to the files under it: a link points at a file, so
    /// a folder that moved is only ever a set of files that moved.
    public static func changes(for item: VaultItem, movingTo newPath: String) -> [String: String] {
        guard item.isFolder else { return [item.relativePath: newPath] }
        return Dictionary(uniqueKeysWithValues: item.flattened().compactMap { descendant in
            guard !descendant.isFolder else { return nil }
            let suffix = descendant.relativePath.dropFirst(item.relativePath.count)
            return (descendant.relativePath, newPath + suffix)
        })
    }

    /// What every note that links into `changes` should say afterwards.
    ///
    /// - Parameter read: how to get a note's current text. The editor hands
    ///   back its own unsaved buffer for the note it has open; everything else
    ///   reads the file.
    public static func rewrites(
        for changes: [String: String],
        in index: VaultIndex,
        read: (NoteRef) throws -> String
    ) throws -> [Rewrite] {
        let sources = Set(changes.keys.flatMap {
            index.backlinks(to: $0).map(\.source.relativePath)
        })
        var plans: [Rewrite] = []

        // A bare name finds the shallowest file of that name, then the
        // shortest path, so a move can leave it answering for another file:
        // `Plan.md` moved deep under `Archive` loses the name to
        // `Work/Plan.md`. Asked of the vault as the move will leave it; a
        // tie is no answer either, and a path is spelled instead.
        func name(_ path: String) -> String {
            let file = (path as NSString).lastPathComponent
            let isMarkdown = VaultScanner.classify(
                extension: (file as NSString).pathExtension.lowercased()
            ) == .markdown
            return (isMarkdown ? (file as NSString).deletingPathExtension : file).lowercased()
        }
        func rank(_ path: String) -> (Int, Int) { (path.count(where: { $0 == "/" }), path.count) }
        let after = Dictionary(grouping: index.allFiles.map {
            changes[$0.relativePath] ?? $0.relativePath
        }, by: name)
        func nameFinds(_ path: String) -> Bool {
            !(after[name(path)] ?? []).contains { $0 != path && rank($0) <= rank(path) }
        }

        for path in sources.sorted() {
            guard let source = index.note(atRelativePath: path) else { continue }
            let original: String
            do {
                original = try read(source)
            } catch {
                throw Failure.unreadable(path)
            }

            let result = WikiLinkParser.rewriteTargets(
                in: original,
                matches: { link in
                    guard let old = index.resolve(link, from: source)?.relativePath
                    else { return false }
                    return changes[old] != nil
                },
                replacement: { link in
                    guard let old = index.resolve(link, from: source)?.relativePath,
                          let new = changes[old]
                    else { return link.target }
                    return WikiLinkParser.retargeted(
                        link.target, to: new, asPath: !nameFinds(new)
                    )
                }
            )
            guard result.count > 0, result.text != original else { continue }
            plans.append(Rewrite(
                note: source, original: original, rewritten: result.text, links: result.count
            ))
        }
        return plans
    }

    // MARK: - Doing it

    /// Writes the rewrites, addressing each note by where it is *now*.
    ///
    /// A note that moved with a folder is at its new path by the time this
    /// runs. A note whose text no longer matches what was planned from is left
    /// alone: an edit that arrived in between is somebody's work, and half of
    /// it plus half of this is worse than neither.
    public static func apply(
        _ rewrites: [Rewrite], after changes: [String: String], vaultRoot: URL
    ) -> Summary {
        var summary = Summary()
        for plan in rewrites {
            let path = changes[plan.note.relativePath] ?? plan.note.relativePath
            let url = vaultRoot.appendingPathComponent(path)
            guard (try? String(contentsOf: url, encoding: .utf8)) == plan.original else {
                summary.skipped += 1
                continue
            }
            do {
                try plan.rewritten.writeNote(to: url)
                summary.links += plan.links
                summary.notes += 1
            } catch {
                summary.skipped += 1
            }
        }
        return summary
    }

    /// The whole operation, for a caller with no windows to worry about.
    ///
    /// The move happens first and the links are repointed after, which is the
    /// order the editor uses: a rewrite planned against the old paths is
    /// applied to notes at their new ones, and a note that fails to move leaves
    /// no half-repointed vault behind.
    public static func perform(
        item: VaultItem,
        to newPath: String,
        index: VaultIndex,
        vaultRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Summary {
        guard !newPath.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.emptyName }
        let target = vaultRoot.appendingPathComponent(newPath)
        // A change of case alone finds the item itself on a case-insensitive
        // volume, and moving it there is the rename.
        guard !fileManager.fileExists(atPath: target.path) || isSameFile(target, item.url) else {
            throw Failure.alreadyExists(newPath)
        }

        let changes = changes(for: item, movingTo: newPath)
        let planned = try rewrites(for: changes, in: index) {
            try String(contentsOf: $0.url, encoding: .utf8)
        }

        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: item.url, to: target)
        return apply(planned, after: changes, vaultRoot: vaultRoot)
    }

    private static func isSameFile(_ one: URL, _ other: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let first = try? one.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let second = try? other.resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return first.isEqual(second)
    }
}
