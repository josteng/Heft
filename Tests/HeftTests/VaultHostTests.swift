import Foundation
import HeftCore
import Testing
@testable import Heft

/// A `VaultHost` that answers from a script and records what it was asked.
///
/// The point of the protocol. Before it, every one of the operations below
/// stopped at `runModal` — a modal panel has no answer to give a test, and it
/// blocks the thread waiting for one — so a rename that collided, a delete
/// that was cancelled and a drop from outside the vault could only be checked
/// by reading the code.
@MainActor
final class ScriptedHost: VaultHost {

    /// What was asked, in order, as `"kind: title"`. Reading these back is
    /// how a test says "and it did not ask" — the commonest bug in this area
    /// is a guard that runs *after* the prompt, so the reader is asked about
    /// something that was never going to happen.
    private(set) var asked: [String] = []

    var names: [String] = []
    var paths: [String] = []
    var confirmations: [Bool] = []
    var folders: [URL] = []
    var exportDestinations: [URL] = []
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    private(set) var copied: [String] = []

    func name(title: String, message: String, initial: String, confirm: String) -> String? {
        asked.append("name: \(title)")
        return names.isEmpty ? nil : names.removeFirst()
    }

    func path(title: String, message: String) -> String? {
        asked.append("path: \(title)")
        return paths.isEmpty ? nil : paths.removeFirst()
    }

    func confirm(title: String, message: String, confirm: String, destructive: Bool) -> Bool {
        asked.append("confirm: \(title)")
        return confirmations.isEmpty ? false : confirmations.removeFirst()
    }

    func chooseFolder(prompt: String, message: String, startingAt: URL?) -> URL? {
        asked.append("folder: \(prompt)")
        return folders.isEmpty ? nil : folders.removeFirst()
    }

    func exportDestination(suggestedName: String, startingAt: URL?) -> URL? {
        asked.append("export: \(suggestedName)")
        return exportDestinations.isEmpty ? nil : exportDestinations.removeFirst()
    }

    func openExternally(_ url: URL) { opened.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
    func copyToPasteboard(_ string: String) { copied.append(string) }
}

@Suite("Vault operations through a window")
@MainActor
struct VaultHostTests {

    private func vault(
        _ files: [String: String] = ["Index.md": "See [[Note]]\n", "Note.md": "# Note\n"]
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-host-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func model(_ root: URL, _ host: ScriptedHost, open: String? = nil) -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: open),
            host: host
        )
    }

    /// The vault scan runs in a detached task, so a model is not usable the
    /// instant it is built. Everything below waits for it rather than
    /// sleeping a fixed amount, which is what makes these reliable under the
    /// parallel Neovim subprocesses the rest of the suite runs.
    private func ready(_ model: AppModel) async throws -> AppModel {
        for _ in 0..<600 where model.tree == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tree != nil, "the vault never finished scanning")
        return model
    }

    /// The rescan after a note is created runs detached, so a file on disk is
    /// not yet a row in the tree.
    private func item(
        _ model: AppModel, awaiting path: String
    ) async throws -> VaultItem {
        for _ in 0..<600 where model.tree?.flattened().contains(
            where: { $0.relativePath == path }
        ) != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try item(model, path)
    }

    private func item(_ model: AppModel, _ path: String) throws -> VaultItem {
        try #require(
            model.tree?.flattened().first { $0.relativePath == path }, "no \(path) in the tree"
        )
    }

    // MARK: - The context rendered surfaces are drawn with

    @Test("Every rendered surface is drawn with the vault's own line-break rule")
    func renderContextCarriesTheVaultsLineBreaks() async throws {
        // The bug this covers: `PresentationView` built its own context and
        // never passed this field. It has a default, so nothing complained,
        // and Presentation is the only surface that reads it, so nothing
        // anywhere honoured the vault.
        let strict = try vault([
            "Note.md": "# Note\n",
            ".obsidian/app.json": #"{"strictLineBreaks": true}"#,
        ])
        defer { try? FileManager.default.removeItem(at: strict) }
        let strictModel = try await ready(model(strict, ScriptedHost()))
        #expect(strictModel.settings.strictLineBreaks)
        #expect(strictModel.renderContext().strictLineBreaks)
        // Export goes through the same builder, colours aside.
        #expect(strictModel.renderContext(ink: { _ in .black }).strictLineBreaks)

        // A vault that says nothing gets Obsidian's default, a line each.
        let plain = try vault()
        defer { try? FileManager.default.removeItem(at: plain) }
        let plainModel = try await ready(model(plain, ScriptedHost()))
        #expect(!plainModel.renderContext().strictLineBreaks)
    }

    @Test("Three source lines render as one paragraph, or as three")
    func lineBreakSettingChangesWhatIsDrawn() throws {
        // The end of the chain, not the setting end: what Presentation
        // actually draws for three lines with no blank line between them.
        let note = "asfasdfasdf\nasfdasdfasdfasdf\nasdfasdfasdf\n"
        let blocks = MarkdownModel.parse(note).blocks
        let paragraph = try #require(blocks.compactMap { block -> [MDInline]? in
            if case let .paragraph(inlines) = block { return inlines }
            return nil
        }.first)

        func drawn(strict: Bool) -> String {
            var context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
            context.strictLineBreaks = strict
            return InlineText.pieces(paragraph, context: context)
                .compactMap { piece -> String? in
                    guard case let .text(runs) = piece else { return nil }
                    return runs.map { run -> String in
                        guard case let .styled(text) = run else { return "" }
                        return String(text.characters)
                    }.joined()
                }
                .joined()
        }

        // Obsidian's default, and what the editor always shows.
        #expect(drawn(strict: false).contains("\n"))
        #expect(drawn(strict: false).split(separator: "\n").count == 3)

        // One paragraph: the newlines become spaces.
        #expect(!drawn(strict: true).contains("\n"))
        #expect(drawn(strict: true) == "asfasdfasdf asfdasdfasdfasdf asdfasdfasdf")
    }

    // MARK: - Opening a note leaves the tree alone

    @Test("Opening a note does not unfold the sidebar around it")
    func openingDoesNotExpandFolders() async throws {
        let root = try vault([
            "Daily Notes/2026-09-04.md": "# Today\n",
            "Note.md": "# Note\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost(), open: "Note.md"))
        #expect(model.expandedFolders.isEmpty)

        // What clicking a date in the calendar does.
        model.open(item: try await item(model, awaiting: "Daily Notes/2026-09-04.md"))
        #expect(model.current?.relativePath == "Daily Notes/2026-09-04.md")

        // The folder stays folded. It used to unfold on every open, which is
        // a year of dailies appearing under a date click, and only half a
        // reveal: nothing scrolled, so the note was in there somewhere.
        #expect(model.expandedFolders.isEmpty, "got \(model.expandedFolders)")
        #expect(model.revealTarget == nil)
    }

    @Test("Reveal in Sidebar is the one that unfolds, and scrolls too")
    func revealUnfoldsAndScrolls() async throws {
        let root = try vault(["Projects/Deep/Thing.md": "# Thing\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost(), open: "Projects/Deep/Thing.md"))

        model.revealCurrentInSidebar()
        // Every ancestor, or a note three deep is revealed behind two closed
        // folders.
        #expect(model.expandedFolders.contains("Projects"))
        #expect(model.expandedFolders.contains("Projects/Deep"))
        #expect(model.revealTarget == "Projects/Deep/Thing.md")
    }

    // MARK: - Creating a note

    @Test("With a sidebar, ⌘N asks it to name the note in place rather than prompting")
    func newNoteNamesInTheSidebar() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))
        model.columnVisibility = .all

        model.createNote()

        // No modal. The sidebar draws a field in the row instead, which is
        // what the + button already did.
        #expect(host.asked.isEmpty, "asked: \(host.asked)")
        #expect(model.inlineNoteRequest != nil)
    }

    @Test("With the sidebar hidden there is nowhere to type, so it still prompts")
    func newNotePromptsWithoutASidebar() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Kickoff"]
        let model = try await ready(model(root, host))
        model.columnVisibility = .detailOnly

        model.createNote()

        #expect(host.asked == ["name: New Note"])
        #expect(model.inlineNoteRequest == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Kickoff.md").path
        ))
    }

    @Test("Two presses are two requests, not one the view already answered")
    func repeatedRequestsAreDistinct() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))
        model.columnVisibility = .all

        model.createNote()
        let first = try #require(model.inlineNoteRequest)
        model.inlineNoteRequest = nil        // what the sidebar does on seeing it
        model.createNote()

        #expect(model.inlineNoteRequest != first)
    }

    @Test("A note created only to be named is removed when the naming is abandoned")
    func abandonedUntitledNoteIsRemoved() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        let created = try #require(model.createUntitledNote(in: root))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(created.path).path
        ))

        model.discardUnnamedNote(at: created.path)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(created.path).path
        ))
    }

    @Test("A note being named is scrolled to, and not opened until it has a name")
    func namingHappensWhereItCanBeSeen() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))
        model.open(item: try item(model, "Note.md"))

        let created = try #require(model.createUntitledNote(in: root))

        // The sidebar is usually showing somewhere else, so a field appearing
        // off screen reads as nothing having happened.
        #expect(model.revealTarget == created.path)
        // Not opened: a caret in the editor beside the caret in the row is
        // two insertion points, one of which is the wrong place to type.
        #expect(model.current?.relativePath == "Note.md")
    }

    @Test("Naming a new note opens the note that was named")
    func namingOpensTheResult() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        let created = try #require(model.createUntitledNote(in: root))
        let untitled = try await item(model, awaiting: created.path)
        #expect(model.rename(untitled, to: "Kickoff", thenOpen: true))

        // Opened at the path the plan produced, not one rebuilt from the name.
        #expect(model.current?.relativePath == "Kickoff.md")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Kickoff.md").path
        ))
    }

    @Test("Keeping the offered name still opens the note")
    func keepingTheOfferedNameOpensIt() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        let created = try #require(model.createUntitledNote(in: root))
        let untitled = try await item(model, awaiting: created.path)
        // What Return on an unchanged name does: a rename to the same name,
        // which is not a failure and has nothing to move.
        #expect(model.rename(untitled, to: untitled.name, thenOpen: true))
        #expect(model.current?.relativePath == created.path)
    }

    @Test("Anything but an empty, still-unnamed note is left alone")
    func onlyTheUnnamedNoteIsDiscarded() async throws {
        let root = try vault([
            "Untitled.md": "typed something\n", "Note.md": "# Note\n", "Scratch.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        // Named by the reader: not this function's business, whatever else
        // is true of it.
        model.discardUnnamedNote(at: "Note.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))

        // The one that matters. An empty note the reader named looks exactly
        // like an abandoned one to every check except the name, and deleting
        // somebody's empty note is the worst thing this could do.
        model.discardUnnamedNote(at: "Scratch.md")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Scratch.md").path
        ))

        // Still called Untitled, but it has something in it.
        model.discardUnnamedNote(at: "Untitled.md")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Untitled.md").path
        ))
    }

    // MARK: - Accepting a group of deletes

    @Test("A group of deletes asks once, naming every file, and takes them all")
    func groupDeletesAskOnce() async throws {
        let root = try vault([
            "Keep.md": "kept\n", "Untitled 1.md": "", "Untitled 2.md": "", "Untitled 3.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let group = Proposal.Group(summary: "Clear the untitled notes")
        for index in 1...3 {
            try ProposalStore.write(
                Proposal(
                    id: "drop-untitled-\(index)", notePath: "Untitled \(index).md",
                    base: nil, body: "", agent: "t",
                    summary: "Delete Untitled \(index)", kind: .delete, group: group
                ),
                in: root
            )
        }

        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(model(root, host))
        model.refreshProposals()
        let waiting = try #require(model.pendingProposals.groups.first)
        #expect(waiting.proposals.count == 3)

        model.acceptGroup(waiting)

        // One question, not three. Three identical alerts in a row is how a
        // confirmation stops being read.
        #expect(host.asked == ["confirm: Delete 3 files?"])
        for index in 1...3 {
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Untitled \(index).md").path
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Keep.md").path
        ))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("Cancelling that one question leaves the whole group alone")
    func cancellingAGroupDeleteChangesNothing() async throws {
        let root = try vault(["A.md": "one\n", "Gone.md": "x\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let group = Proposal.Group(summary: "Tidy up")
        try ProposalStore.write(
            Proposal(
                id: "drop-gone", notePath: "Gone.md", base: nil, body: "", agent: "t",
                summary: "Delete Gone", kind: .delete, group: group
            ),
            in: root
        )
        try ProposalStore.write(
            Proposal(
                id: "edit-a", notePath: "A.md", base: "one\n", body: "two\n", agent: "t",
                summary: "Reword A", group: group
            ),
            in: root
        )

        let host = ScriptedHost()
        host.confirmations = [false]
        let model = try await ready(model(root, host))
        model.refreshProposals()
        model.acceptGroup(try #require(model.pendingProposals.groups.first))

        // Asked before anything was applied, so cancelling cancels the group
        // rather than leaving its edits in and its deletes out.
        #expect(host.asked == ["confirm: Delete Gone.md?"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone.md").path))
        #expect(try String(contentsOf: root.appendingPathComponent("A.md"), encoding: .utf8)
            == "one\n")
        #expect(ProposalStore.all(in: root).count == 2)
    }

    @Test("Applying a delete from its review sheet does not ask a second time")
    func reviewedDeleteDoesNotAskAgain() async throws {
        let root = try vault(["Keep.md": "kept\n", "Gone.md": "x\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        try ProposalStore.write(
            Proposal(
                id: "drop-gone", notePath: "Gone.md", base: nil, body: "", agent: "t",
                summary: "Delete Gone", kind: .delete
            ),
            in: root
        )

        let host = ScriptedHost()
        // Deliberately empty: `ScriptedHost` answers no when it runs out, so
        // an alert appearing here would refuse the delete and the file would
        // survive. The test cannot pass by accident.
        host.confirmations = []
        let model = try await ready(model(root, host))
        model.refreshProposals()
        let waiting = try #require(model.pendingProposals.structural.first)

        // What the sheet's button does. The sheet named the file and said
        // where it goes, so this press is the whole commitment.
        model.applyStructural(waiting, confirmed: true)

        #expect(host.asked.isEmpty, "asked: \(host.asked)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Keep.md").path))
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("Deleting one file from the sidebar still asks about that file")
    func singleDeleteStillAsks() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(model(root, host))

        model.delete(try item(model, "Note.md"))
        #expect(host.asked == ["confirm: Delete Note?"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    // MARK: - Renaming

    @Test("A rename moves the file and repoints what pointed at it")
    func renameRepoints() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Kickoff"]
        let model = try await ready(model(root, host))

        #expect(model.rename(try item(model, "Note.md")))
        #expect(host.asked == ["name: Rename Note"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Kickoff.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8)
            == "See [[Kickoff]]\n")
        #expect(model.status.contains("Renamed to Kickoff.md"))
        #expect(model.status.contains("repointed 1 link in 1 note"))
    }

    @Test("Cancelling the prompt changes nothing")
    func renameCancelled() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        #expect(!model.rename(try item(model, "Note.md")))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    @Test("A rename onto an existing note is refused and leaves both alone")
    func renameCollision() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Index"]
        let model = try await ready(model(root, host))

        #expect(!model.rename(try item(model, "Note.md")))
        #expect(model.status == "Index.md already exists")
        #expect(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8)
            == "See [[Note]]\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    /// Renaming through the sidebar's inline field passes the name directly.
    /// It must not put a modal panel up on top of the field the reader is
    /// already typing in.
    @Test("A name supplied directly is not asked for again")
    func renameWithoutPrompting() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        #expect(model.rename(try item(model, "Note.md"), to: "Renamed"))
        #expect(host.asked.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Renamed.md").path
        ))
    }

    // MARK: - Deleting

    @Test("Deleting asks first, and cancelling keeps the file")
    func deleteCancelled() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [false]
        let model = try await ready(model(root, host))

        model.delete(try item(model, "Note.md"))
        #expect(host.asked == ["confirm: Delete Note?"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    @Test("Confirming moves the file to the Trash")
    func deleteConfirmed() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(model(root, host))

        model.delete(try item(model, "Note.md"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(model.status.contains("Trash"))
    }

    // MARK: - Moving

    /// A link written as a path is repointed; a bare `[[Note]]` that still
    /// resolves after the move is left exactly as it was written. Both are
    /// asserted here because it is the pair that makes the rule visible.
    @Test("A drop into a folder moves the file and repoints only the path links")
    func moveIntoFolder() async throws {
        let root = try vault([
            "Index.md": "See [[Note]] and [[Note|aliased]]\n",
            "Deep.md": "Path link: [[Note.md]]\n",
            "Note.md": "# Note\n",
            "Archive/.keep": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        model.move(
            [root.appendingPathComponent("Note.md")],
            into: root.appendingPathComponent("Archive")
        )
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Archive/Note.md").path
        ))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(model.status.contains("Moved 1 item"))
        // Untouched: it addresses the note by name, and the name did not move.
        #expect(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8)
            == "See [[Note]] and [[Note|aliased]]\n")
    }

    /// A drop can carry anything Finder had on the pasteboard. Pulling a file
    /// in from elsewhere would take it out of wherever the reader keeps it.
    @Test("A drop from outside the vault is refused, not copied in")
    func moveFromOutside() async throws {
        let root = try vault()
        let outside = try vault(["Stray.md": "elsewhere\n"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        model.move([outside.appendingPathComponent("Stray.md")], into: root)
        #expect(model.status == "Stray.md is outside the vault")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Stray.md").path))
        // And it is still where its owner left it.
        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("Stray.md").path
        ))
    }

    @Test("A folder dropped inside itself is refused rather than deleted")
    func moveFolderIntoItself() async throws {
        let root = try vault(["Projects/A.md": "a\n", "Projects/Sub/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        model.move(
            [root.appendingPathComponent("Projects")],
            into: root.appendingPathComponent("Projects/Sub")
        )
        #expect(model.status == "Cannot move Projects inside itself")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Projects/A.md").path
        ))
    }

    @Test("Choosing a folder outside the vault to move into is refused")
    func promptToMoveOutside() async throws {
        let root = try vault()
        let outside = try vault([:])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let host = ScriptedHost()
        host.folders = [outside]
        let model = try await ready(model(root, host))

        model.promptToMove(try item(model, "Note.md"))
        #expect(host.asked == ["folder: Move"])
        #expect(model.status == "That folder is outside the vault")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    // MARK: - Creating

    @Test("Creating a note writes it and opens it")
    func createNote() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Fresh"]
        let model = try await ready(model(root, host))
        // The prompt is what a window with no sidebar uses; with one, the
        // name is typed into the row instead.
        model.columnVisibility = .detailOnly

        model.createNote()
        #expect(host.asked == ["name: New Note"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Fresh.md").path))
        #expect(model.current?.relativePath == "Fresh.md")
    }

    /// A `/` typed into a note title would otherwise make a folder level.
    @Test("A name a filesystem will not take is cleaned rather than refused")
    func createNoteWithSeparator() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.names = ["Q3/Q4 plan"]
        let model = try await ready(model(root, host))
        model.columnVisibility = .detailOnly

        model.createNote()
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Q3-Q4 plan.md").path
        ))
    }

    // MARK: - Handing files to the system

    /// Heft opens markdown itself. A PDF or an image is the system's
    /// business, and this is the one call in the model that would launch
    /// another application if it were not injected.
    @Test("A non-markdown file is handed to the system, not opened in the editor")
    func attachmentGoesToTheSystem() async throws {
        let root = try vault(["Index.md": "x\n", "shot.png": "PNG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Index.md"))

        model.open(item: try item(model, "shot.png"))
        #expect(host.opened.map(\.lastPathComponent) == ["shot.png"])
        // And the editor stayed where it was.
        #expect(model.current?.relativePath == "Index.md")
    }

    /// A second way in, and the reason `follow` no longer asks `isMarkdown`
    /// for itself: it resolves the link and calls `open`, which already hands
    /// anything that is not a note to the system. The duplicate test it used
    /// to make was found by mutating it and watching nothing fail.
    @Test("An embed followed from the text goes to the system too")
    func followedAttachmentGoesToTheSystem() async throws {
        let root = try vault(["Index.md": "![[shot.png]]\n", "shot.png": "PNG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Index.md"))

        model.follow(WikiLink(target: "shot.png", isEmbed: true))
        #expect(host.opened.map(\.lastPathComponent) == ["shot.png"])
        #expect(model.current?.relativePath == "Index.md")
    }
}
