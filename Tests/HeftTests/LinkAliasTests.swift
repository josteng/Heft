import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// `[[` finds a note by the aliases in its frontmatter as well as by its
/// name, and a note found that way is linked as `[[Note|Alias]]`.
@Suite("Link aliases")
struct LinkAliasTests {

    private func vault(_ files: [String: String]) throws -> (URL, VaultIndex) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return (root, VaultIndex.build(root: VaultScanner.scan(root: root)))
    }

    private let files = [
        "Machine Learning.md": "---\naliases:\n  - ML\n  - \"Learning Machines\"\n---\nbody",
        "Mlops.md": "---\nalias: Pipelines\n---\nbody",
        "Other.md": "---\naliases: [Elsewhere, ml notes]\n---\nbody",
        "Plain.md": "no frontmatter",
    ]

    @Test("Aliases are read in each form Obsidian writes them")
    func readsAliases() {
        #expect(NoteAliases.all(in: "---\naliases:\n  - ML\n  - \"Learning Machines\"\n---\n") == ["ML", "Learning Machines"])
        #expect(NoteAliases.all(in: "---\naliases: [A, b, a]\n---\n") == ["A", "b"])
        #expect(NoteAliases.all(in: "---\nalias: One\n---\n") == ["One"])
        #expect(NoteAliases.all(in: "aliases: [Not, frontmatter]") == [])
    }

    @Test("A note is found by its alias, carrying the alias that matched")
    func findsByAlias() throws {
        let (root, index) = try vault(files)
        defer { try? FileManager.default.removeItem(at: root) }

        let exact = try #require(index.linkMatches(matching: "ml", forEmbed: false).first)
        #expect(exact.ref.name == "Machine Learning")
        #expect(exact.alias == "ML")

        let pipelines = index.linkMatches(matching: "pipe", forEmbed: false)
        #expect(pipelines.map(\.ref.name) == ["Mlops"])
        #expect(pipelines.first?.alias == "Pipelines")

        // A name match is the note's own name, with no alias attached, and
        // outranks the same kind of match on an alias.
        let named = index.linkMatches(matching: "mlo", forEmbed: false)
        #expect(named.first?.ref.name == "Mlops")
        #expect(named.first?.alias == nil)
        // Found both ways, offered both ways, so the reader picks what the
        // link should read.
        let learning = index.linkMatches(matching: "learning", forEmbed: false)
            .filter { $0.ref.name == "Machine Learning" }
        #expect(learning.map(\.alias) == ["Learning Machines", nil])
    }

    @Test("Aliases survive the index cache")
    func cacheKeepsAliases() throws {
        let (root, _) = try vault(files)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-alias-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = IndexCache(directory: directory)
        _ = VaultIndex.open(vaultAt: root, cache: cache)
        let reopened = VaultIndex.open(vaultAt: root, cache: cache)
        #expect(reopened.notesRead == 0)
        #expect(reopened.linkMatches(matching: "ml", forEmbed: false).first?.alias == "ML")
    }

    @Test("The separator is escaped in a table row")
    func pipeInTable() {
        #expect(WikiCompletionContext.pipe(at: 3, in: "see [[x") == "|")
        #expect(WikiCompletionContext.pipe(at: 4, in: "| [[x | y |") == "\\|")
    }

    @MainActor
    @Test("Accepting a row found by its alias writes the note and the alias")
    func editorWritesAlias() throws {
        let (root, index) = try vault(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.completionIndex = index
        view.string = "See [[ML"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: true)
        // Opened on an empty query only, so start it the way typing does.
        view.string = "See [["
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.updateLinkCompletion(allowStart: true)
        view.string = "See [[ML"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: false)
        #expect(view.visibleCompletions.first == "ML")
        view.insertNewline(nil)
        #expect(view.string == "See [[Machine Learning|ML]]")
    }
}

/// `|` or `#` with the link menu open takes the highlighted note and goes on
/// inside the link, instead of Return closing it.
@MainActor
@Suite("Continuing a link from its menu")
struct LinkContinuationTests {

    private func editor() throws -> (HeftTextKit2View, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "---\naliases: [ML]\n---\n# Basics\nbody"
            .write(to: root.appendingPathComponent("Machine Learning.md"), atomically: true, encoding: .utf8)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        return (view, root)
    }

    /// Opens the menu the way typing `[[` does, then narrows it to `query`.
    private func open(_ view: HeftTextKit2View, _ before: String, _ query: String, closer: String = "]]") {
        let length = (before as NSString).length
        view.string = before + closer
        view.setSelectedRange(NSRange(location: length, length: 0))
        view.updateLinkCompletion(allowStart: true)
        view.string = before + query + closer
        view.setSelectedRange(NSRange(location: length + (query as NSString).length, length: 0))
        view.updateLinkCompletion(allowStart: false)
    }

    private func type(_ view: HeftTextKit2View, _ key: String) {
        view.insertText(key, replacementRange: view.selectedRange())
    }

    @Test("| takes the highlighted note and leaves the caret for the link's text")
    func pipeContinues() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "mach")
        #expect(view.visibleCompletions.first == "Machine Learning")
        type(view, "|")
        #expect(view.string == "See [[Machine Learning|]]")
        #expect(view.selectedRange() == NSRange(location: 23, length: 0))
    }

    @Test("# does the same for a heading, and closes a link that was not closed")
    func hashContinues() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "mach", closer: "")
        type(view, "#")
        #expect(view.string == "See [[Machine Learning#]]")
        #expect(view.selectedRange() == NSRange(location: 23, length: 0))
    }

    @Test("A row found by an alias continues with its note alone")
    func aliasRowGivesTarget() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "ML")
        #expect(view.visibleCompletions.first == "ML")
        type(view, "|")
        #expect(view.string == "See [[Machine Learning|]]")
    }

    @Test("In a table the pipe is escaped")
    func tablePipe() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "| [[", "mach")
        type(view, "|")
        #expect(view.string == "| [[Machine Learning\\|]]")
    }

    @Test("With nothing to take, or the menu closed, the key is typed")
    func typedWhenNothingToTake() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "zzzq", closer: "")
        #expect(view.visibleCompletions.isEmpty)
        type(view, "|")
        #expect(view.string == "See [[zzzq|")

        open(view, "See [[", "mach", closer: "")
        view.cancelOperation(nil)
        type(view, "|")
        #expect(view.string == "See [[mach|")
    }

    @Test("The link menu says what | and # do, except in an embed")
    func hintShown() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "mach")
        #expect(view.visibleCompletionHint?.contains("|") == true)
        open(view, "See ![[", "mach")
        #expect(!view.visibleCompletions.isEmpty)
        #expect(view.visibleCompletionHint == nil)
    }

    @Test("The note a destination links to")
    func targetOfDestination() {
        #expect(WikiCompletionContext.target(of: "Machine Learning|ML") == "Machine Learning")
        #expect(WikiCompletionContext.target(of: "Machine Learning\\|ML") == "Machine Learning")
        #expect(WikiCompletionContext.target(of: "Folder/Note") == "Folder/Note")
    }
}

/// After `|` a link offers its note's aliases; after `#`, its headings.
@MainActor
@Suite("Completing a link's text and heading")
struct LinkPartTests {

    private func detect(_ source: String, caret: Int? = nil) -> LinkPartContext? {
        let location = caret ?? (source as NSString).length
        return LinkPartContext.detect(in: source, selection: NSRange(location: location, length: 0))
    }

    @Test("The part after | or # is found, with the note it belongs to")
    func detects() {
        let text = detect("See [[Machine Learning|M")
        #expect(text?.part == .text)
        #expect(text?.target == "Machine Learning")
        #expect(text?.query == "M")
        #expect(text?.queryRange == NSRange(location: 23, length: 1))
        #expect(detect("| [[Note\\|x")?.target == "Note")
        #expect(detect("[[Note#Part|x")?.target == "Note")

        let heading = detect("[[Note#Ba]]", caret: 9)
        #expect(heading?.part == .heading)
        #expect(heading?.target == "Note")
        #expect(heading?.hasClosingBrackets == true)
        #expect(detect("[[#Ba")?.target == "")

        #expect(detect("[[Note#^block") == nil)
        #expect(detect("[[Note]] then |x") == nil)
        #expect(detect("[[Note") == nil)
    }

    @Test("Matches start with what was typed before they merely contain it")
    func matching() throws {
        let context = try #require(detect("[[N#ba"))
        #expect(context.matching(["Kebab", "Basics", "basics", "Other"]) == ["Basics", "Kebab"])
        #expect(try #require(detect("[[N#")).matching(["A", "B"]) == ["A", "B"])
    }

    @Test("A heading is written so the link still parses")
    func linkableHeading() {
        #expect(LinkPartContext.linkable(heading: "Notes [draft] | v2") == "Notes draft v2")
        #expect(LinkPartContext.linkable(heading: "C# basics") == "C# basics")
    }

    private func editor() throws -> (HeftTextKit2View, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-part-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "---\naliases: [ML, Learning]\n---\n# Basics\n## Deep [Nets]\nbody"
            .write(to: root.appendingPathComponent("Machine Learning.md"), atomically: true, encoding: .utf8)
        try "no aliases".write(to: root.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        return (view, root)
    }

    private func open(_ view: HeftTextKit2View, _ before: String, _ query: String) {
        let length = (before as NSString).length
        view.string = before + "]]"
        view.setSelectedRange(NSRange(location: length, length: 0))
        view.updateLinkCompletion(allowStart: true)
        view.string = before + query + "]]"
        view.setSelectedRange(NSRange(location: length + (query as NSString).length, length: 0))
        view.updateLinkCompletion(allowStart: false)
    }

    /// Types `query` after the caret, as keys narrowing the open menu do.
    private func narrow(_ view: HeftTextKit2View, to query: String) {
        let caret = view.selectedRange().location
        view.string = (view.string as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: query)
        view.setSelectedRange(NSRange(location: caret + (query as NSString).length, length: 0))
        view.updateLinkCompletion(allowStart: false)
    }

    @Test("| offers the note's aliases, and one is written as the link's text")
    func aliasesAfterPipe() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "mach")
        view.insertText("|", replacementRange: view.selectedRange())
        #expect(view.visibleCompletions == ["ML", "Learning"])
        narrow(view, to: "l")
        #expect(view.visibleCompletions == ["Learning", "ML"])
        view.insertNewline(nil)
        #expect(view.string == "See [[Machine Learning|Learning]]")
        #expect(view.selectedRange() == NSRange(location: 33, length: 0))
    }

    @Test("# offers the note's headings, written so the link parses")
    func headingsAfterHash() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        open(view, "See [[", "mach")
        view.insertText("#", replacementRange: view.selectedRange())
        #expect(view.visibleCompletions == ["Basics", "Deep [Nets]"])
        narrow(view, to: "deep")
        view.insertNewline(nil)
        #expect(view.string == "See [[Machine Learning#Deep Nets]]")
    }

    @Test("[[# offers the headings of the note being written")
    func ownHeadings() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        view.string = "# Intro\n## Method\nSee [[#]]"
        view.setSelectedRange(NSRange(location: 25, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(view.visibleCompletions == ["Intro", "Method"])
    }

    @Test("A note without aliases offers nothing, and | typed into a link opens the menu")
    func noAliasesNoMenu() throws {
        let (view, root) = try editor()
        defer { try? FileManager.default.removeItem(at: root) }
        view.string = "[[Plain|]]"
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(view.visibleCompletions.isEmpty)

        view.string = "[[Machine Learning|]]"
        view.setSelectedRange(NSRange(location: 19, length: 0))
        view.updateLinkCompletion(allowStart: true)
        #expect(view.visibleCompletions == ["ML", "Learning"])
    }
}
