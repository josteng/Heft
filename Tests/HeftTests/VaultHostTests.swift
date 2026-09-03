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

    private func item(_ model: AppModel, _ path: String) throws -> VaultItem {
        try #require(
            model.tree?.flattened().first { $0.relativePath == path }, "no \(path) in the tree"
        )
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
