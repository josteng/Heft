import Foundation

/// The notes worth answering a question with.
///
/// What Siri has when it cannot search the vault itself: an intent that takes
/// what was asked and hands back the notes, which Siri then shows as cards
/// and reads. Named notes first, since a note called "Thesis" is the answer
/// to "thesis" before any note that mentions it; after those, the notes that
/// mention it most, by lines rather than by occurrences, so one line that
/// repeats the word does not beat a note that keeps coming back to it. The
/// same order `heft find --files` reports.
public enum NoteFinding {

    public static func notes(matching query: String, in index: VaultIndex, limit: Int) -> [NoteRef] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, limit > 0 else { return [] }

        var found = NoteMatching.notes(matching: term, in: index, limit: limit)
        var seen = Set(found.map(\.relativePath))

        let byPath = Dictionary(
            index.notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // A line cap of one: only the per-note tallies are wanted, and they
        // are counted for the whole vault whatever the cap.
        let content = ContentSearch.run(notes: index.notes, query: term, limit: 1)
        for tally in content.tallies where found.count < limit {
            guard !seen.contains(tally.path), let note = byPath[tally.path] else { continue }
            found.append(note)
            seen.insert(tally.path)
        }
        return Array(found.prefix(limit))
    }
}
