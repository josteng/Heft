import Combine
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
    /// The pasteboard, as far as the model can tell: what `copyFiles` put
    /// there is what `filesOnPasteboard` hands back, and a test can preload
    /// it to stand in for a copy made in the Finder.
    var pasteboardFiles: [URL] = []

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
    func copyFiles(_ urls: [URL]) { pasteboardFiles = urls }
    func filesOnPasteboard() -> [URL] { pasteboardFiles }
}

/// The temporary folder is reached through a symlink, so a URL the tree
/// scanned and one a test built by hand differ in spelling, not in file.
private extension URL {
    var resolved: String { resolvingSymlinksInPath().path }
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
        let focusRequests = model.editorFocusRequest
        #expect(model.rename(untitled, to: "Kickoff", thenOpen: true))

        // Opened at the path the plan produced, not one rebuilt from the name.
        #expect(model.current?.relativePath == "Kickoff.md")
        #expect(model.editorFocusRequest == focusRequests + 1, "the caret goes to the new note")
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
        let focusRequests = model.editorFocusRequest
        #expect(model.rename(untitled, to: untitled.name, thenOpen: true))
        #expect(model.current?.relativePath == created.path)
        #expect(model.editorFocusRequest == focusRequests + 1, "the caret goes to the new note")
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
    /// A drop moves what is in the vault. What comes from outside is copied
    /// in and left where it was: taking it out of the reader's Downloads is
    /// not what dropping it on a note list should mean.
    @Test("A drop from outside the vault is copied in, and stays where it was")
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
        #expect(model.status == "Copied 1 item in to the vault root")
        #expect(try String(contentsOf: root.appendingPathComponent("Stray.md"), encoding: .utf8) == "elsewhere\n")
        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("Stray.md").path
        ))
    }

    @Test("A drop mixing a vault note and an outside file moves one and copies the other")
    func moveAndCopyInOneDrop() async throws {
        let root = try vault(["Note.md": "n\n", "Archive/.keep": ""])
        let outside = try vault(["Stray.md": "elsewhere\n"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let model = try await ready(model(root, ScriptedHost()))

        model.move(
            [root.appendingPathComponent("Note.md"), outside.appendingPathComponent("Stray.md")],
            into: root.appendingPathComponent("Archive")
        )
        #expect(model.status == "Moved 1 item, Copied 1 item in to Archive")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/Note.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/Stray.md").path))
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

    // MARK: - Copying and pasting files

    /// The pasteboard holds a reference, and the copy is made at paste
    /// time, so what was typed a moment ago has to be on disk by then.
    @Test("Copying the open note saves it first and puts the file on the pasteboard")
    func copyPutsTheFileOnThePasteboard() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Note.md"))
        model.text = "# Note\ntyped\n"
        try #require(model.isDirty)

        model.copy(try item(model, "Note.md"))
        #expect(host.pasteboardFiles.map(\.resolved) == [root.appendingPathComponent("Note.md").resolved])
        #expect(!model.isDirty)
        #expect(try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
            == "# Note\ntyped\n")
        #expect(model.status == "Copied Note")
    }

    @Test("⌘C with nothing selected copies the note that is open")
    func copyCurrentNote() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Index.md"))

        #expect(model.copyCurrentNote())
        #expect(host.pasteboardFiles.map(\.resolved) == [root.appendingPathComponent("Index.md").resolved])

        let empty = try await ready(self.model(root, ScriptedHost()))
        #expect(!empty.copyCurrentNote())
    }

    @Test("A pasted note lands in the folder under its own name, and is opened")
    func pasteIntoFolder() async throws {
        let root = try vault(["Note.md": "# Note\n", "Archive/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("Note.md")]
        let model = try await ready(model(root, host))

        #expect(model.canPaste)
        model.paste(into: root.appendingPathComponent("Archive"))
        #expect(try String(contentsOf: root.appendingPathComponent("Archive/Note.md"), encoding: .utf8)
            == "# Note\n")
        // The original is a copy's source, not a move's.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
        #expect(model.current?.relativePath == "Archive/Note.md")
        #expect(model.status == "Pasted Note.md into Archive")
    }

    @Test("Pasting beside the original makes a copy, and a second one counts up")
    func pasteBesideItself() async throws {
        let root = try vault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("Note.md")]
        let model = try await ready(model(root, host))

        model.paste(into: root)
        model.paste(into: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note copy.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note copy 1.md").path))
        #expect(model.status == "Pasted Note copy 1.md into the vault root")
    }

    /// The opposite of the drop rule, on purpose: a drop moves, and moving
    /// a file out of the reader's Downloads is not what a drop should mean.
    /// A paste copies, so the file stays where it was as well.
    @Test("A file copied in the Finder pastes into the vault, and stays where it was")
    func pasteFromOutside() async throws {
        let root = try vault()
        let outside = try vault(["Stray.md": "stray\n"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let host = ScriptedHost()
        host.pasteboardFiles = [outside.appendingPathComponent("Stray.md")]
        let model = try await ready(model(root, host))

        model.paste(into: root)
        #expect(try String(contentsOf: root.appendingPathComponent("Stray.md"), encoding: .utf8) == "stray\n")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Stray.md").path))
    }

    @Test("Several files paste in one go, and none of them is opened")
    func pasteSeveral() async throws {
        let root = try vault(["A.md": "a\n", "B.md": "b\n", "Archive/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("A.md"), root.appendingPathComponent("B.md")]
        let model = try await ready(model(root, host))

        model.paste(into: root.appendingPathComponent("Archive"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/B.md").path))
        #expect(model.current == nil)
        #expect(model.status == "Pasted 2 items into Archive")
    }

    @Test("With nothing on the pasteboard, paste says so and changes nothing")
    func pasteNothing() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        #expect(!model.canPaste)
        model.paste(into: root)
        #expect(model.status == "Nothing on the pasteboard to paste")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Index.md", "Note.md"])
    }

    @Test("Duplicating a note puts a copy beside it and opens the copy")
    func duplicateNote() async throws {
        let root = try vault(["Ideas/Plan.md": "p\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        model.duplicate(try item(model, "Ideas/Plan.md"))
        #expect(try String(contentsOf: root.appendingPathComponent("Ideas/Plan copy.md"), encoding: .utf8) == "p\n")
        #expect(try String(contentsOf: root.appendingPathComponent("Ideas/Plan.md"), encoding: .utf8) == "p\n")
        #expect(model.status == "Duplicated to Plan copy.md")
        // The copy is what the reader is left in front of.
        #expect(model.current?.relativePath == "Ideas/Plan copy.md")
    }

    @Test("A folder duplicates whole, beside itself")
    func duplicateFolder() async throws {
        let root = try vault(["Projects/A.md": "a\n", "Projects/Sub/B.md": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        model.duplicate(try item(model, "Projects"))
        #expect(try String(contentsOf: root.appendingPathComponent("Projects copy/Sub/B.md"), encoding: .utf8) == "b\n")
        #expect(model.status == "Duplicated to Projects copy")
        // A folder is not a note: nothing was opened.
        #expect(model.current == nil)
    }

    /// ⌘C on a folder, then ⌘V with that folder still selected. The Finder
    /// answers with a copy beside it, and so does this.
    @Test("A folder pasted onto itself lands beside it as a copy")
    func pasteFolderOntoItself() async throws {
        let root = try vault(["Yearly/2026.md": "y\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("Yearly")]
        let model = try await ready(model(root, host))

        model.paste(into: root.appendingPathComponent("Yearly"))
        #expect(try String(contentsOf: root.appendingPathComponent("Yearly copy/2026.md"), encoding: .utf8) == "y\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Yearly/Yearly").path))
        #expect(model.status == "Pasted Yearly copy into the vault root")
    }

    @Test("The keys go to the row the sidebar clicked last, and to the text otherwise")
    func keyboardFollowsTheSidebarsLastClick() async throws {
        let root = try vault(["Note.md": "n\n", "Archive/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Note.md"))
        let archive = root.appendingPathComponent("Archive")

        // Nothing clicked in the sidebar: both keys are the text's own.
        #expect(!model.copyFromKeyboard())
        #expect(!model.pasteFromKeyboard())

        model.sidebarKeyboardTarget = archive
        #expect(model.copyFromKeyboard())
        #expect(host.pasteboardFiles == [archive])
        #expect(model.pasteFromKeyboard())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive copy").path))

        // Blank space is the root: a place to paste into, not a thing to copy.
        model.sidebarKeyboardTarget = root
        host.pasteboardFiles = [root.appendingPathComponent("Note.md")]
        #expect(!model.copyFromKeyboard())
        #expect(model.pasteFromKeyboard())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note copy.md").path))

        // A folder that has gone since it was clicked is nobody's target.
        model.sidebarKeyboardTarget = root.appendingPathComponent("Gone")
        #expect(!model.pasteFromKeyboard())
    }

    /// What ⌘C then ⌘V means with a file clicked in the tree: the copy lands
    /// beside it, which is the Finder's duplicate. It used to go to the text
    /// view instead, which wrote a link into whatever note was open.
    /// ⌘⌫ on a row, the way the Finder trashes a selected file. It asks
    /// first, as every other route to the Trash does.
    @Test("The delete key trashes the row the sidebar clicked last")
    func deleteFromTheKeyboard() async throws {
        let root = try vault(["Ideas/Plan.md": "p\n", "Index.md": "\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(model(root, host, open: "Index.md"))

        // Nothing clicked in the tree: the key is the text's own.
        #expect(!model.deleteFromKeyboard())
        #expect(host.asked.isEmpty)

        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas/Plan.md")
        #expect(model.deleteFromKeyboard())
        #expect(host.asked == ["confirm: Delete Plan?"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Plan.md").path))
        // The row is gone, so it is nothing for the next key to act on.
        #expect(model.sidebarKeyboardTarget == nil)

        // A folder clicked in the tree is a row like any other. Its URL is
        // built as a directory, which is a different spelling of the same
        // path, and the lookup has to survive that.
        host.confirmations = [true]
        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas", isDirectory: true)
        #expect(model.deleteFromKeyboard())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas").path))
    }

    /// What enables File ▸ Move to Trash, and so whether ⌘⌫ is a menu
    /// command at all: while it is off, the key belongs to the text, where
    /// it deletes to the start of the line.
    @Test("The delete key is the tree's only while a row there is clicked")
    func deleteKeyIsOfferedOnlyForARow() async throws {
        let root = try vault(["Ideas/Plan.md": "p\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost(), open: "Index.md"))

        #expect(!model.canDeleteFromSidebar)
        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas", isDirectory: true)
        #expect(model.canDeleteFromSidebar)
        // Blank space stands for the vault root, which is not a row.
        model.sidebarKeyboardTarget = root
        #expect(!model.canDeleteFromSidebar)

        // Typing hands the key back, and does it without waking the window
        // on every keystroke.
        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas", isDirectory: true)
        model.releaseSidebarKeys()
        #expect(!model.canDeleteFromSidebar)
    }

    /// The menu item's enabled state is settled when the menu is built, not
    /// asked for when the key is pressed, so the thing it is built from has
    /// to say when it changes. Without this the item kept whatever state it
    /// had when the window last drew, and ⌘⌫ worked only sometimes.
    @Test("A row clicked in the tree tells the menu bar it changed")
    func rowChangeReachesTheMenu() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))

        var announcements = 0
        let subscription = model.sidebarKeys.objectWillChange.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        model.sidebarKeyboardTarget = root.appendingPathComponent("Note.md")
        #expect(announcements == 1)
        #expect(model.sidebarKeys.url == root.appendingPathComponent("Note.md"))

        model.releaseSidebarKeys()
        #expect(announcements == 2)

        // Already handed back: nothing changed, so the menu is left alone.
        model.releaseSidebarKeys()
        #expect(announcements == 2)
    }

    @Test("Saying no to the question keeps the file, and blank space is never deleted")
    func deleteFromTheKeyboardRefuses() async throws {
        let root = try vault(["Ideas/Plan.md": "p\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [false]
        let model = try await ready(model(root, host))

        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas/Plan.md")
        #expect(model.deleteFromKeyboard())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Plan.md").path))

        // Blank space stands for the vault root, which no keystroke deletes.
        model.sidebarKeyboardTarget = root
        #expect(!model.deleteFromKeyboard())
        #expect(host.asked == ["confirm: Delete Plan?"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas").path))
    }

    @Test("Copy and paste on a file row is the duplicate it is in the Finder")
    func keyboardDuplicatesAFile() async throws {
        let root = try vault(["Ideas/Plan.md": "p\n", "Index.md": "\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host, open: "Index.md"))

        model.sidebarKeyboardTarget = root.appendingPathComponent("Ideas/Plan.md")
        #expect(model.copyFromKeyboard())
        #expect(model.pasteFromKeyboard())
        // Beside the original, not inside it and not in the vault root.
        #expect(try String(contentsOf: root.appendingPathComponent("Ideas/Plan copy.md"), encoding: .utf8) == "p\n")
        // And nothing was written into the note that happened to be open.
        #expect(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8) == "\n")

        // A different file pasted with that same row clicked goes beside it,
        // into its folder. The row is not a folder and cannot be pasted into.
        host.pasteboardFiles = [root.appendingPathComponent("Index.md")]
        #expect(model.pasteFromKeyboard())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Index.md").path))
    }

    /// Text on the pasteboard belongs to the text view even when the tree was
    /// the last thing clicked, or copying a paragraph and pressing ⌘V would
    /// answer that there is nothing to paste.
    @Test("With no files on the pasteboard the keys fall through to the text")
    func textPasteIsNotTakenFromTheEditor() async throws {
        let root = try vault(["Archive/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(model(root, host))

        model.sidebarKeyboardTarget = root.appendingPathComponent("Archive")
        model.status = ""
        #expect(!model.pasteFromKeyboard())
        // Not even a complaint about an empty pasteboard: the key was never
        // taken, so the text view has it.
        #expect(model.status.isEmpty)
    }

    /// A vault of any size orders the tree by name, so a PDF dropped in lands
    /// somewhere down a folder that may not even be open.
    @Test("A file copied in is scrolled to and lit, even though it is no note")
    func copiedFileIsRevealed() async throws {
        let root = try vault(["Papers/.keep": "", "Index.md": "\n"])
        let outside = try vault(["Report.pdf": "%PDF-1.4\n"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let host = ScriptedHost()
        host.pasteboardFiles = [outside.appendingPathComponent("Report.pdf")]
        let model = try await ready(model(root, host, open: "Index.md"))

        model.paste(into: root.appendingPathComponent("Papers"))
        #expect(model.revealTarget == "Papers/Report.pdf")
        #expect(model.highlightedPath == "Papers/Report.pdf")
        // The folder above it is opened, or there is nothing to scroll to.
        #expect(model.expandedFolders.contains("Papers"))
        // A PDF is not opened in the editor; the note stays put.
        #expect(model.current?.relativePath == "Index.md")

        // Opening a note takes the light back, so only one row is lit.
        model.open(item: try item(model, "Index.md"))
        #expect(model.highlightedPath == nil)
    }

    /// A light that stayed would be read as the selection, and a PDF is never
    /// selected the way a note is. It marks what arrived, then goes out.
    @Test("The light on a revealed row goes out by itself")
    func revealLightGoesOut() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, ScriptedHost()))
        model.highlightDuration = .milliseconds(60)

        model.reveal("Note.md")
        #expect(model.highlightedPath == "Note.md")
        // Waited for rather than slept through: the whole suite runs in
        // parallel, and a fixed wait fails on a busy machine instead of on
        // a light that stayed on.
        for _ in 0..<600 where model.highlightedPath != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.highlightedPath == nil)
    }

    @Test("A folder pasted inside itself is refused rather than copied without end")
    func pasteFolderIntoItself() async throws {
        let root = try vault(["Projects/A.md": "a\n", "Projects/Sub/.keep": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.pasteboardFiles = [root.appendingPathComponent("Projects")]
        let model = try await ready(model(root, host))

        model.paste(into: root.appendingPathComponent("Projects/Sub"))
        #expect(model.status == "Cannot copy Projects inside itself")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Projects/Sub").path) == [".keep"])
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
