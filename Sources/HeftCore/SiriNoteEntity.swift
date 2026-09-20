import AppIntents
import CoreSpotlight
import Foundation

// The Notes assistant schema's nouns, which is what lets Siri map a phrasing
// nobody registered onto Heft. Everything here is macOS 27 only: the macOS
// 26 schema set has no Notes domain at all, so `NoteEntity` and the plain
// intents remain the ones that work on both.
//
// In `HeftCore`, for the reason `NoteEntity` is: the extension creates and
// appends to one of these, and the app is the process that can open one,
// so both need the type, and each declaring its own would put two entities
// of the same name into one app's metadata.
//
// Two of the schema's fields describe a vault Heft does not have. `isPinned`
// is always false, because pinning is an Apple Notes idea and there is no
// equivalent here. An account is one synthetic stand-in for the vault itself,
// since the schema puts folders inside accounts and Heft has one vault.

@available(macOS 27.0, *)
@AppEntity(schema: .notes.account)
public struct SiriAccountEntity {
    public static let isAssistantOnly = true
    public static let defaultQuery = SiriAccountQuery()

    public let id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    @Property(title: "Name") public var name: String

    public init(vault: URL) {
        id = vault.path
        name = vault.lastPathComponent
    }
}

@available(macOS 27.0, *)
public struct SiriAccountQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [SiriAccountEntity] {
        guard let vault = CaptureVaultPreference.url, identifiers.contains(vault.path) else { return [] }
        return [SiriAccountEntity(vault: vault)]
    }

    public func entities(matching string: String) async throws -> [SiriAccountEntity] {
        try await suggestedEntities().filter {
            $0.name.localizedCaseInsensitiveContains(string)
        }
    }

    public func suggestedEntities() async throws -> [SiriAccountEntity] {
        CaptureVaultPreference.url.map { [SiriAccountEntity(vault: $0)] } ?? []
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .notes.folder)
public struct SiriFolderEntity: IndexedEntity {
    public static let isAssistantOnly = true
    public static let defaultQuery = SiriFolderQuery()

    /// The vault-relative folder path; the vault root is the empty string.
    public let id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    @Property(title: "Name") public var name: String
    @Property(title: "Account") public var account: SiriAccountEntity?
    @Property(title: "Parent Folder") public var parentFolder: SiriFolderEntity?

    public init(path: String, vault: URL) {
        id = path
        name = path.isEmpty ? vault.lastPathComponent : (path as NSString).lastPathComponent
        account = SiriAccountEntity(vault: vault)
        let parent = (path as NSString).deletingLastPathComponent
        parentFolder = path.isEmpty ? nil : SiriFolderEntity(path: parent, vault: vault)
    }
}

@available(macOS 27.0, *)
public struct SiriFolderQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [SiriFolderEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        let known = Set(SiriSchemaVault.folders(in: vault))
        return identifiers.filter(known.contains).map { SiriFolderEntity(path: $0, vault: vault) }
    }

    public func entities(matching string: String) async throws -> [SiriFolderEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        return SiriSchemaVault.folders(in: vault)
            .filter { $0.localizedCaseInsensitiveContains(string) }
            .prefix(12)
            .map { SiriFolderEntity(path: $0, vault: vault) }
    }

    public func suggestedEntities() async throws -> [SiriFolderEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        return SiriSchemaVault.folders(in: vault).prefix(12).map {
            SiriFolderEntity(path: $0, vault: vault)
        }
    }
}

/// The vault, read the way the schema entities need it.
@available(macOS 27.0, *)
enum SiriSchemaVault {
    static func folders(in vault: URL) -> [String] {
        let index = VaultIndex.open(vaultAt: vault)
        var seen: Set<String> = [""]
        for note in index.notes where !note.folder.isEmpty {
            var path = note.folder
            while !path.isEmpty {
                seen.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return seen.sorted()
    }

    /// A note's attachments: the files it links to that are not notes.
    ///
    /// Read from the link index rather than by parsing again, so the answer
    /// matches what `heft links` reports and what the sidebar shows.
    static func attachments(of note: NoteRef, in vault: URL, index: VaultIndex? = nil) -> [IntentFile] {
        let index = index ?? VaultIndex.open(vaultAt: vault)
        let targets = index.outgoingLinks(from: note.relativePath).map(\.target)
        guard !targets.isEmpty else { return [] }
        let byName = Dictionary(
            index.allFiles.filter { !$0.isMarkdown }.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return targets.compactMap { target -> IntentFile? in
            guard let file = byName[(target as NSString).lastPathComponent.lowercased()],
                  let data = try? Data(contentsOf: file.url)
            else { return nil }
            return IntentFile(data: data, filename: file.name)
        }
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .notes.note)
public struct SiriNoteEntity: IndexedEntity {
    // No `isAssistantOnly` here. It is documented only for intents, as a
    // temporary measure that hides one from Shortcuts, and no Apple sample
    // sets it on an entity. An entity Siri is meant to resolve should not be
    // the place to try it.
    //
    // `IndexedEntity`, and so is the folder, for two reasons that happen to
    // agree. Apple's recipe for a note Siri can find is a schema entity that
    // is also indexed. And the metadata processor demands, of any entity a
    // schema intent takes, one of a few conformances or a default string
    // query *it can see*; with the query in this module and the intent in
    // another, it cannot, and the conformance is the one it checks on the
    // entity itself.
    public static let defaultQuery = SiriNoteQuery()

    // A tappable result card comes from an `OpenIntent` whose target is this
    // type, not from a URL on the entity. Opening needs a window, so that
    // intent is in the app, which is why this type is not in the extension.

    /// The vault-relative path, as `NoteEntity` uses.
    public let id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    // Indexing keys on the name and the body, which is what lets Siri answer
    // from a note rather than merely find it. Apple: "The indexingKey tells
    // Spotlight which properties, like the message body, should be
    // searchable. Once indexed, Siri can search your content, reason over
    // it, and use it to answer questions."
    @Property(title: "Name", indexingKey: \.displayName) public var name: String
    @Property(title: "Content", indexingKey: \.textContent) public var content: String?
    @Property(title: "Created") public var creationDate: Date?
    @Property(title: "Modified") public var modificationDate: Date?
    /// Always false: pinning is an Apple Notes idea with no equivalent here.
    @Property(title: "Pinned") public var isPinned: Bool
    @Property(title: "Folder") public var folder: SiriFolderEntity?
    @Property(title: "Attachments") public var attachments: [IntentFile]

    /// `index` is the vault's, when the caller already holds it: donating a
    /// whole vault builds one of these per note, and opening the index once
    /// per note would read the vault hundreds of times over.
    public init(_ note: NoteRef, in vault: URL, index: VaultIndex? = nil, body: Bool = true) {
        id = note.relativePath
        name = note.name
        isPinned = false
        folder = SiriFolderEntity(path: note.folder, vault: vault)
        content = body ? try? String(contentsOf: note.url, encoding: .utf8) : nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: note.url.path)
        creationDate = attributes?[.creationDate] as? Date
        modificationDate = attributes?[.modificationDate] as? Date

        // The files this note links to that are not notes themselves, which is
        // what Heft already calls an attachment.
        attachments = SiriSchemaVault.attachments(of: note, in: vault, index: index)
    }

    /// Where the note is now, given the vault it belongs to. Resolved on use
    /// for the reason `NoteEntity.url(in:)` is.
    public func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(id)
    }

    /// Unlike `NoteEntity` the body *is* here: this is the entity Siri
    /// reasons over, and a card without its text is a title. Set outright,
    /// not left to the indexing key: the default attribute set was seen to
    /// carry nothing from the keys, so the key says which property the text
    /// is and this is what the index is actually given.
    public var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.displayName = name
        set.textContent = content
        set.relatedUniqueIdentifier = id
        if let folder, !folder.id.isEmpty {
            set.containerDisplayName = folder.name
            set.keywords = [name, folder.name]
        } else {
            set.keywords = [name]
        }
        return set
    }
}

@available(macOS 27.0, *)
public struct SiriNoteQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [SiriNoteEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        let index = VaultIndex.open(vaultAt: vault)
        let byPath = Dictionary(
            index.notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byPath[$0].map { SiriNoteEntity($0, in: vault) } }
    }

    public func entities(matching string: String) async throws -> [SiriNoteEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        let index = VaultIndex.open(vaultAt: vault)
        let daily = DailyNotes(vaultRoot: vault, settings: ObsidianSettings.load(vaultRoot: vault))
        return NoteMatching.notes(matching: string, in: index, limit: 12, daily: daily)
            .map { SiriNoteEntity($0, in: vault) }
    }

    /// Without bodies: a suggestion list is a list of names, and reading a
    /// dozen notes off disk to offer them would be a dozen reads nobody asked
    /// for.
    public func suggestedEntities() async throws -> [SiriNoteEntity] {
        guard let vault = CaptureVaultPreference.url else { return [] }
        let index = VaultIndex.open(vaultAt: vault)
        return FrecencyStore.notes(forVaultAt: vault.path)
            .ranked(
                index.notes, by: \.relativePath,
                tiebreak: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
            .prefix(12)
            .map { SiriNoteEntity($0, in: vault, body: false) }
    }
}
