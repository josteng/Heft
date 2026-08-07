import Foundation

/// A file the index can resolve a link to.
public struct NoteRef: Hashable, Identifiable, Sendable {
    public let relativePath: String
    public let url: URL
    /// Filename without a markdown extension; for attachments, the full filename.
    public let name: String
    public let kind: VaultItem.Kind

    public init(relativePath: String, url: URL, name: String, kind: VaultItem.Kind) {
        self.relativePath = relativePath
        self.url = url
        self.name = name
        self.kind = kind
    }

    public init(item: VaultItem) {
        self.init(
            relativePath: item.relativePath, url: item.url,
            name: item.name, kind: item.kind
        )
    }

    /// Builds a reference for a file that may not be in the index yet, such as
    /// a note created moments ago.
    public init?(url: URL, vaultRoot: URL) {
        let root = vaultRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let kind = VaultScanner.classify(extension: url.pathExtension.lowercased())
        self.init(
            relativePath: relative,
            url: url,
            name: kind == .markdown ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
            kind: kind
        )
    }

    public var id: String { relativePath }
    public var isMarkdown: Bool { kind == .markdown }
    /// Folder shown as link context, empty for root-level notes.
    public var folder: String {
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }
}

/// One incoming reference, with the line it appeared on.
public struct Backlink: Identifiable, Sendable {
    public let source: NoteRef
    public let line: Int
    public let context: String
    public let link: WikiLink
    public var id: String { "\(source.relativePath)#\(line)#\(link.target)" }
}

/// Vault-wide link graph.
///
/// Built off the main thread from a full scan, then treated as immutable; a
/// change on disk produces a new index rather than mutating this one, which
/// keeps readers on the main thread free of locking.
public final class VaultIndex: @unchecked Sendable {

    public let notes: [NoteRef]
    /// Every file, including attachments, keyed for resolution.
    public let allFiles: [NoteRef]

    private let byPath: [String: NoteRef]       // lowercased relative path, with and without .md
    private let byName: [String: [NoteRef]]     // lowercased basename
    private let outgoingByPath: [String: [WikiLink]]
    private let backlinksByPath: [String: [Backlink]]

    public static let empty = VaultIndex(
        notes: [], allFiles: [], byPath: [:], byName: [:], outgoing: [:], backlinks: [:]
    )

    private init(
        notes: [NoteRef], allFiles: [NoteRef],
        byPath: [String: NoteRef], byName: [String: [NoteRef]],
        outgoing: [String: [WikiLink]], backlinks: [String: [Backlink]]
    ) {
        self.notes = notes
        self.allFiles = allFiles
        self.byPath = byPath
        self.byName = byName
        self.outgoingByPath = outgoing
        self.backlinksByPath = backlinks
    }

    // MARK: - Building

    public static func build(root: VaultItem) -> VaultIndex {
        let files = root.flattened().filter { !$0.isFolder }

        var allFiles: [NoteRef] = []
        var byPath: [String: NoteRef] = [:]
        var byName: [String: [NoteRef]] = [:]

        for item in files {
            let ref = NoteRef(
                relativePath: item.relativePath, url: item.url,
                name: item.name, kind: item.kind
            )
            allFiles.append(ref)

            let lowerPath = item.relativePath.lowercased()
            byPath[lowerPath] = ref
            // `[[folder/Note]]` omits the extension, so index that spelling too.
            if item.isMarkdown {
                byPath[(lowerPath as NSString).deletingPathExtension] = ref
            }
            byName[item.name.lowercased(), default: []].append(ref)
        }

        // Prefer the shallowest, then shortest path when a basename is ambiguous.
        for key in byName.keys {
            byName[key]?.sort { a, b in
                let da = a.relativePath.count(where: { $0 == "/" })
                let db = b.relativePath.count(where: { $0 == "/" })
                if da != db { return da < db }
                return a.relativePath.count < b.relativePath.count
            }
        }

        let notes = allFiles.filter(\.isMarkdown)
        let partial = VaultIndex(
            notes: notes, allFiles: allFiles, byPath: byPath, byName: byName,
            outgoing: [:], backlinks: [:]
        )

        // Second pass: read note bodies and build the link graph. Resolution
        // needs the tables above, hence the two passes.
        var outgoing: [String: [WikiLink]] = [:]
        var backlinks: [String: [Backlink]] = [:]

        for note in notes {
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            var links: [WikiLink] = []

            NoteText.forEachProseLine(text) { lineNumber, line in
                for link in WikiLinkParser.links(in: line) {
                    links.append(link)
                    guard let target = partial.resolve(link, from: note) else { continue }
                    backlinks[target.relativePath, default: []].append(Backlink(
                        source: note,
                        line: lineNumber,
                        context: line.trimmingCharacters(in: .whitespaces),
                        link: link
                    ))
                }
            }
            if !links.isEmpty { outgoing[note.relativePath] = links }
        }

        return VaultIndex(
            notes: notes, allFiles: allFiles, byPath: byPath, byName: byName,
            outgoing: outgoing, backlinks: backlinks
        )
    }

    // MARK: - Queries

    /// Resolves a wikilink the way Obsidian does: an explicit path wins, then a
    /// basename match, preferring the shallowest file. `from` handles the
    /// `[[#Heading]]` case, which points into the current note.
    public func resolve(_ link: WikiLink, from source: NoteRef?) -> NoteRef? {
        let target = link.target.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return source }

        let lower = target.lowercased()

        if let hit = byPath[lower] { return hit }
        // A link written without an extension to a markdown file.
        if byPath[lower + ".md"] != nil { return byPath[lower + ".md"] }

        // Basename lookup, which is how most Obsidian links are written.
        let base = (lower as NSString).lastPathComponent
        if let candidates = byName[base], let first = candidates.first {
            // If the link carried a folder, prefer a candidate under it.
            if target.contains("/") {
                if let scoped = candidates.first(where: { $0.relativePath.lowercased().hasSuffix(lower) }) {
                    return scoped
                }
                if let scoped = candidates.first(where: { $0.relativePath.lowercased().hasSuffix(lower + ".md") }) {
                    return scoped
                }
            }
            return first
        }
        // Attachments are linked with their extension, already covered by byName,
        // but a link may differ in extension case only.
        let withoutExt = (base as NSString).deletingPathExtension
        if let candidates = byName[withoutExt], let first = candidates.first { return first }

        return nil
    }

    public func note(atRelativePath path: String) -> NoteRef? {
        byPath[path.lowercased()]
    }

    public func backlinks(to path: String) -> [Backlink] {
        backlinksByPath[path] ?? []
    }

    public func outgoingLinks(from path: String) -> [WikiLink] {
        outgoingByPath[path] ?? []
    }

    /// Links in `path` that point nowhere; offered as "create this note".
    public func unresolvedLinks(from path: String, source: NoteRef?) -> [WikiLink] {
        outgoingLinks(from: path).filter { resolve($0, from: source) == nil && !$0.target.isEmpty }
    }

    /// Conservative filename search for Quick Open and the sidebar. Literal
    /// matches rank first; compact or word-boundary fuzzy matches are accepted,
    /// while loose subsequences such as `eee` across a long title are rejected.
    public func search(_ query: String, limit: Int = 50) -> [NoteRef] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return Array(notes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(limit))
        }
        var scored: [(NoteRef, Int)] = []
        for note in notes {
            let name = note.name.lowercased()
            let score: Int
            if name == q { score = 400 }
            else if name.hasPrefix(q) { score = 300 }
            else if name.contains(q) { score = 200 }
            else if let fuzzy = FuzzyMatch.score(query: q, candidate: name),
                    fuzzy >= max(36, q.count * 16) {
                score = 100 + fuzzy
            }
            else { continue }
            scored.append((note, score))
        }
        return scored
            .sorted { a, b in a.1 == b.1 ? a.0.name.count < b.0.name.count : a.1 > b.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// Subsequence matcher scoring contiguous runs and word-boundary hits higher,
/// which is what makes "dn" find "Daily Notes" ahead of "Down".
enum FuzzyMatch {
    static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query), c = Array(candidate)
        var qi = 0, total = 0, streak = 0

        for (ci, ch) in c.enumerated() {
            guard qi < q.count, ch == q[qi] else { streak = 0; continue }
            var points = 10
            if ci == 0 { points += 15 }
            else if !c[ci - 1].isLetter && !c[ci - 1].isNumber { points += 10 }
            streak += 1
            points += min(streak, 5) * 3
            total += points
            qi += 1
        }

        guard qi == q.count else { return nil }
        // Shorter candidates win ties.
        return total - min(c.count / 4, 20)
    }
}
