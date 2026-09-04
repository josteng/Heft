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
    /// Lowercased tag to the notes carrying it, and the display spelling of
    /// each tag — the first one seen wins, so `#Project` and `#project` are one
    /// tag shown the way the vault first wrote it.
    private let notesByTag: [String: [NoteRef]]
    private let tagSpelling: [String: String]
    private let tagsByPath: [String: [String]]
    /// Where the notes in each folder already keep their attachments: the
    /// note's folder, then the attachment's folder, then how many references.
    ///
    /// Counted from the same read that builds the link graph, so it costs
    /// nothing beyond the parse — the bargain tags already take. Counting any
    /// mention of an attachment's filename rather than embeds alone is what
    /// makes it see a vault that keeps book covers in a `Cover:` property.
    private let attachmentUsage: [String: [String: Int]]

    public static let empty = VaultIndex(
        notes: [], allFiles: [], byPath: [:], byName: [:], outgoing: [:], backlinks: [:],
        notesByTag: [:], tagSpelling: [:], tagsByPath: [:], attachmentUsage: [:]
    )

    private init(
        notes: [NoteRef], allFiles: [NoteRef],
        byPath: [String: NoteRef], byName: [String: [NoteRef]],
        outgoing: [String: [WikiLink]], backlinks: [String: [Backlink]],
        notesByTag: [String: [NoteRef]], tagSpelling: [String: String],
        tagsByPath: [String: [String]], attachmentUsage: [String: [String: Int]]
    ) {
        self.notes = notes
        self.allFiles = allFiles
        self.byPath = byPath
        self.byName = byName
        self.outgoingByPath = outgoing
        self.backlinksByPath = backlinks
        self.notesByTag = notesByTag
        self.tagSpelling = tagSpelling
        self.tagsByPath = tagsByPath
        self.attachmentUsage = attachmentUsage
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
            outgoing: [:], backlinks: [:], notesByTag: [:], tagSpelling: [:],
            tagsByPath: [:], attachmentUsage: [:]
        )

        // Second pass: read note bodies and build the link graph. Resolution
        // needs the tables above, hence the two passes.
        var outgoing: [String: [WikiLink]] = [:]
        var backlinks: [String: [Backlink]] = [:]
        var notesByTag: [String: [NoteRef]] = [:]
        var tagSpelling: [String: String] = [:]
        var tagsByPath: [String: [String]] = [:]
        var attachmentUsage: [String: [String: Int]] = [:]

        // Basename to the folders holding a file of that name. Attachments
        // only: a note mentioning another note says nothing about where files
        // are kept.
        var attachmentFolders: [String: Set<String>] = [:]
        for file in allFiles where !file.isMarkdown {
            attachmentFolders[file.name.lowercased(), default: []].insert(file.folder)
        }

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

            // Where this note keeps its attachments, from the same read.
            if !attachmentFolders.isEmpty {
                for name in AttachmentNames.mentioned(in: text) {
                    guard let folders = attachmentFolders[name] else { continue }
                    for folder in folders {
                        attachmentUsage[note.folder, default: [:]][folder, default: 0] += 1
                    }
                }
            }

            // Tags come from the same read, so indexing them costs nothing
            // beyond the parse.
            let tags = NoteTags.all(in: text)
            if !tags.isEmpty {
                tagsByPath[note.relativePath] = tags
                for tag in tags {
                    let key = tag.lowercased()
                    notesByTag[key, default: []].append(note)
                    // First spelling seen wins, so `#Project` and `#project`
                    // are one tag rather than two that differ only in case.
                    if tagSpelling[key] == nil { tagSpelling[key] = tag }
                }
            }
        }

        return VaultIndex(
            notes: notes, allFiles: allFiles, byPath: byPath, byName: byName,
            outgoing: outgoing, backlinks: backlinks,
            notesByTag: notesByTag, tagSpelling: tagSpelling, tagsByPath: tagsByPath,
            attachmentUsage: attachmentUsage
        )
    }

    /// The folder the notes at or under `folder` most often keep attachments
    /// in, looking one level further up each time nothing is found.
    ///
    /// The vault root is deliberately never consulted as a *level*. Aggregated
    /// there, the answer is whatever the busiest corner of the vault does, so a
    /// daily note in a vault with a large thesis folder would be told to file
    /// its screenshots with the thesis. A folder that has never held an
    /// attachment has no habit, and saying so lets the next rule answer.
    public func attachmentDestination(near folder: String) -> String? {
        var level = folder
        while !level.isEmpty {
            var totals: [String: Int] = [:]
            for (noteFolder, destinations) in attachmentUsage
            where noteFolder == level || noteFolder.hasPrefix(level + "/") {
                for (destination, count) in destinations {
                    totals[destination, default: 0] += count
                }
            }
            // Ties break on the name, so the answer cannot change between two
            // runs over an unchanged vault.
            if let best = totals.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
                return best.key
            }
            guard let slash = level.lastIndex(of: "/") else { break }
            level = String(level[level.startIndex..<slash])
        }
        return nil
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

    /// Filename candidates for an inline `[[…]]` / `![[…]]` completion.
    /// Embeds additionally offer files Heft can actually present inline.
    public func linkSuggestions(
        matching query: String, forEmbed: Bool, limit: Int = 8
    ) -> [NoteRef] {
        let candidates = forEmbed
            ? allFiles.filter { $0.isMarkdown || $0.kind == .image || $0.kind == .pdf }
            : notes
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return Array(candidates.sorted(by: suggestionOrder).prefix(limit))
        }

        var scored: [(ref: NoteRef, score: Int)] = []
        for ref in candidates {
            let name = ref.name.lowercased()
            let path = ref.relativePath.lowercased()
            let score: Int
            if name == q { score = 500 }
            else if name.hasPrefix(q) { score = 400 }
            else if name.contains(q) { score = 300 }
            else if path.contains(q) { score = 220 }
            else if let fuzzy = FuzzyMatch.score(query: q, candidate: name),
                    fuzzy >= max(36, q.count * 16) {
                score = 100 + fuzzy
            } else { continue }
            scored.append((ref, score))
        }
        return scored.sorted { left, right in
            left.score == right.score
                ? suggestionOrder(left.ref, right.ref)
                : left.score > right.score
        }
        .prefix(limit)
        .map(\.ref)
    }

    /// Uses a short basename when it resolves uniquely, otherwise a path.
    /// Markdown paths omit `.md`, matching Obsidian's normal link spelling.
    public func linkDestination(for ref: NoteRef) -> String {
        let key = ref.name.lowercased()
        let sameName = byName[key] ?? []
        guard sameName.count > 1 else { return ref.name }
        return ref.isMarkdown
            ? (ref.relativePath as NSString).deletingPathExtension
            : ref.relativePath
    }

    private func suggestionOrder(_ left: NoteRef, _ right: NoteRef) -> Bool {
        let nameOrder = left.name.localizedStandardCompare(right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
    }

    // MARK: Tags

    /// Every tag in the vault, most used first, then alphabetically.
    public var allTags: [String] {
        var counted: [(name: String, count: Int)] = []
        counted.reserveCapacity(notesByTag.count)
        for (key, notes) in notesByTag {
            counted.append((tagSpelling[key] ?? key, notes.count))
        }
        counted.sort { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return counted.map(\.name)
    }

    /// Tags whose name contains `query`. An empty query returns all of them.
    ///
    /// Nested tags match on any segment, so `#work/admin` is found by "admin"
    /// as well as by "work".
    public func tags(matching query: String) -> [String] {
        let needle = NoteTags.normalise(query).lowercased()
        guard !needle.isEmpty else { return allTags }
        return allTags.filter { $0.lowercased().contains(needle) }
    }

    public func notes(taggedWith tag: String) -> [NoteRef] {
        notesByTag[NoteTags.normalise(tag).lowercased()] ?? []
    }

    public func tags(of path: String) -> [String] {
        tagsByPath[path] ?? []
    }

    public func noteCount(forTag tag: String) -> Int {
        notes(taggedWith: tag).count
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
    /// - Parameter familiarity: a note's raw frecency score, which this uses
    ///   two different ways.
    ///
    ///   With something typed it is a tie-break worth at most `boostWeight`,
    ///   which is less than the gap between any two match tiers: familiarity
    ///   reorders results *within* a tier and can never lift a substring match
    ///   above a prefix one, so an unfamiliar note that matches better still
    ///   wins and typing stays predictable. It saturates at `wellUsed`,
    ///   because past that point one heavily-used note would sit at the top of
    ///   every search it matched at all.
    ///
    ///   With nothing typed it is the whole ranking, **unsaturated**. That
    ///   distinction is the bug this parameter used to have: the caller
    ///   saturated before handing the score over, so every note used four or
    ///   more times tied at the ceiling and the empty list fell through to the
    ///   alphabetical tiebreak — a switcher that claimed to open on what you
    ///   use and did not. Both rules live here now, where one of them cannot
    ///   be applied without the other being considered.
    public static let boostWeight = 60

    /// Uses within a half-life past which a note is simply "familiar".
    public static let wellUsed: Double = 4

    public func search(
        _ query: String,
        limit: Int = 50,
        familiarity: ((NoteRef) -> Double)? = nil
    ) -> [NoteRef] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            let alphabetical = notes.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            // With nothing typed there is no match to rank by, so this is
            // *only* the boost: what you use, most-used first. Alphabetical
            // order is the fallback for everything unused, and the whole list
            // for a vault nobody has opened yet.
            guard let familiarity else { return Array(alphabetical.prefix(limit)) }
            // Sorted with the original index as the tiebreak, because Swift's
            // sort is not stable: without it every note scoring zero — which
            // in a fresh vault is all of them — would come back in whatever
            // order the sort happened to leave them, and the list would
            // reshuffle itself between openings.
            var byFamiliarity: [(offset: Int, note: NoteRef, score: Double)] = []
            byFamiliarity.reserveCapacity(alphabetical.count)
            for (offset, note) in alphabetical.enumerated() {
                byFamiliarity.append((offset, note, familiarity(note)))
            }
            byFamiliarity.sort { left, right in
                left.score == right.score ? left.offset < right.offset : left.score > right.score
            }
            return byFamiliarity.prefix(limit).map(\.note)
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
            let known = familiarity.map {
                Int(($0(note) / Self.wellUsed).clamped(to: 0...1) * Double(Self.boostWeight))
            } ?? 0
            scored.append((note, score + known))
        }
        return scored.enumerated()
            .sorted { a, b in
                if a.element.1 != b.element.1 { return a.element.1 > b.element.1 }
                if a.element.0.name.count != b.element.0.name.count {
                    return a.element.0.name.count < b.element.0.name.count
                }
                return a.offset < b.offset
            }
            .map(\.element)
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

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
