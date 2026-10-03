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
}

/// What each scope lists, from a real vault on disk.
@MainActor
@Suite("Search bar rows", .serialized)
struct SearchBarRowTests {

    private func model(_ files: [String: String], scope: String? = nil) async throws -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-bar-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
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

    /// The bar ⌘T opens: the last note opened, then what is used most. The
    /// scopes are chips above the list and cost it no rows.
    @Test("With nothing typed: recent, then frequent")
    func startRows() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b", "Gamma.md": "c"])
        defer { model.closeWorkspace() }
        let session = try #require(model.session)
        for _ in 0..<5 { session.recordRecent("Alpha.md") }
        session.recordRecent("Gamma.md")

        let rows = ids(model.barRows(
            scope: nil, query: "", entireVault: true, order: .init(lead: .recent, count: 1)
        ))
        #expect(Array(rows.prefix(4)) == [
            "heading:Recent", "note:Gamma.md", "heading:Frequent", "note:Alpha.md",
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

    /// No note opened yet must not mean a list without notes. Commands may
    /// already be frequent, since that store is app-wide.
    @Test("A vault with no history still lists its notes")
    func noHistory() async throws {
        let model = try await model(["Alpha.md": "a", "Beta.md": "b"])
        defer { model.closeWorkspace() }
        let rows = model.barRows(scope: nil, query: "", entireVault: true)
        #expect(Array(ids(rows).suffix(3)) == ["heading:Notes", "note:Alpha.md", "note:Beta.md"])
        #expect(rows.first { $0.id == "heading:Notes" }?.scope == .notes)
    }

    /// Frequent mixes both kinds on one scale.
    @Test("A command used often sits among the frequent notes")
    func frequentMixesCommands() async throws {
        let model = try await model(["Alpha.md": "a"])
        defer { model.closeWorkspace() }
        for _ in 0..<40 { FrecencyStore.commands.record("toggleSidebar") }
        let rows = ids(model.barRows(
            scope: nil, query: "", entireVault: true, order: .init(lead: .recent, count: 0)
        ))
        #expect(rows.contains("command:toggleSidebar"), "got \(rows)")
    }

    /// "rec" offers Recent as a row, ranked with everything else, so Space or
    /// Tab can make it the chip; tags are found by name without the hash.
    @Test("Scopes and tags are found by name")
    func scopesByName() async throws {
        let model = try await model(["Plan.md": "#work", "Diary.md": "x"])
        defer { model.closeWorkspace() }
        #expect(ids(model.barRows(scope: nil, query: "rec", entireVault: true)).first == "scope:Recent")
        #expect(ids(model.barRows(scope: nil, query: "tags", entireVault: true)).first == "scope:Tags")
        #expect(ids(model.barRows(scope: nil, query: "most used", entireVault: true))
            .contains("scope:Frequent"), "a synonym finds it too")
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
        let rows = ids(model.barRows(
            scope: nil, query: "", entireVault: true, order: .init(lead: .recent, count: 0)
        ))
        #expect(rows.contains("scope:Tags"), "got \(rows)")
        #expect(rows.contains("tag:home"), "got \(rows)")
    }

    /// Typed with no scope: one ranking across notes and commands, and the
    /// text search offered last rather than mixed in.
    @Test("Typed: notes and commands ranked together, text search last")
    func everything() async throws {
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
        #expect(rows.last == "searchText")
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
        #expect(rows.first?.scope == .recent, "the heading is a way into its scope")

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
        #expect(tags.first?.scope == .tag("work") || tags.first?.scope == .tag("home"))

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
        var files = ["Zebra notes.md": "zebra"]
        for i in 0..<12 { files["Day \(i).md"] = "saw a zebra today" }
        let model = try await model(files)
        defer { model.closeWorkspace() }
        let text = ContentSearch.run(notes: model.index.notes, query: "zebra")
        let rows = model.barRows(scope: nil, query: "zebra", entireVault: true, text: text)
        let rowIDs = ids(rows)
        let heading = try #require(rowIDs.firstIndex(of: "heading:Text"), "got \(rowIDs)")
        #expect(rows[heading].scope == .contents, "the heading leads into the text scope")
        #expect(rowIDs.firstIndex(of: "note:Zebra notes.md")! < heading, "names first")
        #expect(rowIDs.filter { $0.hasPrefix("hit:") }.count == AppModel.barTextPreview)
        guard case .searchText(_, let matches) = try #require(rows.last) else {
            Issue.record("the last row leads to the text scope"); return
        }
        #expect(matches == 13)
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
        #expect(!BarRow.heading("Search In", target: nil).isSelectable)
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
