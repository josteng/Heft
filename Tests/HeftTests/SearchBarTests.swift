import Foundation
import HeftCore
import Testing
@testable import Heft

/// The rules the bar's scopes follow, without a window.
@Suite("Search bar scopes")
struct BarScopeTests {

    /// A symbol typed alone is a way in; anything longer is a query. That is
    /// what keeps a pasted absolute path a path.
    @Test("Only a trigger typed on its own enters a scope")
    func triggers() {
        #expect(BarScope.entered(byTyping: "@") == .notes)
        #expect(BarScope.entered(byTyping: ">") == .commands)
        #expect(BarScope.entered(byTyping: "#") == .tags)
        #expect(BarScope.entered(byTyping: "/") == .contents)
        #expect(BarScope.entered(byTyping: "/Users/someone/Notes/Plan.md") == nil)
        #expect(BarScope.entered(byTyping: "#project") == nil)
        #expect(BarScope.entered(byTyping: "a") == nil)
        #expect(BarScope.entered(byTyping: "") == nil)
    }

    /// Space enters a scope only for the start of its name, as a browser
    /// wants the keyword itself; a synonym or a middle is still typing.
    @Test("Space needs the start of the name")
    func namedByPrefix() {
        #expect(BarScope.recent.isNamed(byPrefix: "rec"))
        #expect(BarScope.contents.isNamed(byPrefix: "tex"))
        #expect(BarScope.folder("Work/Project Notes").isNamed(byPrefix: "not"), "a later word of the name")
        #expect(!BarScope.contents.isNamed(byPrefix: "not"), "the chip is Text, not Text in Notes")
        #expect(!BarScope.frequent.isNamed(byPrefix: "most"), "only a synonym")
        #expect(!BarScope.recent.isNamed(byPrefix: "cent"))
        #expect(!BarScope.recent.isNamed(byPrefix: ""))
        #expect(BarScope.tag("work").isNamed(byPrefix: "wo"))
    }

    @Test("Backspace leaves a tag for the tags, and anything else for no scope")
    func parents() {
        #expect(BarScope.tag("work").parent == .tags)
        for scope in [BarScope.notes, .commands, .contents, .tags, .recent, .frequent] {
            #expect(scope.parent == nil, "\(scope)")
        }
    }

    @Test("A folder chip shows its own name, and Backspace goes back to the folders")
    func folders() {
        #expect(BarScope.folder("Work/Thesis").title == "Thesis")
        #expect(BarScope.folder("Work/Thesis").placeholder == "Search in Work/Thesis")
        #expect(BarScope.folder("Work/Thesis").parent == .folders)
        #expect(BarScope.folders.parent == nil)
        #expect(BarScope.folder("Work").useKey != BarScope.tag("Work").useKey)
    }

    /// Text is searched beside names only where the notes are a chosen few.
    @Test("Only a tag or a folder searches text beside names")
    func textToo() {
        #expect(BarScope.tag("x").searchesTextToo)
        #expect(BarScope.folder("x").searchesTextToo)
        for scope in [BarScope.notes, .commands, .contents, .tags, .folders, .recent, .frequent] {
            #expect(!scope.searchesTextToo, "\(scope)")
        }
    }

    @Test("Commands and tags ignore the focused folder; notes and text follow it")
    func folderFocus() {
        #expect(!BarScope.commands.followsFolderFocus)
        #expect(!BarScope.tags.followsFolderFocus)
        #expect(!BarScope.folder("Home").followsFolderFocus, "a chosen folder outranks the focus")
        #expect(BarScope.notes.followsFolderFocus)
        #expect(BarScope.contents.followsFolderFocus)
        #expect(BarScope.tag("x").followsFolderFocus)
    }
}

@Suite("Command match tiers")
struct CommandMatchTests {

    private func score(_ query: String, _ title: String, _ terms: String = "") -> Int? {
        CommandMatch.score(query: query, title: title, terms: terms)
    }

    /// The same ladder as note names, so the two rank against each other.
    @Test("A title outranks its synonyms at every step")
    func ladder() {
        #expect(score("bold", "Bold") == 400)
        #expect(score("quick open", "Quick Open…") == 400, "the ellipsis is not part of the name")
        #expect(score("show", "Show backlinks") == 300)
        #expect(score("back", "Show backlinks") == 250, "a word of the title")
        #expect(score("links", "Show backlinks") == 200)
        #expect(score("strong", "Bold", "strong emphasis") == 150, "only a synonym")
        #expect(score("zebra", "Bold", "strong emphasis") == nil)
    }

    /// The palette's old rule was "the query appears in title plus terms";
    /// nothing it found may go missing.
    @Test("Every command the old palette found is still found")
    @MainActor
    func nothingLost() {
        for command in AppCommand.registry {
            for query in ["note", "open", "copy", "toggle", "path", "format"] where command.matches(query) {
                #expect(
                    CommandMatch.score(query: query, title: command.title, terms: command.searchTerms) != nil,
                    "\(command.id) for \(query)"
                )
            }
        }
    }
}

@Suite("Scored note search")
struct ScoredSearchTests {

    private func index(_ names: [String]) -> VaultIndex {
        let root = URL(fileURLWithPath: "/vault")
        let items = names.map {
            VaultItem(
                url: root.appendingPathComponent("\($0).md"), relativePath: "\($0).md",
                kind: .markdown, name: $0, children: []
            )
        }
        return VaultIndex.build(root: VaultItem(
            url: root, relativePath: "", kind: .folder, name: "", children: items
        ))
    }

    @Test("The scores order exactly as the plain search does, and nothing typed matches nothing")
    func agreesWithSearch() {
        let index = index(["Meeting", "Meeting Notes", "Weekly meeting", "Plan"])
        let scored = index.scoredSearch("meet", limit: 10)
        #expect(scored.map(\.note) == index.search("meet", limit: 10))
        #expect(scored.map(\.score) == scored.map(\.score).sorted(by: >))
        #expect(scored.first?.score == 300, "a prefix match")
        #expect(index.scoredSearch("", limit: 10).isEmpty)
    }

    /// The search that prompted this: "0." listed three never-opened notes
    /// that start with it above the version note in daily use, which only
    /// contains it, and the two version notes in scan order.
    @Test("A familiar word start beats an unused prefix, and use past the cap breaks ties")
    func versionSearch() {
        let index = index([
            "0.3.0 Post", "v0.6", "v0.7", "OpenAI Interview 01.10.2026", "Release 0.1.0 next steps",
        ])
        let use: [String: Double] = ["v0.7": 20, "v0.6": 5, "OpenAI Interview 01.10.2026": 8]
        let found = index.search("0.", limit: 10, familiarity: { use[$0.name] ?? 0 }).map(\.name)
        #expect(found == [
            "v0.7", "v0.6", "0.3.0 Post", "OpenAI Interview 01.10.2026", "Release 0.1.0 next steps",
        ], "familiarity crosses the half step either way; got \(found)")
        let scores = Dictionary(uniqueKeysWithValues: index.scoredSearch("0.", limit: 10).map { ($0.note.name, $0.score) })
        #expect(scores["Release 0.1.0 next steps"] == 250, "a word start, after a space")
        #expect(scores["v0.7"] == 250, "a word start, where letters turn into digits")
        #expect(scores["OpenAI Interview 01.10.2026"] == 200, "inside a number is only contained")
    }

    @Test("A pin counts as fully familiar and wins a tie")
    func pinsBoost() {
        let index = index(["v0.5", "v0.7", "0.3.0 Post"])
        let use: [String: Double] = ["v0.7": 20]
        let found = index.search(
            "0.", limit: 10, familiarity: { use[$0.name] ?? 0 }, pinned: { $0.name == "v0.5" }
        ).map(\.name)
        #expect(found == ["v0.5", "v0.7", "0.3.0 Post"], "got \(found)")
    }

    @Test("A word starts after a separator or where letters and digits meet")
    func wordStarts() {
        #expect(VaultIndex.matchesWordStart("plan", in: "weekly plan"))
        #expect(VaultIndex.matchesWordStart("plan", in: "q3plan"))
        #expect(VaultIndex.matchesWordStart("2", in: "draft2"))
        #expect(VaultIndex.matchesWordStart("plan", in: "a-plan"))
        #expect(!VaultIndex.matchesWordStart("lan", in: "weekly plan"))
        #expect(!VaultIndex.matchesWordStart("plan", in: "plan"), "a prefix is its own tier")
        #expect(VaultIndex.matchesWordStart("an", in: "banana an"), "a later occurrence counts")
    }
}

/// What each scope lists, from a real vault on disk.
@MainActor
@Suite("Search bar rows", .serialized)
struct SearchBarRowTests {

    private func model(
        _ files: [String: String], scope: String? = nil, edited: [String: Date] = [:]
    ) async throws -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-bar-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            if let date = edited[path] {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, scopePath: scope)
        )
        for _ in 0..<600 where model.index.notes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.index.notes.isEmpty, "the vault never finished scanning")
        return model
    }

    private func ids(_ rows: [BarRow]) -> [String] { rows.map(\.id) }

    private static let frequentOnly = StartList(
        rows: [.init(.frequent, Set(StartList.Kind.allCases), count: 12)]
    )

    /// The bar ⌘T opens: the last note opened, then what is used most. The
    /// scopes are chips above the list and cost it no rows.
    @Test("With nothing typed: recent, then frequent")
    func startRows() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b", "Gamma.md": "c"])
        defer { model.closeWorkspace() }
        let session = try #require(model.session)
        for _ in 0..<5 { session.recordRecent("Alpha.md") }
        session.recordRecent("Gamma.md")

        // A row after Frequent, so Frequent does not fill the rest; the last
        // row would go on to every note.
        let start = StartList(rows: [
            .init(.recent, [.notes], count: 1), .init(.frequent, Set(StartList.Kind.allCases), count: 12),
            .init(.recent, [.scopes], count: 1),
        ])
        let rows = ids(model.barRows(scope: nil, query: "", entireVault: true, start: start))
        #expect(Array(rows.prefix(4)) == [
            "heading:Recent notes", "note:Gamma.md", "heading:Frequent", "note:Alpha.md",
        ], "got \(rows)")
        // The store of uses is app-wide and other tests enter scopes, so the
        // rule checked is the real one: a scope listed here has been used.
        for scope in BarScope.searchable where rows.contains("scope:\(scope.title)") {
            #expect(FrecencyStore.commands.score(scope.useKey) > 0, "\(scope) is listed unused")
        }
        #expect(!rows.contains("note:Beta.md"), "an unused note is not frequent")
        // Nor an unused command, though it can run: Frequent is what you use.
        for row in rows where row.hasPrefix("command:") {
            #expect(FrecencyStore.commands.score(String(row.dropFirst(8))) > 0, "\(row) is unused")
        }
    }

    /// No note opened yet still lists the notes, under All notes, which
    /// fills the rest by default. Commands may already be frequent, since
    /// that store is app-wide.
    @Test("A vault with no history still lists its notes")
    func noHistory() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b"])
        defer { model.closeWorkspace() }
        let rows = model.barRows(scope: nil, query: "", entireVault: true, start: .standard)
        #expect(Array(ids(rows).suffix(3)) == ["heading:Frequent notes", "note:Alpha.md", "note:Beta.md"])

        // No rows at all would be an empty sheet; it opens on the notes.
        #expect(ids(model.barRows(scope: nil, query: "", entireVault: true, start: StartList(rows: [])))
            == ["heading:Notes", "note:Alpha.md", "note:Beta.md"])
    }

    /// Focusing a window on a folder is using it, as entering it in the bar
    /// is, so it ranks among recent and frequent folders.
    @Test("Focusing a folder counts as using it")
    func focusCounts() async throws {
        let model = try await model(["Work/Plan.md": "a"])
        defer { model.closeWorkspace() }
        let before = FrecencyStore.commands.score(BarScope.folder("Work").useKey)
        let item = try #require(model.tree?.children.first { $0.name == "Work" })
        model.setScope(to: item)
        #expect(FrecencyStore.commands.score(BarScope.folder("Work").useKey) > before)
        #expect(RecentUses.dates()[BarScope.folder("Work").useKey] != nil)
    }

    /// The sidebar's own openings count too, from the clicks that open them.
    @Test("Opening a folder or a tag in the sidebar counts as using it")
    func sidebarCounts() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("model.recordScopeUse(.folder(item.relativePath))"))
        #expect(source.contains("model.recordScopeUse(.tag(name))"))
    }

    /// Recent rows are only as good as their history: running a command and
    /// entering a scope both record when.
    @Test("Running a command or entering a scope records when")
    func usesAreRecorded() throws {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        let command = try #require(AppCommand.registry.first { $0.id == "toggleBacklinks" })
        let before = Date().addingTimeInterval(-1)
        command.perform(on: model)
        model.recordScopeUse(.folder("Work"))
        let dates = RecentUses.dates()
        #expect((dates[RecentUses.commandKey("toggleBacklinks")] ?? .distantPast) > before)
        #expect((dates[BarScope.folder("Work").useKey] ?? .distantPast) > before)
    }

    /// The sections come in the reader's order, each capped, nothing twice,
    /// and the last one switched on takes the rest.
    @Test("The start list follows its setting")
    func startListOrder() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b", "Gamma.md": "c"])
        defer { model.closeWorkspace() }
        try #require(model.session).recordRecent("Gamma.md")
        // In the future, so no other test's uses of the same app-wide store
        // can come between them.
        let soon = Date().addingTimeInterval(10_000)
        RecentUses.record(RecentUses.commandKey("toggleBacklinks"), at: soon)
        RecentUses.record(RecentUses.commandKey("toggleSidebar"), at: soon.addingTimeInterval(1))
        let start = StartList(rows: [
            .init(.recent, [.commands], count: 1),
            .init(.recent, [.notes], count: 5),
            .init(.frequent, [.notes], count: 1),
        ])
        let rows = ids(model.barRows(scope: nil, query: "", entireVault: true, start: start))
        #expect(rows == [
            "heading:Recent commands", "command:toggleSidebar",
            "heading:Recent notes", "note:Gamma.md",
            // The last row, so its count of one does not apply, and it goes on
            // past the used notes to every note; Gamma is not repeated.
            "heading:Frequent notes", "note:Alpha.md", "note:Beta.md",
        ], "got \(rows)")
    }

    /// One row can mix kinds; a recent one orders them by when they were
    /// used, whatever kind each is.
    @Test("A recent row of several kinds orders them by time")
    func recentMix() async throws {
        let model = try await model(["Work/Plan.md": "a", "Home.md": "b"])
        defer { model.closeWorkspace() }
        try #require(model.session).recordRecent("Home.md")
        let later = Date().addingTimeInterval(1_000_000)
        RecentUses.record(BarScope.folder("Work").useKey, at: later)
        RecentUses.record(RecentUses.commandKey("toggleBacklinks"), at: later.addingTimeInterval(-1))
        let start = StartList(rows: [.init(.recent, [.notes, .folders, .commands], count: 30)])
        let rows = ids(model.barRows(scope: nil, query: "", entireVault: true, start: start))
        // Other tests use commands in the same app-wide store, so the check
        // is the order of these three, not the whole list.
        let folder = try #require(rows.firstIndex(of: "folder:Work"), "got \(rows)")
        let command = try #require(rows.firstIndex(of: "command:toggleBacklinks"))
        let note = try #require(rows.firstIndex(of: "note:Home.md"))
        #expect(rows.first == "heading:Recent notes, commands and folders")
        #expect(folder < command && command < note, "got \(rows)")
        // A row that ticks nothing lists nothing and takes no heading.
        let empty = StartList(rows: [.init(.recent, [], count: 3), .init(.recent, [.folders], count: 3)])
        #expect(ids(model.barRows(scope: nil, query: "", entireVault: true, start: empty)).first
            == "heading:Recent folders")
    }

    /// Frequent mixes both kinds on one scale.
    @Test("A command used often sits among the frequent notes")
    func frequentMixesCommands() async throws {
        let model = try await model(["Alpha.md": "a"])
        defer { model.closeWorkspace() }
        for _ in 0..<40 { FrecencyStore.commands.record("toggleSidebar") }
        let rows = ids(model.barRows(scope: nil, query: "", entireVault: true, start: Self.frequentOnly))
        #expect(rows.contains("command:toggleSidebar"), "got \(rows)")
    }

    /// "rec" offers Recent as a row, ranked with everything else, so Space or
    /// Tab can make it the chip; tags are found by name without the hash.
    @Test("Scopes and tags are found by name")
    func scopesByName() async throws {
        let model = try await model(["Plan.md": "#work", "Diary.md": "x"])
        defer { model.closeWorkspace() }
        #expect(ids(model.barRows(scope: nil, query: "rec", entireVault: true)).first == "scope:Recent notes")
        #expect(ids(model.barRows(scope: nil, query: "tags", entireVault: true)).first == "scope:Tags")
        #expect(ids(model.barRows(scope: nil, query: "most used", entireVault: true))
            .contains("scope:Frequent notes"), "a synonym finds it too")
        #expect(ids(model.barRows(scope: nil, query: "wor", entireVault: true)).first == "tag:work")
    }

    /// "Search the Vault…" and the Text scope are the same choice; with no
    /// scope only the scope is listed, and the command's words still find it.
    @Test("A command that only opens a scope is not listed beside it")
    func noDuplicateScopeCommands() async throws {
        let model = try await model(["Plan.md": "x"])
        defer { model.closeWorkspace() }
        let search = ids(model.barRows(scope: nil, query: "search the vault", entireVault: true))
        #expect(search.contains("scope:Text"), "got \(search)")
        #expect(!search.contains("command:searchVault"))
        let open = ids(model.barRows(scope: nil, query: "quick open", entireVault: true))
        #expect(open.contains("scope:Notes"), "got \(open)")
        #expect(!open.contains("command:quickOpen"))
        // The palette itself still lists them.
        #expect(ids(model.barRows(scope: .commands, query: "search", entireVault: true))
            .contains("command:searchVault"))
    }

    /// A scope entered is a use, so it climbs and appears among Frequent.
    @Test("A scope used often is frequent")
    func scopeUseCounts() async throws {
        let model = try await model(["Alpha.md": "a #home"])
        defer { model.closeWorkspace() }
        for _ in 0..<30 { model.recordScopeUse(.tags) }
        for _ in 0..<30 { model.recordScopeUse(.tag("home")) }
        let rows = ids(model.barRows(scope: nil, query: "", entireVault: true, start: Self.frequentOnly))
        #expect(rows.contains("scope:Tags"), "got \(rows)")
        #expect(rows.contains("tag:home"), "got \(rows)")
    }

    /// Typed with no scope: one ranking across notes and commands, and the
    /// text search offered last rather than mixed in.
    @Test("Typed: notes and commands ranked together, text search last")
    func everything() async throws {
        let asked = GeneralSettings.shared.asksAgent
        GeneralSettings.shared.asksAgent = true
        defer { GeneralSettings.shared.asksAgent = asked }
        let model = try await model(["Bold ideas.md": "x", "Plan.md": "y"])
        defer { model.closeWorkspace() }
        // With no note open, Bold cannot run, so it sinks below the note
        // although it matches better.
        let closed = ids(model.barRows(scope: nil, query: "bold", entireVault: true))
        #expect(
            try #require(closed.firstIndex(of: "command:formatBold"))
                > (try #require(closed.firstIndex(of: "note:Bold ideas.md")))
        )

        model.open(try #require(model.index.notes.first { $0.name == "Plan" }))
        let rows = ids(model.barRows(scope: nil, query: "bold", entireVault: true))
        let command = try #require(rows.firstIndex(of: "command:formatBold"), "got \(rows)")
        let note = try #require(rows.firstIndex(of: "note:Bold ideas.md"))
        // The command's title is the query exactly; the note's only starts
        // with it.
        #expect(command < note)
        // Text search, then asking the agent, last.
        #expect(Array(rows.suffix(2)) == ["searchText", "ask"])
        #expect(!rows.contains("note:Plan.md"))
        // The contents of a note are never searched here.
        #expect(!rows.contains { $0.hasPrefix("hit:") })
    }

    @Test("A pasted path puts its note first with no scope too")
    func pathFirst() async throws {
        let model = try await model(["Archive/Report.md": "old", "Report.md": "new"])
        defer { model.closeWorkspace() }
        let rows = ids(model.barRows(scope: nil, query: "Archive/Report.md", entireVault: true))
        #expect(rows.first == "note:Archive/Report.md")
        #expect(rows.filter { $0 == "note:Archive/Report.md" }.count == 1)
    }

    /// ⌘O is the same list it always was, with its headings as ways into
    /// their own scope and the text search offered after the names.
    @Test("The notes scope keeps Quick Open's order, headings and all")
    func notesScope() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b"])
        defer { model.closeWorkspace() }
        try #require(model.session).recordRecent("Beta.md")
        let order = QuickOpenOrder(lead: .recent, count: 1)
        let rows = model.barRows(scope: .notes, query: "", entireVault: true, order: order)
        #expect(ids(rows) == ["heading:Recent", "note:Beta.md", "heading:Frequent", "note:Alpha.md"])
        #expect(rows.first?.isSelectable == false, "a heading is a label the arrows pass over")

        let typed = ids(model.barRows(scope: .notes, query: "alp", entireVault: true, order: order))
        #expect(typed == ["note:Alpha.md", "searchText"])
    }

    @Test("Recent lists the whole history in order, narrowed by a name")
    func recentScope() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b", "Gamma.md": "c"])
        defer { model.closeWorkspace() }
        let session = try #require(model.session)
        session.recordRecent("Alpha.md")
        session.recordRecent("Gamma.md")
        #expect(ids(model.barRows(scope: .recent, query: "", entireVault: true))
            == ["note:Gamma.md", "note:Alpha.md"])
        #expect(ids(model.barRows(scope: .recent, query: "alp", entireVault: true))
            == ["note:Alpha.md"])
    }

    /// Choosing a tag makes it the chip: its notes, searched by name.
    @Test("Tags list with counts, and one tag lists only its notes")
    func tags() async throws {
        let model = try await model([
            "Plan.md": "#work and #home", "Report.md": "#work", "Diary.md": "#home", "Loose.md": "none",
        ])
        defer { model.closeWorkspace() }
        let tags = model.barRows(scope: .tags, query: "", entireVault: true)
        let counts = tags.compactMap { row -> String? in
            guard case .tag(let name, let count) = row else { return nil }
            return "\(name):\(count)"
        }
        #expect(Set(counts) == ["work:2", "home:2"])
        // The first tag, past any Recent heading another test's recorded use
        // of #work puts above it: uses are kept across tests.
        let first = tags.first { $0.isSelectable }
        #expect(first?.scope == .tag("work") || first?.scope == .tag("home"))

        #expect(Set(ids(model.barRows(scope: .tag("work"), query: "", entireVault: true)))
            == ["note:Plan.md", "note:Report.md"])
        #expect(ids(model.barRows(scope: .tag("work"), query: "rep", entireVault: true))
            == ["note:Report.md"])
    }

    /// Folders hold their notes at any depth; a folder of nothing but
    /// subfolders still counts what is under them.
    @Test("Folders list with every note under them, and one folder lists those notes")
    func folders() async throws {
        let model = try await model([
            "Work/Plan.md": "a", "Work/Thesis/Draft.md": "b", "Work/Thesis/Notes.md": "c",
            "Home/List.md": "d", "Loose.md": "e",
        ])
        defer { model.closeWorkspace() }
        let folders = model.barRows(scope: .folders, query: "", entireVault: true).compactMap { row -> String? in
            guard case .folder(let path, let count) = row else { return nil }
            return "\(path):\(count)"
        }
        #expect(Set(folders) == ["Work:3", "Work/Thesis:2", "Home:1"])
        #expect(Set(ids(model.barRows(scope: .folder("Work"), query: "", entireVault: true)))
            == ["note:Work/Plan.md", "note:Work/Thesis/Draft.md", "note:Work/Thesis/Notes.md"])
        #expect(ids(model.barRows(scope: .folder("Work"), query: "dra", entireVault: true))
            == ["note:Work/Thesis/Draft.md"])
        #expect(ids(model.barRows(scope: nil, query: "thesis", entireVault: true)).first
            == "folder:Work/Thesis")
        #expect(model.barRows(scope: nil, query: "thesis", entireVault: true).first?.scope
            == .folder("Work/Thesis"))
    }

    /// In a tag or a folder the names come first and the lines that match
    /// follow under their own heading; elsewhere text is its own scope.
    @Test("A tag lists names, then the text that matched inside its notes")
    func textInTag() async throws {
        let model = try await model([
            "Milk run.md": "#shop buy oat", "Bakery.md": "#shop milk bread", "Other.md": "milk",
        ])
        defer { model.closeWorkspace() }
        let notes = model.barSearchableNotes(scope: .tag("shop"), entireVault: true)
        #expect(Set(notes.map(\.name)) == ["Milk run", "Bakery"], "only the tag's notes are read")
        let text = ContentSearch.run(notes: notes, query: "milk")

        let rows = ids(model.barRows(scope: .tag("shop"), query: "milk", entireVault: true, text: text))
        #expect(Array(rows.prefix(2)) == ["note:Milk run.md", "heading:Text"], "got \(rows)")
        #expect(rows.contains { $0.hasPrefix("hit:Bakery.md") })
        #expect(!rows.contains { $0.hasPrefix("hit:Other.md") })

        // Without text there are no headings; the notes scope never mixes it.
        #expect(ids(model.barRows(scope: .tag("shop"), query: "milk", entireVault: true))
            == ["note:Milk run.md"])
        #expect(!ids(model.barRows(scope: .notes, query: "milk", entireVault: true, text: text))
            .contains { $0.hasPrefix("hit:") })
        #expect(ids(model.barRows(scope: .contents, query: "milk", entireVault: true, text: text))
            .allSatisfy { $0.hasPrefix("hit:") })
    }

    /// With no scope the text is searched only when names found little:
    /// enough names and jumping by name is left exactly as it was.
    @Test("Text is searched only when names leave room in the list")
    func textThreshold() async throws {
        var files = ["Diary.md": "zebra #log"]
        for i in 0..<AppModel.barTextThreshold { files["Report \(i).md"] = "#log" }
        let model = try await model(files)
        defer { model.closeWorkspace() }
        #expect(!model.barWantsText(scope: nil, query: "report", entireVault: true), "names fill the list")
        #expect(model.barWantsText(scope: nil, query: "zebra", entireVault: true), "no name at all")
        #expect(model.barWantsText(scope: nil, query: "report 1", entireVault: true), "a few names")
        #expect(!model.barWantsText(scope: nil, query: "", entireVault: true))
        #expect(!model.barWantsText(scope: .notes, query: "zebra", entireVault: true), "⌘O never")
        #expect(model.barWantsText(scope: .contents, query: "report", entireVault: true), "text always")
        // A tag follows the same line as the bar with no scope.
        #expect(!model.barWantsText(scope: .tag("log"), query: "report", entireVault: true))
        #expect(model.barWantsText(scope: .tag("log"), query: "zebra", entireVault: true))
    }

    /// The names stay first; a few lines follow; the last row says how many
    /// there are in all and leads to them.
    @Test("With no scope, a few matching lines follow the names")
    func textPreview() async throws {
        let asked = GeneralSettings.shared.asksAgent
        GeneralSettings.shared.asksAgent = true
        defer { GeneralSettings.shared.asksAgent = asked }
        var files = ["Zebra notes.md": "zebra"]
        for i in 0..<12 { files["Day \(i).md"] = "saw a zebra today" }
        let model = try await model(files)
        defer { model.closeWorkspace() }
        let text = ContentSearch.run(notes: model.index.notes, query: "zebra")
        let rows = model.barRows(scope: nil, query: "zebra", entireVault: true, text: text)
        let rowIDs = ids(rows)
        let heading = try #require(rowIDs.firstIndex(of: "heading:Text"), "got \(rowIDs)")
        #expect(!rows[heading].isSelectable, "a label, like every heading")
        #expect(rowIDs.firstIndex(of: "note:Zebra notes.md")! < heading, "names first")
        #expect(rowIDs.filter { $0.hasPrefix("hit:") }.count == AppModel.barTextPreview)
        #expect(rowIDs.last == "ask", "asking comes after everything")
        guard case .searchText(_, let matches) = try #require(rows.dropLast().last) else {
            Issue.record("the row before it leads to the text scope"); return
        }
        #expect(matches == 13)
    }

    /// One setting orders every scope with nothing typed: commands, tags
    /// and folders get the recent and frequent parts notes have.
    @Test("Commands, tags and folders list recent, then frequent")
    func scopesArranged() async throws {
        let model = try await model(["Work/Plan.md": "#home", "Home/List.md": "#work"])
        defer { model.closeWorkspace() }
        let soon = Date().addingTimeInterval(3_000_000)
        RecentUses.record(RecentUses.commandKey("toggleBacklinks"), at: soon)
        RecentUses.record(BarScope.tag("work").useKey, at: soon)
        RecentUses.record(BarScope.folder("Home").useKey, at: soon)
        let first = QuickOpenOrder(lead: .recent, count: 1)

        let commands = ids(model.barRows(scope: .commands, query: "", entireVault: true, order: first))
        #expect(Array(commands.prefix(3)) == [
            "heading:Recent", "command:toggleBacklinks", "heading:Frequent",
        ], "got \(commands)")
        #expect(commands.filter { $0 == "command:toggleBacklinks" }.count == 1)

        let tags = ids(model.barRows(scope: .tags, query: "", entireVault: true, order: first))
        #expect(Array(tags.prefix(3)) == ["heading:Recent", "tag:work", "heading:Frequent"])

        let folders = ids(model.barRows(scope: .folders, query: "", entireVault: true, order: first))
        #expect(Array(folders.prefix(3)) == ["heading:Recent", "folder:Home", "heading:Frequent"])

        // One order alone: no headings, and nothing dropped.
        let only = ids(model.barRows(
            scope: .tags, query: "", entireVault: true, order: first.with(mode: .recentOnly)
        ))
        #expect(only == ["tag:work", "tag:home"], "got \(only)")
    }

    /// Recent notes first and frequent commands first, at once.
    @Test("Each scope follows its own order")
    func ordersPerScope() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b"])
        defer { model.closeWorkspace() }
        try #require(model.session).recordRecent("Alpha.md")
        for _ in 0..<5 { FrecencyStore.commands.record("toggleBacklinks") }
        var orders = ScopeOrders.standard
        orders[.commands] = QuickOpenOrder(lead: .frequent, count: 1)
        let notes = ids(model.barRows(scope: .notes, query: "", entireVault: true, orders: orders))
        #expect(notes.first == "heading:Recent", "got \(notes)")
        let commands = ids(model.barRows(scope: .commands, query: "", entireVault: true, orders: orders))
        #expect(commands.first == "heading:Frequent", "got \(commands)")
        #expect(commands.dropFirst().first?.hasPrefix("command:") == true, "commands lead, by use")
    }

    /// A folder or a tag lists its own notes in its own order before
    /// anything is typed, with the pinned ones among them first; it used to
    /// list them as the scan found them.
    @Test("A folder and a tag order their notes by their own rows")
    func notesInScopeOrdered() async throws {
        let now = Date()
        let model = try await model(
            [
                "Work/Zeta.md": "#t", "Work/Note 10.md": "#t", "Work/Note 2.md": "z",
                "Home/Alpha.md": "#t",
            ],
            edited: [
                "Work/Zeta.md": now.addingTimeInterval(-300),
                "Work/Note 10.md": now.addingTimeInterval(-100),
                "Home/Alpha.md": now.addingTimeInterval(-200),
                "Work/Note 2.md": now.addingTimeInterval(-400),
            ]
        )
        defer { model.closeWorkspace() }
        model.togglePin(.init(.note, "Work/Zeta.md"))
        model.togglePin(.init(.note, "Home/Alpha.md"))
        var orders = ScopeOrders.standard
        orders[.folder] = QuickOpenOrder.standard.with(mode: .alphabetical)
        orders[.tag] = QuickOpenOrder.standard.with(mode: .lastEdited)

        let folder = ids(model.barRows(scope: .folder("Work"), query: "", entireVault: true, orders: orders))
        #expect(folder == [
            "heading:Pinned", "note:Work/Zeta.md",
            "heading:Alphabetical", "note:Work/Note 2.md", "note:Work/Note 10.md",
        ], "got \(folder)")

        model.togglePin(.init(.note, "Work/Zeta.md"))
        let tag = ids(model.barRows(scope: .tag("t"), query: "", entireVault: true, orders: orders))
        #expect(tag == [
            "heading:Pinned", "note:Home/Alpha.md",
            "heading:Last edited", "note:Work/Note 10.md", "note:Work/Zeta.md",
        ], "got \(tag)")

        // Each follows its own row: the folder's order is not the tag's.
        orders[.folder] = QuickOpenOrder.standard.with(mode: .lastEdited)
        let byEdit = ids(model.barRows(scope: .folder("Work"), query: "", entireVault: true, orders: orders))
        #expect(byEdit == ["note:Work/Note 10.md", "note:Work/Zeta.md", "note:Work/Note 2.md"],
                "a pin outside the folder stays out; got \(byEdit)")
    }

    /// Ask lists the chats already had, latest first; typing offers the
    /// question and a drafted note first, then the chats that mention it.
    @Test("Ask lists its chats, and typed text becomes a question or a draft")
    func askRows() async throws {
        let asked = GeneralSettings.shared.asksAgent
        GeneralSettings.shared.asksAgent = true
        defer { GeneralSettings.shared.asksAgent = asked }
        let model = try await model(["Plan.md": "a", "What we decided about the plan.md": "b"])
        defer { model.closeWorkspace() }
        let root = try #require(model.vaultRoot)
        var parser = AgentChat(question: "When is the parser due?", scope: "", createdAt: Date(timeIntervalSince1970: 100))
        parser.turns[0].answer = "Friday."
        let sidebar = AgentChat(question: "Ideas for the sidebar", scope: "", createdAt: Date(timeIntervalSince1970: 200))
        try AgentChatStore.save(parser, in: root)
        try AgentChatStore.save(sidebar, in: root)
        model.agent.load(vaultRoot: root)

        let empty = ids(model.barRows(scope: .ask, query: "", entireVault: true))
        #expect(empty == ["heading:Chats", "chat:\(sidebar.id)", "chat:\(parser.id)"], "got \(empty)")
        let typed = ids(model.barRows(scope: .ask, query: "friday", entireVault: true))
        #expect(typed == ["ask", "draftNote", "heading:Chats", "chat:\(parser.id)"], "got \(typed)")

        let unscoped = ids(model.barRows(scope: nil, query: "plan", entireVault: true))
        #expect(unscoped.last == "ask")
        #expect(!ids(model.barRows(scope: nil, query: "", entireVault: true)).contains("ask"))

        // Text that reads as a question puts Ask first, where Return is,
        // unless a name answers to it; the reader decides when.
        let question = "what did I write about the parser this week"
        #expect(ids(model.barRows(scope: nil, query: question, entireVault: true, askFirst: .forQuestions)).first == "ask")
        #expect(ids(model.barRows(scope: nil, query: question, entireVault: true, askFirst: .never)).last == "ask")
        #expect(ids(model.barRows(scope: nil, query: "plan", entireVault: true, askFirst: .forQuestions)).last == "ask",
                "a search stays a search")
        let nothing = "zqxv wrrt plmk"
        #expect(ids(model.barRows(scope: nil, query: nothing, entireVault: true, askFirst: .whenNothingFound)).first == "ask")
        // With "when nothing is found", anything found keeps Ask last.
        #expect(ids(model.barRows(scope: nil, query: "plan", entireVault: true, askFirst: .whenNothingFound)).last == "ask")
        // Found in a note's text, not named: a question still asks first,
        // and "when nothing is found" lets the match lead.
        let plan = try #require(model.index.notes.first { $0.name == "Plan" })
        let hit = ContentMatch(note: plan, line: 1, preview: "a", occurrences: 1)
        let text = ContentSearchResult(query: question, matches: [hit], totalOccurrences: 1, matchedNotes: 1)
        #expect(ids(model.barRows(scope: nil, query: question, entireVault: true, text: text, askFirst: .forQuestions)).first == "ask")
        #expect(ids(model.barRows(scope: nil, query: question, entireVault: true, text: text, askFirst: .whenNothingFound)).first != "ask")

        // A note named by the words is opened, question or not.
        let named = ids(model.barRows(scope: nil, query: "what we decided about the plan", entireVault: true, askFirst: .forQuestions))
        #expect(named.first == "note:What we decided about the plan.md", "got \(named)")

        // A chat is found in ⌘T by its title, and by what was said in it
        // after every name.
        let byTitle = ids(model.barRows(scope: nil, query: "sidebar", entireVault: true))
        #expect(byTitle.contains("chat:\(sidebar.id)"))
        let byAnswer = ids(model.barRows(scope: nil, query: "friday", entireVault: true))
        #expect(byAnswer.contains("chat:\(parser.id)"), "got \(byAnswer)")

        // A chat opened is listed in ⌘T before anything is typed, ranked by
        // use like the rest, and only while Ask is on.
        model.recordChatUse(sidebar.id)
        let start = StartList(rows: [.init(.recent, [.chats], count: 5)])
        #expect(ids(model.barRows(scope: nil, query: "", entireVault: true, start: start)).contains("chat:\(sidebar.id)"))
        #expect(!ids(model.barRows(scope: nil, query: "", entireVault: true, start: start)).contains("chat:\(parser.id)"),
                "never opened, so not listed")

        // Off, which it is until turned on: no row, no chip, not found by name.
        GeneralSettings.shared.asksAgent = false
        #expect(!ids(model.barRows(scope: nil, query: "plan", entireVault: true)).contains("ask"))
        #expect(!BarScope.shownChips.contains(.ask))
        #expect(!ids(model.barRows(scope: nil, query: "", entireVault: true, start: start)).contains("chat:\(sidebar.id)"))
        #expect(!ids(model.barRows(scope: nil, query: "sidebar", entireVault: true)).contains("chat:\(sidebar.id)"))
        #expect(!ids(model.barRows(scope: nil, query: "ask", entireVault: true)).contains("scope:Ask"))
        GeneralSettings.shared.asksAgent = true
        #expect(BarScope.shownChips.last == .ask)
    }

    /// ⌘1 is the first chip, as Spotlight numbers its categories.
    @Test("The chips are numbered by their place")
    func chipNumbers() {
        #expect(BarScope.chip(number: 1) == .notes)
        #expect(BarScope.chip(number: 5) == .contents)
        #expect(BarScope.chip(number: 6) == .ask)
        #expect(BarScope.chip(number: 7) == nil)
        #expect(BarScope.chip(number: 0) == nil)
        #expect(BarScope.tags.chipNumber == 3)
        #expect(BarScope.recent.chipNumber == nil)
    }

    /// What is pinned comes first in its scope, once, under its own
    /// heading; the rest keeps its order without it.
    @Test("Pins lead their scope and are not repeated below")
    func pinnedFirst() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b", "Gamma.md": "c"])
        defer { model.closeWorkspace() }
        try #require(model.session).recordRecent("Beta.md")
        model.togglePin(.init(.note, "Gamma.md"))
        model.togglePin(.init(.note, "Alpha.md"))
        model.togglePin(.init(.command, "toggleBacklinks"))
        let order = QuickOpenOrder(lead: .recent, count: 1)

        let notes = ids(model.barRows(scope: .notes, query: "", entireVault: true, order: order))
        #expect(Array(notes.prefix(3)) == ["heading:Pinned", "note:Gamma.md", "note:Alpha.md"], "got \(notes)")
        #expect(notes.filter { $0 == "note:Alpha.md" }.count == 1)
        #expect(notes.contains("heading:Recent") && notes.contains("note:Beta.md"))

        let commands = ids(model.barRows(scope: .commands, query: "", entireVault: true, order: order))
        #expect(Array(commands.prefix(2)) == ["heading:Pinned", "command:toggleBacklinks"])
        #expect(commands.filter { $0 == "command:toggleBacklinks" }.count == 1)

        // ⌘T's pinned row lists them across kinds, in the order pinned.
        let start = StartList(rows: [.init(.pinned, Set(StartList.Kind.allCases), count: 10)])
        let all = ids(model.barRows(scope: nil, query: "", entireVault: true, start: start))
        #expect(Array(all.prefix(4)) == ["heading:Pinned", "note:Gamma.md", "note:Alpha.md", "command:toggleBacklinks"],
                "got \(all)")
        #expect(model.isPinned(.note(try #require(model.index.notes.first { $0.name == "Gamma" }))))

        // Unpinning puts it back where it would be.
        model.togglePin(.init(.note, "Gamma.md"))
        let after = ids(model.barRows(scope: .notes, query: "", entireVault: true, order: order))
        #expect(Array(after.prefix(2)) == ["heading:Pinned", "note:Alpha.md"])
        #expect(after.contains("note:Gamma.md"))
        // The pins are the vault's, in a file beside the proposals.
        let root = try #require(model.vaultRoot)
        #expect(Pins.load(from: root).items.map(\.value) == ["Alpha.md", "toggleBacklinks"])
    }

    @Test("A matching line pins the note it is in")
    func hitPinsItsNote() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        let note = NoteRef(relativePath: "Work/Plan.md", url: URL(fileURLWithPath: "/v/Work/Plan.md"), name: "Plan", kind: .markdown)
        let hit = ContentMatch(note: note, line: 3, preview: "x", occurrences: 1)
        #expect(model.pin(for: .hit(hit)) == Pins.Pin(.note, "Work/Plan.md"))
    }

    @Test("A pinned note followed when it moves")
    func pinFollowsRename() async throws {
        let model = try await model(["Plan.md": "a"])
        defer { model.closeWorkspace() }
        model.togglePin(.init(.note, "Plan.md"))
        try #require(model.session).replaceRecentPath("Plan.md", with: "Work/Plan.md")
        #expect(model.pins.values(of: .note) == ["Work/Plan.md"])
    }

    @Test("The chips are the scopes with something to list, Text last of the searches, then Ask")
    func chips() {
        #expect(BarScope.chips == [.notes, .commands, .tags, .folders, .contents, .ask])
        #expect(BarScope.entered(byTyping: "?") == .ask)
        #expect(!BarScope.chips.contains(.recent) && !BarScope.chips.contains(.frequent))
        #expect(BarScope.recent.title == "Recent notes")
    }

    @Test("A focused window narrows notes but not commands")
    func folderFocus() async throws {
        let model = try await model(["Thesis/Draft.md": "a", "Home/Draft list.md": "b"], scope: "Thesis")
        defer { model.closeWorkspace() }
        let scoped = ids(model.barRows(scope: nil, query: "draft", entireVault: false))
        #expect(scoped.contains("note:Thesis/Draft.md"))
        #expect(!scoped.contains("note:Home/Draft list.md"))
        #expect(!model.barRows(scope: .commands, query: "", entireVault: false).isEmpty)
    }

    /// The commands that used to open a picker of their own now narrow the
    /// bar they were chosen in.
    @Test("Quick Open and Search the Vault are ways into their scopes")
    func pickerCommandsAreScopes() throws {
        let quickOpen = try #require(AppCommand.registry.first { $0.id == "quickOpen" })
        let search = try #require(AppCommand.registry.first { $0.id == "searchVault" })
        #expect(BarRow.command(quickOpen).scope == .notes)
        #expect(BarRow.command(search).scope == .contents)
        #expect(BarRow.searchText("x").scope == .contents)
        #expect(!BarRow.heading("Search In").isSelectable)
        #expect(BarRow.heading("Recent").scope == nil, "no heading leads anywhere")
    }

    /// ⌘1 to ⌘3 ask the sidebar for a view, and bring a hidden sidebar back.
    @Test("Asking for a sidebar view shows the sidebar on it")
    func sidebarViews() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        model.columnVisibility = .detailOnly
        model.showSidebar(.tags)
        #expect(model.sidebarModeRequest == .tags)
        #expect(model.columnVisibility != .detailOnly)
    }

    /// The menu bar cannot observe the model, so it watches this instead;
    /// it has to follow the bar exactly.
    @Test("The menu's view of the bar follows it open and closed")
    func barPresence() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        #expect(!model.barPresence.isOpen)
        model.openBar(.notes)
        #expect(model.barPresence.isOpen)
        model.isCommandPalettePresented = true
        #expect(model.barPresence.isOpen, "narrowing keeps it open")
        model.bar = nil
        #expect(!model.barPresence.isOpen)
    }

    /// While the bar is up, a shortcut that acts on the note or the window
    /// behind it is off. Read from the menu's source, as the shortcut table's
    /// own tests read it, since a menu cannot be driven without a window.
    @Test("Shortcuts that act behind the bar are off while it is open")
    func shortcutsBehindTheBar() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/HeftApp.swift"),
            encoding: .utf8
        )
        let behind = [
            "newNote", "openToday", "exportPDF", "toggleCheckbox", "find", "findNext",
            "findPrevious", "toggleSidebar", "toggleCalendar", "revealInSidebar", "toggleBacklinks",
            "sidebarView1", "sidebarView2", "sidebarView3",
        ]
        for id in behind {
            let marker = ".keyboardShortcut(.\(id))"
            let start = try #require(source.range(of: marker), "no menu item for \(id)")
            let rest = source[start.upperBound...]
            let next = rest.range(of: "Button(")?.lowerBound ?? rest.endIndex
            let nextToggle = rest.range(of: "Toggle(")?.lowerBound ?? rest.endIndex
            let item = rest[..<min(next, nextToggle)]
            #expect(item.contains("behindBar"), "\(id) still acts behind the bar")
        }
        // The bar's own keys must stay live, or they could not narrow it.
        for id in ["searchBar", "quickOpen", "commandPalette", "searchVault"] {
            let start = try #require(source.range(of: ".keyboardShortcut(.\(id))"))
            let rest = source[start.upperBound...]
            let item = rest[..<(rest.range(of: "Button(")?.lowerBound ?? rest.endIndex)]
            #expect(!item.contains("behindBar"), "\(id) is the bar's own")
        }
    }

    /// A shortcut pressed with the bar open narrows it in place: the same
    /// sheet, so nothing closes and reopens.
    @Test("Opening the bar while it is open narrows the same sheet")
    func reopening() {
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor())
        model.openBar(nil)
        let first = model.bar
        model.isCommandPalettePresented = true
        #expect(model.bar?.id == first?.id)
        #expect(model.bar?.scope == .commands)
        #expect(model.bar?.generation == 1)
        #expect(model.isCommandPalettePresented && !model.isQuickOpenPresented)

        // Closing a scope that is not the open one leaves the bar alone.
        model.isQuickOpenPresented = false
        #expect(model.bar != nil)
        model.isCommandPalettePresented = false
        #expect(model.bar == nil)
    }
}


@Suite("Start list setting")
struct StartListTests {

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "dev.stenglein.Heft.start-test-\(UUID().uuidString)"))
    }

    @Test("The standard list: pinned, recent notes, frequent everything, then the notes")
    func standard() {
        let plan = StartList.standard.plan
        #expect(plan.map(\.row.title) == ["Pinned", "Recent notes", "Frequent", "Frequent notes"])
        #expect(plan.map(\.limit) == [10, 5, 12, StartList.restLimit])
        #expect(StartList.standard.fillsRest(StartList.standard.rows[3]))
        #expect(!StartList.standard.fillsRest(StartList.standard.rows[2]))

        // A row with nothing ticked is not the last one: the row above it
        // still fills the rest.
        let trailing = StartList(rows: [.init(.frequent, [.notes], count: 3), .init(.recent, [], count: 3)])
        #expect(trailing.fillsRest(trailing.rows[0]))
        #expect(trailing.plan.map(\.limit) == [StartList.restLimit])
    }

    @Test("A row's heading names its kind when it has one")
    func titles() {
        #expect(StartList.Row(.recent, [.folders], count: 3).title == "Recent folders")
        #expect(StartList.Row(.frequent, [.notes, .tags], count: 3).title == "Frequent notes and tags")
        #expect(StartList.Row(.frequent, [.commands, .notes, .tags], count: 3).title
            == "Frequent notes, commands and tags", "kinds in their own order")
        #expect(StartList.Row(.recent, [.notes, .tags, .folders, .scopes], count: 3).title == "Recent")
        #expect(StartList.Row(.recent, [.notes, .tags], count: 3).kindsSummary == "Notes, Tags")
        #expect(StartList.Row(.recent, Set(StartList.Kind.allCases), count: 3).kindsSummary == "Everything")
        #expect(StartList.Row(.recent, [.notes], count: 99).count == StartList.countRange.upperBound)
    }

    @Test("A row saved as everything before chats existed lists chats too")
    func everythingBeforeChats() throws {
        let defaults = try suite()
        let stored = #"{"rows":[{"order":"frequent","kinds":["notes","commands","tags","folders","scopes"],"count":12},{"order":"recent","kinds":["notes"],"count":5}]}"#
        defaults.set(Data(stored.utf8), forKey: StartList.defaultsKey)
        let read = StartList.current(in: defaults)
        #expect(read.rows[0].kinds.contains(.chats), "everything then is everything now")
        #expect(read.rows[0].kindsSummary == "Everything")
        #expect(read.rows[1].kinds == [.notes], "a narrower row stays as it was")
    }

    @Test("Stored and read back in the reader's order")
    func roundTrip() throws {
        let defaults = try suite()
        #expect(StartList.current(in: defaults).matches(.standard), "nothing stored")
        var list = StartList.standard
        list.rows.swapAt(0, 2)
        list.rows.append(.init(.recent, [.tags, .folders], count: 7))
        list.save(in: defaults)
        #expect(StartList.current(in: defaults).matches(list))
    }

    /// A list written by a later version keeps what it can.
    @Test("An unknown order drops its row, an unknown kind drops only the kind")
    func tolerant() throws {
        let defaults = try suite()
        let json = #"{"rows":[{"order":"recent","kinds":["notes","pins"],"count":3},"#
            + #"{"order":"starred","kinds":["notes"],"count":4}]}"#
        defaults.set(Data(json.utf8), forKey: StartList.defaultsKey)
        let list = StartList.current(in: defaults)
        #expect(list.rows.count == 1)
        #expect(list.rows.first?.kinds == [.notes])
    }

    @Test("Uses are remembered by time, last first, and only so many")
    func recentUses() throws {
        let defaults = try suite()
        let start = Date()
        RecentUses.record("a", at: start, in: defaults)
        RecentUses.record("b", at: start.addingTimeInterval(1), in: defaults)
        RecentUses.record("a", at: start.addingTimeInterval(2), in: defaults)
        #expect(RecentUses.keys(in: defaults) == ["a", "b"])
        for i in 0..<100 { RecentUses.record("c\(i)", at: start.addingTimeInterval(10 + Double(i)), in: defaults) }
        #expect(RecentUses.keys(in: defaults).count == RecentUses.limit)
        #expect(RecentUses.keys(in: defaults).first == "c99")
    }
}


@Suite("Quick Open modes")
struct QuickOpenModeTests {

    /// "Alone" is a leading block of none, as the setting was always stored.
    @Test("Four choices map onto the order and count already stored")
    func modes() {
        #expect(QuickOpenOrder(lead: .recent, count: 5).mode == .recentFirst)
        #expect(QuickOpenOrder(lead: .frequent, count: 5).mode == .frequentFirst)
        #expect(QuickOpenOrder(lead: .frequent, count: 0).mode == .recentOnly)
        #expect(QuickOpenOrder(lead: .recent, count: 0).mode == .frequentOnly)
        for mode in QuickOpenOrder.Mode.allCases {
            #expect(QuickOpenOrder.standard.with(mode: mode).mode == mode)
        }
        // A count is kept across a change of order, and restored after "only".
        #expect(QuickOpenOrder(lead: .recent, count: 7).with(mode: .frequentFirst).count == 7)
        #expect(QuickOpenOrder(lead: .recent, count: 0).with(mode: .recentFirst).count
            == QuickOpenOrder.standard.count)
        // A plain sort keeps the block, so going back finds it as it was.
        let sorted = QuickOpenOrder(lead: .frequent, count: 7).with(mode: .alphabetical)
        #expect(sorted.with(mode: .frequentFirst) == QuickOpenOrder(lead: .frequent, count: 7))
        #expect(!QuickOpenOrder.Mode.choices(lastEdited: false).contains(.lastEdited))
        #expect(QuickOpenOrder.Mode.choices(lastEdited: true).contains(.lastEdited))
        #expect(ScopeOrders.Kind.folder.listsNotes && !ScopeOrders.Kind.commands.listsNotes)
    }

    @Test("Anything with a last use and a score is arranged as notes are")
    func arrangeItems() {
        let items = ["a", "b", "c", "d"]
        let last: [String: Double] = ["c": 3, "a": 2]
        let score: [String: Double] = ["b": 5, "a": 1]
        let recentFirst = QuickOpenOrder(lead: .recent, count: 1).arrangeItems(
            items, name: { $0 }, lastUsed: { last[$0] }, useScore: { score[$0] ?? 0 }
        )
        #expect(recentFirst.lead == ["c"])
        #expect(recentFirst.rest == ["b", "a", "d"], "by use, then the order given")
        #expect(recentFirst.heading == .recent)

        let frequentFirst = QuickOpenOrder(lead: .frequent, count: 1).arrangeItems(
            items, name: { $0 }, lastUsed: { last[$0] }, useScore: { score[$0] ?? 0 }
        )
        #expect(frequentFirst.lead == ["b"])
        #expect(frequentFirst.rest == ["c", "a", "d"], "by when used, then the rest")

        let recentOnly = QuickOpenOrder(lead: .frequent, count: 0).arrangeItems(
            items, name: { $0 }, lastUsed: { last[$0] }, useScore: { score[$0] ?? 0 }
        )
        #expect(recentOnly.lead.isEmpty && recentOnly.heading == nil)
        #expect(recentOnly.rest == ["c", "a", "b", "d"])

        // By name as Finder sorts, use ignored.
        let named = ["Item 10", "item 2", "Beta", "alpha"]
        let alphabetical = QuickOpenOrder.standard.with(mode: .alphabetical).arrangeItems(
            named, name: { $0 }, lastUsed: { _ in 1 }, useScore: { _ in 1 }
        )
        #expect(alphabetical.lead.isEmpty && alphabetical.heading == nil)
        #expect(alphabetical.rest == ["alpha", "Beta", "item 2", "Item 10"], "got \(alphabetical.rest)")
    }
}


@Suite("Per-scope orders")
struct ScopeOrdersTests {

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "dev.stenglein.Heft.scope-orders-\(UUID().uuidString)"))
    }

    /// The setting from before there were more scopes is the notes' row.
    @Test("Each scope keeps its own order, and notes keep Quick Open's keys")
    func storage() throws {
        let defaults = try suite()
        QuickOpenOrder(lead: .frequent, count: 3).save(in: defaults)
        var orders = ScopeOrders.current(in: defaults)
        #expect(orders[.notes] == QuickOpenOrder(lead: .frequent, count: 3), "carried over")
        #expect(orders[.commands] == .standard)

        orders[.commands] = QuickOpenOrder(lead: .frequent, count: 0)
        orders.save(in: defaults)
        let read = ScopeOrders.current(in: defaults)
        #expect(read[.commands].mode == .recentOnly)
        #expect(read[.notes] == QuickOpenOrder(lead: .frequent, count: 3))
        #expect(read[.tags] == .standard)
        #expect(QuickOpenOrder.current(in: defaults) == read[.notes], "the same keys")

        // A plain sort is stored beside the block, and cleared with it.
        var sorted = read
        sorted[.folder] = QuickOpenOrder.standard.with(mode: .alphabetical)
        sorted[.notes] = read[.notes].with(mode: .lastEdited)
        sorted.save(in: defaults)
        let again = ScopeOrders.current(in: defaults)
        #expect(again[.folder].mode == .alphabetical)
        #expect(again[.tag] == .standard, "a folder's row is not a tag's")
        #expect(QuickOpenOrder.current(in: defaults).mode == .lastEdited)
        again[.notes].with(mode: .frequentFirst).save(in: defaults)
        #expect(QuickOpenOrder.current(in: defaults) == QuickOpenOrder(lead: .frequent, count: 3))
    }
}


@Suite("Pins")
struct PinsTests {

    @Test("Pinned in the order pinned, once; pinning again unpins")
    func toggle() {
        var pins = Pins()
        let first = pins.toggle(.init(.note, "a.md"))
        let second = pins.toggle(.init(.tag, "work"))
        let again = pins.toggle(.init(.note, "a.md"))
        #expect(first && second)
        #expect(!again, "the second toggle unpins")
        pins.toggle(.init(.note, "a.md"))
        #expect(pins.items == [.init(.tag, "work"), .init(.note, "a.md")], "back at the end")
        #expect(Pins([.init(.note, "x"), .init(.note, "x")]).items.count == 1)
    }

    @Test("A moved folder carries the pins of what is in it")
    func moves() {
        var pins = Pins([.init(.note, "Work/Plan.md"), .init(.folder, "Work"), .init(.note, "Workshop.md")])
        pins.move(.folder, from: "Work", to: "Jobs")
        #expect(pins.items == [.init(.note, "Jobs/Plan.md"), .init(.folder, "Jobs"), .init(.note, "Workshop.md")])
        pins.move(.note, from: "Workshop.md", to: "Shop.md")
        #expect(pins.items.last == .init(.note, "Shop.md"))
    }

    @Test("Stored in the vault and read back; an unknown kind is dropped alone")
    func storage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Pins.load(from: root).items.isEmpty, "no file yet")
        let pins = Pins([.init(.command, "newNote"), .init(.folder, "Work")])
        try pins.save(to: root)
        #expect(Pins.load(from: root) == pins)
        #expect(Pins.url(in: root).path.hasSuffix(".heft/pins.json"))

        let json = #"{"pins":[{"kind":"note","value":"a.md"},{"kind":"heading","value":"x"}]}"#
        try Data(json.utf8).write(to: Pins.url(in: root))
        #expect(Pins.load(from: root).items == [.init(.note, "a.md")])
    }
}
