import AppIntents
import CoreSpotlight
import Foundation

/// A note, as the system's intents see it.
///
/// This is what was missing for Siri: Heft's intents were four verbs with no
/// nouns, so there was no way to say *which* note. An entity gives every
/// intent a note-shaped parameter, and the system resolves the spoken or typed
/// name to one of these before the intent runs.
///
/// Identified by vault-relative path rather than by name, because two folders
/// may hold a `Notes.md` and an entity's id has to survive being stored in a
/// shortcut somebody wrote last month.
///
/// In `HeftCore`, not beside the intents, because both the app and the capture
/// extension need it and each declaring its own would put two entities of the
/// same name into one app's metadata. `AppIntents` is neither AppKit nor
/// SwiftUI, so the rule that keeps this module windowless still holds.
public struct NoteEntity: AppEntity, IndexedEntity, URLRepresentableEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Note", numericFormat: "\(placeholder: .int) notes"
    )
    public static let defaultQuery = NoteEntityQuery()

    /// The vault-relative path, extension included.
    public let id: String

    // Declared as properties, not plain stored values, because the metadata
    // the indexer reads lists exactly these: an entity with none is donated
    // with nothing to match against.
    /// The filename without its extension, which is what a note is called.
    @Property(title: "Name")
    public var name: String

    /// The containing folder, or empty at the vault root.
    @Property(title: "Folder")
    public var folder: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: folder.isEmpty ? nil : "\(folder)"
        )
    }

    public init(id: String, name: String, folder: String) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    public init(_ note: NoteRef) {
        self.init(id: note.relativePath, name: note.name, folder: note.folder)
    }

    /// What Spotlight, and through it Siri, is told about a note.
    ///
    /// This is the difference between a note Siri can be *given* and a note it
    /// can *find*. Without it the entity only ever fills a parameter of a Heft
    /// action; with it "find my note about the roof" reaches the vault at all.
    ///
    /// The body is deliberately absent. Spotlight already indexes the files
    /// themselves, so donating the text again would double every note in the
    /// results, and a vault is large enough for that to be the difference
    /// between a useful answer and a page of duplicates.
    public var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .plainText)
        set.title = name
        set.displayName = name
        set.relatedUniqueIdentifier = id
        if !folder.isEmpty { set.containerDisplayName = folder }
        set.keywords = folder.isEmpty ? [name] : [name, folder]
        return set
    }

    /// The `heft://` link that opens this note.
    ///
    /// What makes a note handed back by an intent clickable: Siri and
    /// Shortcuts both show a result card, and without a URL there is nothing
    /// for a tap on it to do. The scheme is already registered and already
    /// opens a note by vault-relative path.
    public static var urlRepresentation: URLRepresentation {
        "heft://open?path=\(.id)"
    }

    /// Where the note is now, given the vault it belongs to.
    ///
    /// Resolved on use rather than stored: a shortcut holding this entity
    /// outlives the path it was made from, and a stale absolute URL would
    /// write somewhere the vault no longer is.
    public func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(id)
    }
}

/// Finds the note a request is about, without waking the app.
///
/// Reading the vault from disk is the whole point: resolving "the note about
/// the roof" must not launch Heft, for the same reason a capture must not.
/// `VaultIndex` is the same index the app and `heft find` use, so a spoken
/// name resolves exactly as a typed one does in Quick Open.
public struct NoteEntityQuery: EntityQuery, EntityStringQuery, Sendable {
    /// How many notes a disambiguation list or a suggestion list is worth.
    /// Past this the list is not a choice, it is a directory.
    static let limit = 12

    public init() {}

    private var vault: URL? { CaptureVaultPreference.url }

    func vaultIndex() -> (root: URL, index: VaultIndex)? { index() }

    private func index() -> (root: URL, index: VaultIndex)? {
        guard let vault else { return nil }
        return (vault, VaultIndex.open(vaultAt: vault))
    }

    /// The entities behind ids a shortcut stored earlier.
    ///
    /// An id that no longer names a note is dropped rather than resolved to
    /// something near it: a shortcut that quietly starts appending to a
    /// different note is worse than one that stops working.
    public func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        guard let found = index() else { return [] }
        let byPath = Dictionary(
            found.index.notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byPath[$0].map(NoteEntity.init) }
    }

    /// What somebody said or typed, matched against note names.
    public func entities(matching string: String) async throws -> [NoteEntity] {
        guard let found = index() else { return [] }
        // The vault's own daily-note format, so "the note for September 13"
        // resolves to whatever this vault calls that day.
        let daily = DailyNotes(
            vaultRoot: found.root, settings: ObsidianSettings.load(vaultRoot: found.root)
        )
        return NoteMatching
            .notes(matching: string, in: found.index, limit: Self.limit, daily: daily)
            .map(NoteEntity.init)
    }

    /// What the picker offers before anything is typed: the notes this reader
    /// actually opens, which is the same ranking Quick Open opens on.
    public func suggestedEntities() async throws -> [NoteEntity] {
        guard let found = index() else { return [] }
        let ranked = FrecencyStore.notes(forVaultAt: found.root.path).ranked(
            found.index.notes,
            by: \.relativePath,
            tiebreak: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
        return Array(ranked.prefix(Self.limit).map(NoteEntity.init))
    }
}

/// Turning what somebody said into the note they meant.
///
/// Separate from the query so it can be tested without a vault preference and
/// without the system: the interesting part is the matching, not the lookup.
public enum NoteMatching {

    /// The index's own matcher first, so a spoken name resolves exactly as a
    /// typed one does in Quick Open. Failing that, every note whose name
    /// holds all of the words, which is what makes "the roof note" find one
    /// called "Roof repair" while "roof shed" finds neither.
    ///
    /// Word-wise rather than substring-wise on the whole phrase, because
    /// speech puts words in an order the filename does not have.
    public static func notes(
        matching string: String, in index: VaultIndex, limit: Int, daily: DailyNotes? = nil
    ) -> [NoteRef] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if let exact = index.note(named: query) { return [exact] }

        // A date said out loud never matches the file it names. "September 13,
        // 2026" shares no word with `2026-09-13`, so asking for a daily note
        // by date found nothing at all until the date was resolved through the
        // vault's own daily-note format first.
        if let daily, let date = self.date(in: query) ?? impliedDay(in: query),
           let note = index.notes.first(where: { $0.relativePath == daily.relativePath(for: date) }) {
            return [note]
        }
        // A date that names no daily note falls through rather than stopping:
        // a note actually called "September 13 meeting" is still the best
        // answer to a question about that day.

        let words = self.words(in: query)
        guard !words.isEmpty else { return [] }
        // The folder counts as well as the name. A vault keeps a subject in a
        // folder and names the notes inside it for their parts, so asking for
        // "thesis" has to find `Thesis/Chapter 1`, whose name says nothing
        // about a thesis at all.
        let matches = index.notes.filter { note in
            let haystack = (note.folder + "/" + note.name).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        // A hit on the name beats one that only matched the folder, then
        // shortest first: "Roof" answers "roof" better than "Roof repair
        // quotes from three builders" does.
        func named(_ note: NoteRef) -> Bool {
            let name = note.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return Array(
            matches
                .sorted {
                    if named($0) != named($1) { return named($0) }
                    return ($0.name.count, $0.name) < ($1.name.count, $1.name)
                }
                .prefix(limit)
        )
    }

    /// The date a phrase names, if it names one.
    ///
    /// `NSDataDetector` rather than a list of formats: it reads "September
    /// 13, 2026", "13 September" and "13/9/2026" alike, in the reader's
    /// locale, which is the whole range of ways somebody says a day out loud.
    static func date(in query: String) -> Date? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }
        let range = NSRange(query.startIndex..., in: query)
        return detector.firstMatch(in: query, options: [], range: range)?.date
    }

    /// The day a phrase means when it names no date at all.
    ///
    /// "My daily note" and "today's note" are how people ask for it, and
    /// neither holds a date for a detector to find: the daily notes are called
    /// `2026-09-20`, so matching by words finds nothing and the answer came
    /// back "I can't find a daily note".
    static func impliedDay(in query: String) -> Date? {
        let words = Set(self.words(in: query))
        guard words.contains("daily") || words.contains("today")
            || words.contains("todays") || words.contains("journal")
        else { return nil }
        return Date()
    }

    /// The words to match a name against.
    ///
    /// Punctuation is dropped, or "September 13," looks for a name holding a
    /// comma and finds nothing.
    static func words(in query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Telling Spotlight what is in the vault.
///
/// Donated from the app rather than the extension: the app is the process that
/// already knows when the vault changed, and the extension exists to be brief.
///
/// A *named* index, never `CSSearchableIndex.default()`. Apple's macOS 27
/// documentation says in as many words not to ship the default one: it is for
/// prototyping, and a named index is the app's own store.
///
/// Through `indexAppEntities` rather than hand-built `CSSearchableItem`s. On
/// macOS 27 content indexed the old way is retrievable by a query but does not
/// reach Spotlight, while an `IndexedEntity` does, so the tidier call is also
/// the working one.
///
/// Every note every time, rather than a diff. Indexing is a replace by
/// identifier and a vault is small enough that the whole set costs less than
/// working out which notes moved; a rename would otherwise leave the old
/// identifier behind, findable and wrong.
public enum NoteIndexing {

    /// The app's own index. Named for the same reason a folder is: so that
    /// what Heft put there can be replaced or dropped as one.
    public static let indexName = "dev.stenglein.Heft.notes"

    public static var index: CSSearchableIndex { CSSearchableIndex(name: indexName) }

    /// Hands the vault's notes to Spotlight, and says how many went.
    ///
    /// On macOS 27 what goes is the schema note, body included, because
    /// that is the one Apple describes Siri reasoning over: "conform your
    /// schematized entity to the IndexedEntity protocol". Without the vault
    /// root, or on 26, the plain entity goes, which is a name Siri can find.
    @discardableResult
    public static func donate(
        _ notes: [NoteRef], in vaultRoot: URL? = nil, vaultIndex: VaultIndex? = nil,
        to index: CSSearchableIndex? = nil
    ) async -> Int {
        guard !notes.isEmpty else { return 0 }
        do {
            if #available(macOS 27.0, *), let vaultRoot {
                let shared = vaultIndex ?? VaultIndex.open(vaultAt: vaultRoot)
                let entities = notes.map { SiriNoteEntity($0, in: vaultRoot, index: shared) }
                try await (index ?? Self.index).indexAppEntities(entities)
            } else {
                try await (index ?? Self.index).indexAppEntities(notes.map(NoteEntity.init))
            }
            return notes.count
        } catch {
            // Indexing is an improvement, never a requirement: a vault that
            // cannot be donated still opens, searches and captures.
            return 0
        }
    }
}

/// Spotlight asking for the index to be rebuilt, which is the other half of
/// donating: without it the system only ever has what Heft last pushed, and
/// can never ask for what it is missing.
///
/// Gated, because `CSSearchableIndexDescription` arrived in macOS 27 and Heft
/// still runs on 26, where donating alone is all there is.
@available(macOS 27.0, *)
extension NoteEntityQuery: IndexedEntityQuery {

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        guard let found = vaultIndex() else { return }
        await NoteIndexing.donate(found.index.notes, in: found.root, vaultIndex: found.index)
    }

    public func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        guard let found = vaultIndex() else { return }
        let wanted = Set(identifiers)
        await NoteIndexing.donate(
            found.index.notes.filter { wanted.contains($0.relativePath) },
            in: found.root, vaultIndex: found.index
        )
    }
}
