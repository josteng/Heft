import Foundation
import HeftCore
import Testing
@testable import Heft

/// The sidebar's right-click verbs, reachable without finding the row first.
/// Each acts on the note in front, which is what a palette opened over the
/// editor can mean by "this note".
@MainActor
@Suite("Palette note actions", .serialized)
struct PaletteNoteActionTests {

    private func vaultRoot(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-palette-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    /// The scan runs detached, so a model is not usable the instant it is
    /// built. Polled rather than slept through, which is what keeps this
    /// reliable while the rest of the suite runs in parallel.
    private func ready(_ model: AppModel) async throws -> AppModel {
        for _ in 0..<600 where model.tree == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tree != nil, "the vault never finished scanning")
        return model
    }

    private func command(_ id: String) throws -> AppCommand {
        try #require(AppCommand.registry.first { $0.id == id }, "no command \(id)")
    }

    @Test("Copy Path puts the vault-relative path on the pasteboard")
    func copiesRelativePath() async throws {
        let root = try vaultRoot(["Folder/Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Folder/Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }

        try command("copyNotePath").perform(on: model)
        #expect(host.copied == ["Folder/Note.md"])
    }

    @Test("Copy Absolute Path puts the whole path on the pasteboard")
    func copiesAbsolutePath() async throws {
        let root = try vaultRoot(["Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }

        try command("copyNoteAbsolutePath").perform(on: model)
        // The form a terminal or an agent can be handed, which is the whole
        // reason this one exists.
        let copied = try #require(host.copied.first)
        #expect(copied.hasPrefix("/"))
        #expect(copied.hasSuffix("/Note.md"))
        #expect(copied != "Note.md")
    }

    @Test("Copy Wikilink brackets the name and drops the extension")
    func copiesWikilink() async throws {
        let root = try vaultRoot(["Folder/Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Folder/Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }

        try command("copyNoteWikilink").perform(on: model)
        #expect(host.copied == ["[[Note]]"])
    }

    @Test("Reveal in Finder shows the open note's own file")
    func revealsTheNote() async throws {
        let root = try vaultRoot(["Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }

        try command("revealNoteInFinder").perform(on: model)
        #expect(host.revealed.map { $0.lastPathComponent } == ["Note.md"])
    }

    @Test("Duplicate leaves a copy beside the note")
    func duplicatesTheNote() async throws {
        let root = try vaultRoot(["Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }
        try #require(model.currentItem != nil, "the tree has no entry for the open note")

        try command("duplicateNote").perform(on: model)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Note copy.md").path
        ))
    }

    @Test("Move to… asks for a folder and moves the note into it")
    func movesTheNote() async throws {
        let root = try vaultRoot(["Note.md": "Body\n", "Folder/Keep.md": "x\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.folders = [root.appendingPathComponent("Folder", isDirectory: true)]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }
        try #require(model.currentItem != nil)

        try command("moveNote").perform(on: model)
        #expect(host.asked.contains { $0.hasPrefix("folder:") })
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Folder/Note.md").path
        ))
    }

    @Test("Move to Trash asks before it trashes")
    func trashAsksFirst() async throws {
        let root = try vaultRoot(["Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [false]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }
        try #require(model.currentItem != nil)

        try command("trashNote").perform(on: model)
        #expect(host.asked.contains { $0.hasPrefix("confirm:") })
        // Said no, so the file is still there. A palette must not be a
        // faster way to lose a note than the menu is.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Note.md").path))
    }

    @Test("Nothing open means none of them are offered")
    func disabledWithNoNote() async throws {
        let root = try vaultRoot(["Note.md": "Body\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: ScriptedHost()
        ))
        defer { model.closeWorkspace() }
        try #require(model.current == nil, "this vault opened a note by itself")

        for id in [
            "copyNotePath", "copyNoteAbsolutePath", "copyNoteWikilink", "copyNoteFile",
            "revealNoteInFinder", "renameNote", "duplicateNote", "moveNote", "trashNote",
        ] {
            #expect(try !command(id).isEnabled(on: model), Comment(rawValue: id))
        }
    }

    @Test("Opening an attachment leaves the note these verbs describe in front")
    func attachmentDoesNotBecomeTheNote() async throws {
        // Why none of these guard on `isMarkdown`: a PDF is handed to its
        // default app rather than opened, so the note in front stays the
        // note, and a palette command run afterwards still means that note
        // rather than the file that was just clicked.
        let root = try vaultRoot(["Note.md": "Body\n", "Scan.pdf": "%PDF-1.4\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md"),
            host: host
        ))
        defer { model.closeWorkspace() }

        let attachment = try #require(
            model.tree?.flattened().first { $0.relativePath == "Scan.pdf" }
        )
        model.open(item: attachment)
        #expect(host.opened.map { $0.lastPathComponent } == ["Scan.pdf"])
        #expect(model.current?.relativePath == "Note.md")

        try command("copyNoteWikilink").perform(on: model)
        #expect(host.copied == ["[[Note]]"])
    }

    @Test("Every verb on the note menu has a palette command")
    func menuAndPaletteAgree() throws {
        // The list is the point. A verb added to the row menu and forgotten
        // here is exactly the gap this suite exists to close.
        let expected = [
            "Copy Path": "copyNotePath",
            "Copy Absolute Path": "copyNoteAbsolutePath",
            "Copy Wikilink": "copyNoteWikilink",
            "Reveal in Finder": "revealNoteInFinder",
            "Rename": "renameNote",
            "Duplicate": "duplicateNote",
            "Move to…": "moveNote",
            "Move to Trash": "trashNote",
        ]
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        for (menuTitle, id) in expected {
            #expect(
                source.contains("MenuButton(\"\(menuTitle)\""),
                Comment(rawValue: "the note menu no longer offers \(menuTitle)")
            )
            #expect(
                AppCommand.registry.contains { $0.id == id },
                Comment(rawValue: "no palette command for \(menuTitle)")
            )
        }
    }
}
