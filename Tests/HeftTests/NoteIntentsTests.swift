import CoreSpotlight
import Foundation
import Testing
@testable import HeftCore

/// The nouns Siri was missing. What matters is that a spoken name finds the
/// note a person meant, that an id stored in a shortcut months ago still
/// resolves, and that creating a note can only ever add.
@Suite("Note intents")
struct NoteIntentsTests {

    private func vault(_ files: [String: String] = [:]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-intents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func index(_ root: URL) -> VaultIndex {
        VaultIndex.open(vaultAt: root, cache: IndexCache(directory: root.appendingPathComponent(".c")))
    }

    private func names(_ query: String, _ root: URL, limit: Int = 12) -> [String] {
        NoteMatching.notes(matching: query, in: index(root), limit: limit).map(\.name)
    }

    // MARK: - Answering with notes

    /// Siri asking what the notes say about something gets the notes that
    /// are named for it before the ones that mention it, and among those,
    /// the ones that keep coming back to it.
    @Test("Named notes come first, then the notes that mention it most")
    func findingRanksNamesThenMentions() throws {
        let root = try vault([
            "Thesis.md": "nothing here",
            "Meeting.md": "thesis\nthesis again\nand thesis once more",
            "Aside.md": "one thesis thesis thesis line",
            "Unrelated.md": "roof",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = NoteFinding.notes(matching: "thesis", in: index(root), limit: 10).map(\.name)
        #expect(found == ["Thesis", "Meeting", "Aside"])
    }

    @Test("An answer is capped, and nothing asked is nothing answered")
    func findingIsCapped() throws {
        var files: [String: String] = [:]
        for index in 0..<8 { files["Note \(index).md"] = "roof" }
        let root = try vault(files)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NoteFinding.notes(matching: "roof", in: index(root), limit: 3).count == 3)
        #expect(NoteFinding.notes(matching: "  ", in: index(root), limit: 3).isEmpty)
    }

    // MARK: - Finding the note somebody meant

    @Test("An exact name wins outright")
    func exactName() throws {
        let root = try vault(["Roof repair.md": "", "Roof.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("Roof", root) == ["Roof"])
    }

    /// Speech does not put the words in the order the filename has, so the
    /// words are matched individually rather than as one substring.
    @Test("Every word has to appear, in any order")
    func everyWord() throws {
        let root = try vault([
            "Roof repair.md": "", "Kitchen plans.md": "", "Repair the roof again.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        // "Roof repair" is a note's actual name, so it wins outright rather
        // than opening a list; the reordered phrase is the one that matches
        // by words.
        #expect(names("roof repair", root) == ["Roof repair"])
        #expect(names("repair roof", root) == ["Roof repair", "Repair the roof again"])
        #expect(names("roof kitchen", root).isEmpty, "a word that matches nothing rules it out")
    }

    /// The shortest name is the likeliest answer: asked for "roof", a note
    /// called "Roof" beats one called "Roof repair quotes".
    @Test("The shortest matching name comes first")
    func shortestFirst() throws {
        let root = try vault([
            "Roof repair quotes.md": "", "Roofing.md": "", "Roof repair.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("roof", root) == ["Roofing", "Roof repair", "Roof repair quotes"])
    }

    @Test("A disambiguation list is capped")
    func capped() throws {
        var files: [String: String] = [:]
        for index in 0..<30 { files["Roof \(index).md"] = "" }
        let root = try vault(files)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("roof", root, limit: 5).count == 5)
    }

    @Test("Nothing said is nothing matched")
    func emptyQuery() throws {
        let root = try vault(["Roof.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("", root).isEmpty)
        #expect(names("   ", root).isEmpty)
    }

    /// A vault keeps a subject in a folder and names the notes inside it for
    /// their parts, so the folder has to count as well as the name.
    @Test("A folder name finds the notes inside it")
    func folderCounts() throws {
        let root = try vault([
            "Thesis/Chapter 1.md": "", "Thesis/Notes on method.md": "", "Roof.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("thesis", root) == ["Chapter 1", "Notes on method"])
        #expect(names("thesis method", root) == ["Notes on method"])
    }

    /// A hit on the name is a better answer than one that only matched the
    /// folder it happens to sit in.
    @Test("A name match comes before a folder-only match")
    func nameBeatsFolder() throws {
        let root = try vault(["Thesis/Chapter 1.md": "", "Old/Thesis plan.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("thesis", root) == ["Thesis plan", "Chapter 1"])
    }

    // MARK: - Asking for a day

    /// The bug Siri found: a date said out loud shares no word with the file
    /// it names, so "September 13, 2026" matched nothing at all.
    @Test("A spoken date resolves to that day's daily note")
    func spokenDate() throws {
        let root = try vault([
            "Daily/2026-09-13.md": "the thirteenth",
            "Daily/2026-09-19.md": "",
            "Other.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))

        for spoken in ["September 13, 2026", "13 September 2026", "2026-09-13"] {
            let found = NoteMatching.notes(
                matching: spoken, in: index(root), limit: 12, daily: daily
            )
            #expect(found.map(\.relativePath) == ["Daily/2026-09-13.md"], Comment(rawValue: spoken))
        }
    }

    /// A date with no daily note behind it is not a dead end: a note actually
    /// called "September 13 meeting" is still the best answer about that day.
    @Test("A date with no daily note falls back to the words")
    func dateWithNoDailyNote() throws {
        let root = try vault([
            "Daily/2026-09-19.md": "", "September 13 2026 meeting.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))
        let found = NoteMatching.notes(
            matching: "September 13, 2026", in: index(root), limit: 12, daily: daily
        )
        #expect(found.map(\.name) == ["September 13 2026 meeting"])
    }

    /// And the daily note still wins when there is one, whatever else shares
    /// those words.
    @Test("The daily note beats a note that merely mentions the date")
    func dailyNoteWins() throws {
        let root = try vault([
            "Daily/2026-09-13.md": "", "September 13 2026 meeting.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))
        let found = NoteMatching.notes(
            matching: "September 13, 2026", in: index(root), limit: 12, daily: daily
        )
        #expect(found.map(\.relativePath) == ["Daily/2026-09-13.md"])
    }

    /// Punctuation is not part of a filename, so it cannot be part of the
    /// match: "Roof, repairs" has to find "Roof repairs".
    @Test("Punctuation in what was said is ignored")
    func punctuation() throws {
        let root = try vault(["Roof repairs.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names("roof, repairs!", root) == ["Roof repairs"])
    }

    @Test("A phrase with no date in it still matches by words")
    func notADate() throws {
        let root = try vault(["Roof repairs.md": "", "Daily/2026-09-13.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))
        let found = NoteMatching.notes(
            matching: "roof", in: index(root), limit: 12, daily: daily
        )
        #expect(found.map(\.name) == ["Roof repairs"])
    }

    /// "My daily note" holds no date for a detector to find, and the file is
    /// called 2026-09-20, so matching by words found nothing at all.
    @Test("Asking for the daily note finds today's")
    func dailyNoteByName() throws {
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let stem = today.string(from: Date())
        let root = try vault(["Daily/\(stem).md": "", "Other.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))

        for spoken in ["my daily note", "today's note", "the daily note in Heft"] {
            let found = NoteMatching.notes(
                matching: spoken, in: index(root), limit: 12, daily: daily
            )
            #expect(found.map(\.name) == [stem], Comment(rawValue: spoken))
        }
    }

    @Test("A phrase that is not about a day is unaffected")
    func notADay() throws {
        let root = try vault(["Roof repairs.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings.load(vaultRoot: root))
        let found = NoteMatching.notes(matching: "roof", in: index(root), limit: 12, daily: daily)
        #expect(found.map(\.name) == ["Roof repairs"])
    }

    // MARK: - Appending

    /// Appending to a named note is not a capture: the inbox's dated heading
    /// and leading time are its structure, and wrong in a note about a roof.
    @Test("An appended line is added plainly, with no timestamp")
    func appendsPlainly() throws {
        let root = try vault(["Roof.md": "the roof needs looking at\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try NoteAppend.append("also look in the basement", to: "Roof.md", in: root)

        let text = try String(contentsOf: root.appendingPathComponent("Roof.md"), encoding: .utf8)
        #expect(text == "the roof needs looking at\n\nalso look in the basement\n")
        #expect(!text.contains(":"), "a time would have put a colon in it")
        #expect(!text.contains("#"), "a day heading would have put one in it")
    }

    @Test("Appending to a note that is not there says so")
    func appendMissing() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: NoteAppend.Failure.self) {
            try NoteAppend.append("text", to: "Nope.md", in: root)
        }
    }

    @Test("An empty append changes nothing")
    func appendNothing() throws {
        let root = try vault(["Roof.md": "body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try NoteAppend.append("   ", to: "Roof.md", in: root)
        #expect(try String(contentsOf: root.appendingPathComponent("Roof.md"), encoding: .utf8) == "body\n")
    }

    // MARK: - The entity itself

    /// Identified by path, not by name: two folders may each hold a Notes.md,
    /// and a shortcut written last month still has to point at one of them.
    @Test("An entity is identified by its path")
    func identity() throws {
        let root = try vault(["Work/Notes.md": "", "Home/Notes.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let entities = index(root).notes.map(NoteEntity.init)
        #expect(Set(entities.map(\.id)) == ["Work/Notes.md", "Home/Notes.md"])
        #expect(Set(entities.map(\.name)) == ["Notes"])
        #expect(Set(entities.map(\.folder)) == ["Work", "Home"])
    }

    @Test("An entity resolves to where the note is now")
    func entityURL() throws {
        let root = try vault(["Work/Notes.md": "hello"])
        defer { try? FileManager.default.removeItem(at: root) }
        let entity = NoteEntity(id: "Work/Notes.md", name: "Notes", folder: "Work")
        #expect(try String(contentsOf: entity.url(in: root), encoding: .utf8) == "hello")
    }

    /// A result card is only clickable if the entity has a URL, and the URL
    /// has to be one Heft actually answers. Built by hand in the entity and
    /// parsed by `HeftURL`, so the two are pinned to each other here.
    @Test("A note's URL is the one Heft opens")
    func urlRoundTrips() {
        let path = "Work/Roof repair.md"
        let built = HeftURL.open(path: path)
        #expect(built != nil)
        #expect(HeftURL.openedPath(in: built!) == path)
        #expect(built?.scheme == "heft")
        #expect(built?.host == "open")
    }

    // MARK: - What Spotlight is told

    /// The attribute set is what turns an entity Siri can be handed into one
    /// it can find, so the fields it searches on have to be filled.
    @Test("A note is donated under its own name and folder")
    func attributeSet() {
        let entity = NoteEntity(id: "Work/Roof repair.md", name: "Roof repair", folder: "Work")
        let attributes = entity.attributeSet
        #expect(attributes.title == "Roof repair")
        #expect(attributes.displayName == "Roof repair")
        #expect(attributes.containerDisplayName == "Work")
        #expect(attributes.relatedUniqueIdentifier == "Work/Roof repair.md")
        #expect(attributes.keywords?.contains("Roof repair") == true)
    }

    /// Spotlight already indexes the files, so donating the body again would
    /// put every note in the results twice.
    @Test("The note's text is not donated")
    func bodyIsNotDonated() {
        let entity = NoteEntity(id: "Note.md", name: "Note", folder: "")
        #expect(entity.attributeSet.textContent == nil)
        #expect(entity.attributeSet.contentDescription == nil)
    }

    /// The schema note is the one Siri reasons over, so its body goes into
    /// the index. Not through the indexing key alone: the default attribute
    /// set carried nothing from it, which this test found.
    @Test("The schema note is donated with its text")
    @available(macOS 27.0, *)
    func schemaNoteCarriesItsBody() throws {
        let root = try vault(["Work/Roof.md": "call the builder"])
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(index(root).notes.first)
        let attributes = SiriNoteEntity(note, in: root, index: index(root)).attributeSet
        #expect(attributes.textContent == "call the builder")
        #expect(attributes.title == "Roof")
        #expect(attributes.relatedUniqueIdentifier == "Work/Roof.md")
        #expect(attributes.keywords?.contains("Work") == true)
    }

    @Test("A note at the vault root has no container")
    func rootHasNoContainer() {
        let entity = NoteEntity(id: "Note.md", name: "Note", folder: "")
        #expect(entity.attributeSet.containerDisplayName == nil)
        #expect(entity.attributeSet.keywords == ["Note"])
    }

    /// Donating nothing is not an error, and must not be reported as one.
    @Test("An empty vault donates nothing and says so")
    func donatesNothing() async {
        #expect(await NoteIndexing.donate([]) == 0)
    }

    /// Apple's macOS 27 documentation says not to ship the default index: it
    /// is for prototyping, and a named one is the app's own store.
    @Test("The index is a named one, never the default")
    func namedIndex() {
        #expect(NoteIndexing.indexName == "dev.stenglein.Heft.notes")
        #expect(!NoteIndexing.indexName.isEmpty)
    }

    // MARK: - Creating one

    @Test("A note is created with its body")
    func creates() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Shopping", body: "Milk", in: root, location: .vaultRoot, captureFolder: nil)
        #expect(url.lastPathComponent == "Shopping.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "Milk\n")
    }

    /// It only ever adds. A name already taken gets a sibling, because an
    /// intent that can run unattended must not be able to replace a note.
    @Test("An existing note is never replaced")
    func neverReplaces() throws {
        let root = try vault(["Shopping.md": "Do not lose me"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Shopping", body: "Milk", in: root, location: .vaultRoot, captureFolder: nil)
        #expect(url.lastPathComponent == "Shopping 1.md")
        #expect(
            try String(contentsOf: root.appendingPathComponent("Shopping.md"), encoding: .utf8)
                == "Do not lose me"
        )
    }

    @Test("A name given with .md does not get it twice")
    func extensionOnce() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Shopping.md", in: root, location: .vaultRoot, captureFolder: nil)
        #expect(url.lastPathComponent == "Shopping.md")
    }

    /// A title arriving from speech is exactly where a path escape would, and
    /// "it only adds" is a property of adding to a *note*.
    @Test("A name cannot climb out of the vault")
    func refusesEscape() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../escaped", "/etc/passwd", "Work/Nested", "..", "", "   "] {
            #expect(throws: NoteCreation.Failure.self) {
                try NoteCreation.create(named: name, in: root, location: .vaultRoot, captureFolder: nil)
            }
        }
    }

    /// A misheard folder should fail rather than scatter folders through a
    /// vault, so the folder has to be one that is already there.
    @Test("A folder has to exist already")
    func folderMustExist() throws {
        let root = try vault(["Work/Keep.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Plan", in: root, folder: "Work", location: .vaultRoot, captureFolder: nil)
        #expect(url.path.hasSuffix("Work/Plan.md"))

        #expect(throws: NoteCreation.Failure.self) {
            try NoteCreation.create(named: "Plan", in: root, folder: "Nowhere", location: .vaultRoot, captureFolder: nil)
        }
        #expect(throws: NoteCreation.Failure.self) {
            try NoteCreation.create(named: "Plan", in: root, folder: "../outside", location: .vaultRoot, captureFolder: nil)
        }
    }

    /// A note made without a window has no open note and no focused folder to
    /// sit beside, so it lands where the reader configured new notes to go.
    @Test("The configured folder is where a note with no folder lands")
    func followsTheSetting() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }

        // The temporary directory is reached through a symlink, so the two
        // sides have to be resolved before they can be compared.
        let beside = try NoteCreation.create(named: "A", in: root, location: .besideTheOpenNote, captureFolder: nil)
        // Compared as paths: two URLs for the same directory differ when one
        // carries a trailing slash and the other does not.
        #expect(
            beside.deletingLastPathComponent().resolvingSymlinksInPath().path
                == root.resolvingSymlinksInPath().path
        )

        let configured = try NoteCreation.create(
            named: "B", in: root, location: .folder("Inbox/Voice"), captureFolder: nil
        )
        #expect(configured.path.hasSuffix("Inbox/Voice/B.md"))
    }

    /// Unlike a folder somebody said, the configured one is made if missing:
    /// naming it in Settings is asking for notes to go there.
    @Test("The configured folder is created, a spoken one is not")
    func createsOnlyTheConfiguredFolder() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try NoteCreation.create(named: "A", in: root, location: .folder("Made"), captureFolder: nil)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Made").path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)

        #expect(throws: NoteCreation.Failure.self) {
            try NoteCreation.create(named: "B", in: root, folder: "Spoken", location: .vaultRoot, captureFolder: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Spoken").path))
    }

    /// Its own setting, because the sidebar's answer to "where do new notes
    /// go" is "beside the open note", and a note made by voice has no open
    /// note to sit beside.
    @Test("A windowless note goes to the capture folder when one is set")
    func captureFolderWins() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(
            named: "Spoken", in: root, location: .besideTheOpenNote,
            captureFolder: "Captured/Voice"
        )
        #expect(url.path.hasSuffix("Captured/Voice/Spoken.md"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A folder named in the intent is still more specific than the setting.
    @Test("A folder said out loud beats the setting")
    func spokenFolderBeatsTheSetting() throws {
        let root = try vault(["Work/Keep.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Plan", in: root, folder: "Work", captureFolder: "Captured")
        #expect(url.path.hasSuffix("Work/Plan.md"))
    }

    @Test("An unset capture folder leaves the sidebar's setting in charge")
    func unsetFallsBack() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(
            named: "Spoken", in: root, location: .folder("Sidebar"), captureFolder: nil
        )
        #expect(url.path.hasSuffix("Sidebar/Spoken.md"))
    }

    /// It cannot name anywhere outside the vault, whatever is typed into it.
    @Test("The capture folder is cleaned before it is stored")
    func captureFolderIsCleaned() {
        let defaults = HeftDefaults.shared
        let was = defaults.string(forKey: CaptureNoteFolderPreference.defaultsKey)
        defer { defaults.set(was, forKey: CaptureNoteFolderPreference.defaultsKey) }

        CaptureNoteFolderPreference.set("../outside/Notes")
        #expect(CaptureNoteFolderPreference.folder == "outside/Notes")
        CaptureNoteFolderPreference.set("/absolute")
        #expect(CaptureNoteFolderPreference.folder == "absolute")
    }

    /// The note you just made by voice is the one whose name you are least
    /// likely to remember, so it has to be findable without being opened.
    @Test("A new note is recorded so Quick Open knows it")
    func recordedForLater() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FrecencyStore.notes(forVaultAt: root.path).score("Spoken.md") == 0)

        _ = try NoteCreation.create(named: "Spoken", in: root, location: .vaultRoot, captureFolder: nil)
        // Read through a fresh store: one built earlier holds the ranking it
        // loaded at the time, which is the point of not publishing changes.
        #expect(
            FrecencyStore.notes(forVaultAt: root.path).score("Spoken.md") > 0,
            "it would be nowhere in Quick Open's ordering"
        )
    }

    @Test("An empty body writes an empty note")
    func emptyBody() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try NoteCreation.create(named: "Blank", in: root, location: .vaultRoot, captureFolder: nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "")
    }
}
