import Foundation
import HeftCore
import Testing

/// Where the frontmatter is, how a value is written so YAML reads it back as
/// typed, and the keys and values the vault offers.
@Suite("Property editing")
struct PropertyEditingTests {

    @Test("The block runs from the opening fence to the end of the closing one")
    func block() {
        #expect(PropertyEditing.blockRange(in: "---\na: 1\n---\nBody") == NSRange(location: 0, length: 13))
        #expect(PropertyEditing.blockRange(in: "---\r\na: 1\r\n---\r\n") == NSRange(location: 0, length: 16))
        #expect(PropertyEditing.blockRange(in: "---\na: 1\nnever closed") == nil)
        #expect(PropertyEditing.blockRange(in: "Body\n---\n") == nil)
        #expect(PropertyEditing.keys(in: "---\nAuthor: x\ntags:\n  - a\n---\n") == ["Author", "tags"])
    }

    @Test("Values YAML would misread are quoted, and read back as typed")
    func quoting() {
        for value in ["[[Some Note]]", "a: b", "x #y", "#tag", "- item", "say \"hi\"", "plain", "-5", "C#", "2026-11-03"] {
            let written = "k: " + PropertyEditing.scalar(value)
            #expect(Frontmatter.parse(written).first?.value == .text(value), "\(value) → \(written)")
        }
        #expect(PropertyEditing.scalar("plain") == "plain")
        let item = PropertyEditing.scalar("a]b", inList: true)
        #expect(Frontmatter.parse("k: [x, \(item)]").first?.value == .list(["x", "a]b"]))
    }

    @Test("The catalog offers keys and each key's values by use, matching what is typed")
    func catalog() {
        let catalog = PropertyCatalog(properties: [
            [NoteProperty(key: "Category", value: .text("ML")), NoteProperty(key: "tags", value: .list(["a"]))],
            [NoteProperty(key: "category", value: .text("Thesis")), NoteProperty(key: "Author", value: .text("Jane"))],
            [NoteProperty(key: "Category", value: .text("ml"))],
        ])
        #expect(catalog.keys == ["Category", "Author", "tags"])
        #expect(catalog.keys(matching: "cat") == ["Category"])
        #expect(catalog.keys(matching: "o") == ["Category", "Author"])
        #expect(catalog.keys(matching: "au") == ["Author"])
        #expect(catalog.keys(matching: "", excluding: ["category"]) == ["Author", "tags"])
        #expect(catalog.values(for: "CATEGORY", matching: "") == ["ML", "Thesis"])
        #expect(catalog.values(for: "Category", matching: "th") == ["Thesis"])
    }
}

/// A list edited as its pills: what is typed on the key line becomes an
/// item, and items go one line at a time.
@Suite("Property list editing")
struct PropertyListEditingTests {
    private let note = "---\ntags:\n  - x\n  - y\nA: 1\n---\n"

    private func applied(_ edit: MarkdownEditing.Edit?, to source: String) -> String {
        guard let edit else { return source }
        return (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("Only at the end of a list's key line; tags are a list before they have items")
    func detects() {
        let list = PropertyListContext.detect(in: note, selection: NSRange(location: 9, length: 0))
        #expect(list?.key == "tags")
        #expect(list.map { $0.items.map(\.value) } == ["x", "y"])
        #expect(PropertyListContext.detect(in: note, selection: NSRange(location: 8, length: 0)) == nil)
        #expect(PropertyListContext.detect(in: note, selection: NSRange(location: 26, length: 0)) == nil)
        #expect(PropertyListContext.detect(in: "---\ntags:\n---\n", selection: NSRange(location: 9, length: 0)) != nil)
        #expect(PropertyListContext.detect(in: "---\nA:\n---\n", selection: NSRange(location: 6, length: 0)) == nil)
        #expect(PropertyListContext.detect(in: "---\ntags: [a]\n---\n", selection: NSRange(location: 13, length: 0)) == nil)
    }

    @Test("What was typed becomes the last item, in the list's indent, and leaves the key line")
    func adds() {
        let typed = "---\ntags: zed\n  - x\n---\n"
        let list = PropertyListContext.detect(in: typed, selection: NSRange(location: 13, length: 0))
        let edit = list?.adding("zed", in: typed)
        #expect(applied(edit, to: typed) == "---\ntags:\n  - x\n  - zed\n---\n")
        #expect(edit?.selection == NSRange(location: 9, length: 0))
        let empty = "---\ntags:\n---\n"
        let first = PropertyListContext.detect(in: empty, selection: NSRange(location: 9, length: 0))
        // Tags split at spaces, as a tag cannot hold one.
        #expect(applied(first?.adding("a b", in: empty), to: empty) == "---\ntags:\n  - a\n  - b\n---\n")
        let quoted = PropertyListContext.detect(in: note, selection: NSRange(location: 9, length: 0))
        let added = applied(quoted?.adding("[[Note]]", in: note), to: note)
        #expect(added.contains("  - \"[[Note]]\"\n"))
    }

    @Test("An item goes with its line, the others stay")
    func removes() {
        let list = PropertyListContext.detect(in: note, selection: NSRange(location: 9, length: 0))
        #expect(applied(list?.removing(at: 0, in: note), to: note) == "---\ntags:\n  - y\nA: 1\n---\n")
        #expect(applied(list?.removing(at: 1, in: note), to: note) == "---\ntags:\n  - x\nA: 1\n---\n")
        #expect(list?.removing(at: 2, in: note) == nil)
    }
}

/// Property types live in `.obsidian/types.json`, shared with Obsidian.
@Suite("Property types")
struct PropertyTypeTests {
    private let file = """
    {
      "types": {
        "aliases": "aliases",
        "Rating": "number"
      }
    }
    """

    @Test("Setting a type changes its own entry or adds one, leaving the rest as Obsidian wrote it")
    func setting() {
        let changed = PropertyTypes.setting(.text, for: "Rating", in: file)
        #expect(changed == file.replacingOccurrences(of: "\"Rating\": \"number\"", with: "\"Rating\": \"text\""))
        let added = PropertyTypes.setting(.date, for: "Read on", in: file)
        #expect(added.contains("\"types\": {\n    \"Read on\": \"date\",\n    \"aliases\": \"aliases\""))
        #expect(PropertyTypes.setting(.checkbox, for: "a/b", in: nil).contains("\"a/b\": \"checkbox\""))
        let noTypes = PropertyTypes.setting(.number, for: "n", in: "{\n  \"other\": 1\n}")
        let parsed = try? JSONSerialization.jsonObject(with: Data(noTypes.utf8)) as? [String: Any]
        #expect((parsed?["types"] as? [String: String]) == ["n": "number"])
        #expect(parsed?["other"] as? Int == 1)
        let empty = PropertyTypes.setting(.text, for: "k", in: "{\n  \"types\": {}\n}")
        #expect((try? JSONSerialization.jsonObject(with: Data(empty.utf8))) != nil)
    }

    @Test("The vault's types are read from its file, again only when it changes")
    func reading() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("heft-types-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(PropertyTypes.types(in: vault).isEmpty)
        try PropertyTypes.set(.number, for: "Rating", in: vault)
        let before = PropertyTypes.generation
        #expect(PropertyTypes.types(in: vault)["Rating"] == .number)
        #expect(PropertyTypes.generation != before)
        #expect(PropertyTypes.type(of: "rating", in: PropertyTypes.types(in: vault)) == .number)
    }

    @Test("A types file that cannot be read, or is only an iCloud placeholder, is refused, never replaced")
    func typesRefused() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("heft-types-\(UUID().uuidString)")
        let obsidian = vault.appendingPathComponent(".obsidian")
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        // Not UTF-8: unreadable as text, so it must be left as it is.
        let unreadable = Data([0x7B, 0xFF, 0xFE, 0x7D])
        try unreadable.write(to: obsidian.appendingPathComponent("types.json"))
        #expect(throws: (any Error).self) { try PropertyTypes.set(.number, for: "Rating", in: vault) }
        #expect(try Data(contentsOf: obsidian.appendingPathComponent("types.json")) == unreadable)
        // Only the placeholder iCloud leaves: nothing is written beside it.
        try FileManager.default.removeItem(at: obsidian.appendingPathComponent("types.json"))
        try Data().write(to: obsidian.appendingPathComponent(".types.json.icloud"))
        #expect(throws: PropertyTypes.WriteError.notDownloaded) { try PropertyTypes.set(.number, for: "Rating", in: vault) }
        #expect(!FileManager.default.fileExists(atPath: obsidian.appendingPathComponent("types.json").path))
    }

    @Test("Changing between a value and a list converts the value")
    func converting() {
        let single = "---\nGenre: Fiction\n---\n"
        let toList = PropertyEditing.converting(key: "genre", toList: true, in: single)
        #expect(toList.map { (single as NSString).replacingCharacters(in: $0.range, with: $0.replacement) }
            == "---\nGenre:\n  - Fiction\n---\n")
        let list = "---\nGenre:\n  - a\n  - b\nX: 1\n---\n"
        let toText = PropertyEditing.converting(key: "Genre", toList: false, in: list)
        #expect(toText.map { (list as NSString).replacingCharacters(in: $0.range, with: $0.replacement) }
            == "---\nGenre: a, b\nX: 1\n---\n")
        #expect(PropertyEditing.converting(key: "X", toList: false, in: list) == nil)
        #expect(PropertyEditing.converting(key: "Missing", toList: true, in: list) == nil)
    }
}

/// What Obsidian documents a property must be.
@Suite("Property rules")
struct PropertyRuleTests {
    private func tidied(_ source: String) -> String {
        var result = source
        for row in PropertyEditing.rows(in: source).reversed() {
            if let edit = PropertyRules.tidying(row, in: result) {
                result = (result as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            }
        }
        return result
    }

    @Test("Left alone, a row is made YAML: colon, space, quoted links")
    func tidying() {
        #expect(tidied("---\nkey\n---\n") == "---\nkey:\n---\n")
        #expect(tidied("---\nkey:value\n---\n") == "---\nkey: value\n---\n")
        #expect(tidied("---\nup: [[Note]]\n---\n") == "---\nup: \"[[Note]]\"\n---\n")
        #expect(tidied("---\nup:\n  - [[A]]\n  - b\n---\n") == "---\nup:\n  - \"[[A]]\"\n  - b\n---\n")
        // Already fine: untouched, byte for byte.
        for fine in ["---\nk: v\n---\n", "---\nk:\n---\n", "---\nk: \"[[A]]\"\n---\n", "---\nk: [a, b]\n---\n", "---\n# c\nk: v\n---\n"] {
            #expect(tidied(fine) == fine)
        }
    }

    @Test("A typed tag loses its # and splits at spaces, as Obsidian's tag field does")
    func tags() {
        #expect(PropertyRules.tags(from: "#work") == ["work"])
        #expect(PropertyRules.tags(from: "a b, c") == ["a", "b", "c"])
        #expect(PropertyRules.tags(from: "  ") == [])
    }

    @Test("What Obsidian warns of is said; what it accepts is not")
    func issues() {
        #expect(PropertyRules.issue(key: "Rating", value: "four", items: [], type: .number) != nil)
        #expect(PropertyRules.issue(key: "Rating", value: "4.5", items: [], type: .number) == nil)
        #expect(PropertyRules.issue(key: "Done", value: "yes", items: [], type: .checkbox) != nil)
        #expect(PropertyRules.issue(key: "Done", value: "false", items: [], type: .checkbox) == nil)
        #expect(PropertyRules.issue(key: "Read", value: "03.11.2026", items: [], type: .date) != nil)
        #expect(PropertyRules.issue(key: "Read", value: "2026-11-03", items: [], type: .date) == nil)
        #expect(PropertyRules.issue(key: "At", value: "2026-11-03T10:30:00", items: [], type: .datetime) == nil)
        #expect(PropertyRules.issue(key: "At", value: "2026-11-03 10:30", items: [], type: .datetime) != nil)
        #expect(PropertyRules.issue(key: "tags", value: "", items: ["a b"], type: nil) != nil)
        #expect(PropertyRules.issue(key: "tags", value: "", items: ["ab"], type: nil) == nil)
        #expect(PropertyRules.issue(key: "alias", value: "x", items: [], type: nil) != nil)
        #expect(PropertyRules.issue(key: "Rating", value: "", items: [], type: .number) == nil)
        #expect(PropertyRules.issue(key: "Note", value: "anything", items: [], type: nil) == nil)
    }
}
