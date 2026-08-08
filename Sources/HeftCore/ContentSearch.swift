import Foundation

/// One line of one note that matched a search.
public struct ContentMatch: Identifiable, Sendable {
    public let note: NoteRef
    /// 1-based, to match what an editor's gutter would show.
    public let line: Int
    /// The line, trimmed and window-cropped around the first match.
    public let preview: String
    public let occurrences: Int

    public var id: String { "\(note.relativePath)#\(line)" }

    public init(note: NoteRef, line: Int, preview: String, occurrences: Int) {
        self.note = note
        self.line = line
        self.preview = preview
        self.occurrences = occurrences
    }
}

public struct ContentSearchResult: Sendable {
    public let query: String
    public let matches: [ContentMatch]
    public let totalOccurrences: Int
    public let matchedNotes: Int

    public static func empty(_ query: String = "") -> Self {
        ContentSearchResult(query: query, matches: [], totalOccurrences: 0, matchedNotes: 0)
    }

    public init(query: String, matches: [ContentMatch], totalOccurrences: Int, matchedNotes: Int) {
        self.query = query
        self.matches = matches
        self.totalOccurrences = totalOccurrences
        self.matchedNotes = matchedNotes
    }
}

/// Literal, case-insensitive full-text search across a vault.
///
/// Deliberately not indexed. A vault is a few hundred files of a few kilobytes
/// each, so reading them all costs less than keeping a search index correct
/// across external edits arriving over iCloud. This runs off the main thread;
/// callers debounce it.
public enum ContentSearch {

    public static func run(
        notes: [NoteRef], query: String, limit: Int = 500
    ) -> ContentSearchResult {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .empty(query) }

        var matches: [ContentMatch] = []
        var totalOccurrences = 0
        var matchedNotes = Set<String>()

        for note in notes {
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let occurrences = occurrenceCount(of: term, in: rawLine)
                guard occurrences > 0 else { continue }
                totalOccurrences += occurrences
                matchedNotes.insert(note.relativePath)
                let preview = contextPreview(in: rawLine, query: term)
                matches.append(ContentMatch(
                    note: note, line: offset + 1,
                    preview: preview.isEmpty ? "Empty line" : preview,
                    occurrences: occurrences
                ))
            }
        }

        // A hit in a note whose *name* also matches is almost always the one
        // being looked for, so filename rank outranks occurrence count.
        let lowered = term.lowercased()
        matches.sort { left, right in
            let leftRank = filenameRank(left.note.name, query: lowered)
            let rightRank = filenameRank(right.note.name, query: lowered)
            if leftRank != rightRank { return leftRank > rightRank }
            if left.occurrences != right.occurrences { return left.occurrences > right.occurrences }
            let order = left.note.relativePath.localizedStandardCompare(right.note.relativePath)
            if order != .orderedSame { return order == .orderedAscending }
            return left.line < right.line
        }

        return ContentSearchResult(
            query: query,
            matches: Array(matches.prefix(limit)),
            totalOccurrences: totalOccurrences,
            matchedNotes: matchedNotes.count
        )
    }

    static func filenameRank(_ name: String, query: String) -> Int {
        let candidate = name.lowercased()
        if candidate == query { return 3 }
        if candidate.hasPrefix(query) { return 2 }
        if candidate.contains(query) { return 1 }
        return 0
    }

    public static func occurrenceCount(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var remainder = text[...]
        while let range = remainder.range(of: query, options: [.caseInsensitive, .literal]) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }

    /// A window of the line around its first match, so a hit deep in a long
    /// paragraph is still visible in a one-line preview.
    public static func contextPreview(in line: String, query: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: query, options: [.caseInsensitive, .literal]) else {
            return trimmed.isEmpty ? "Empty line" : trimmed
        }

        let matchStart = trimmed.distance(from: trimmed.startIndex, to: match.lowerBound)
        let matchEnd = trimmed.distance(from: trimmed.startIndex, to: match.upperBound)
        let startOffset = max(0, matchStart - 55)
        let endOffset = min(trimmed.count, matchEnd + 95)
        let start = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
        let end = trimmed.index(trimmed.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "")
            + trimmed[start..<end]
            + (endOffset < trimmed.count ? "…" : "")
    }
}
