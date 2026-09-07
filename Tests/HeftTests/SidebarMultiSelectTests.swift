import Foundation
import HeftCore
import Testing
@testable import Heft

/// Acting on several rows at once: what the selection resolves to, and what
/// the verbs do with it.
@MainActor
@Suite("Sidebar multi-select", .serialized)
struct SidebarMultiSelectTests {

    private func vaultRoot(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-multi-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func ready(_ model: AppModel) async throws -> AppModel {
        for _ in 0..<600 where model.tree == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tree != nil, "the vault never finished scanning")
        return model
    }

    private func waitForTree(_ model: AppModel, toContain path: String) async {
        for _ in 0..<600 {
            if model.tree?.flattened().contains(where: { $0.relativePath == path }) == true { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - What the selection resolves to

    @Test("A folder swallows its own children, so nothing is counted twice")
    func outermostDropsDescendants() {
        // Trashing the folder takes the notes with it. Asking the filesystem
        // for the child afterwards fails on a file that has already gone.
        let paths = ["Folder", "Folder/A.md", "Folder/Deep/B.md", "C.md"]
        #expect(SidebarSelection.outermost(paths) == ["C.md", "Folder"])
    }

    @Test("A folder does not swallow a sibling whose name it prefixes")
    func outermostRespectsNameBoundaries() {
        // "Notes" must not eat "Notes archive": the separator is what makes
        // one path a child of another, not the letters.
        #expect(
            SidebarSelection.outermost(["Notes", "Notes archive", "Notes/A.md"])
                == ["Notes", "Notes archive"]
        )
    }

    @Test("The tree's items come back outermost first")
    func modelResolvesItems() async throws {
        let root = try vaultRoot(["Folder/A.md": "a\n", "Folder/B.md": "b\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "C.md"),
            host: ScriptedHost()
        ))
        defer { model.closeWorkspace() }

        let items = model.items(for: ["Folder", "Folder/A.md", "C.md"])
        #expect(items.map(\.relativePath) == ["C.md", "Folder"])
    }

    // MARK: - The verbs

    @Test("Command-Delete trashes every selected row, asking once")
    func deletesTheSelection() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.sidebarKeys.selection = SidebarSelection(paths: ["A.md", "B.md"])
        #expect(model.canDeleteFromSidebar)
        #expect(model.deleteFromKeyboard())

        // One question, not one per file.
        #expect(host.asked.filter { $0.hasPrefix("confirm:") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("B.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("C.md").path))
        // And the rows are no longer what a key acts on.
        #expect(model.sidebarKeys.selection.isEmpty)
    }

    @Test("Saying no to the one question keeps every file")
    func refusingKeepsEverything() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [false]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.sidebarKeys.selection = SidebarSelection(paths: ["A.md", "B.md"])
        #expect(model.deleteFromKeyboard())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("B.md").path))
    }

    @Test("Deleting a folder and a note beside it trashes both")
    func deletesFoldersAndNotesTogether() async throws {
        let root = try vaultRoot(["Folder/A.md": "a\n", "Folder/B.md": "b\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        // The folder and one of its own notes, which is what a shift-click
        // across an open folder gives you.
        model.sidebarKeys.selection = SidebarSelection(paths: ["Folder", "Folder/A.md", "C.md"])
        #expect(model.deleteFromKeyboard())
        #expect(host.asked.filter { $0.hasPrefix("confirm:") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("C.md").path))
    }

    @Test("Command-C puts every selected file on the pasteboard")
    func copiesTheSelection() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.sidebarKeys.selection = SidebarSelection(paths: ["A.md", "B.md"])
        #expect(model.canCopyFile)
        #expect(model.copyFromKeyboard())
        #expect(Set(host.pasteboardFiles.map { $0.lastPathComponent }) == ["A.md", "B.md"])
    }

    @Test("Pasting the copied files puts all of them in the folder")
    func pastesTheWholeSelection() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.sidebarKeys.selection = SidebarSelection(paths: ["A.md", "B.md"])
        #expect(model.copyFromKeyboard())
        model.paste(into: root.appendingPathComponent("Folder", isDirectory: true))
        await waitForTree(model, toContain: "Folder/A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/B.md").path))
    }

    @Test("Move to… asks for one folder and moves everything into it")
    func movesTheSelection() async throws {
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.folders = [root.appendingPathComponent("Folder", isDirectory: true)]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.promptToMove(model.items(for: ["A.md", "B.md"]))
        #expect(host.asked.filter { $0.hasPrefix("folder:") }.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/B.md").path))
    }

    @Test("With nothing selected the keys still act on the clicked row")
    func fallsBackToTheClickedRow() async throws {
        // The whole of the previous behaviour has to survive: an empty
        // selection means "the row above", which is what every keystroke
        // meant before there was a selection at all.
        let root = try vaultRoot(["A.md": "a\n", "B.md": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        host.confirmations = [true]
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        model.sidebarKeyboardTarget = root.appendingPathComponent("A.md")
        #expect(model.deleteFromKeyboard())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("B.md").path))
    }

    @Test("Paste falls back to the selection when nothing was clicked last")
    func pasteFallsBackToTheSelection() async throws {
        // A ⌘V that silently does nothing is worse than one that pastes
        // beside the rows the reader can see are chosen.
        let root = try vaultRoot(["A.md": "a\n", "Folder/Keep.md": "k\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ScriptedHost()
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: nil),
            host: host
        ))
        defer { model.closeWorkspace() }

        host.pasteboardFiles = [root.appendingPathComponent("A.md")]
        model.sidebarKeyboardTarget = nil
        model.sidebarKeys.selection = SidebarSelection(paths: ["Folder"])
        #expect(model.pasteFromKeyboard())
        await waitForTree(model, toContain: "Folder/A.md")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.md").path))
    }

    @Test("A right-click aims the keys at the row it opened on")
    func rightClickAimsTheKeys() throws {
        // Copying from the context menu and then pressing ⌘V has to paste
        // somewhere. Before this the keys were still aimed at whatever was
        // left-clicked last, which could be nothing at all.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("private func aimKeyboard()"))
        #expect(source.components(separatedBy: ".onAppear { aimKeyboard() }").count == 3,
                "both the file menu and the folder menu should aim the keys")
    }

    // MARK: - What the tree draws

    @Test("A collapsed folder hides its children from a range")
    func visibleOrderFollowsTheDisclosure() {
        let tree = [
            VaultItem(
                url: URL(fileURLWithPath: "/v/Folder"), relativePath: "Folder",
                kind: .folder, name: "Folder",
                children: [
                    VaultItem(
                        url: URL(fileURLWithPath: "/v/Folder/A.md"), relativePath: "Folder/A.md",
                        kind: .markdown, name: "A"
                    ),
                ]
            ),
            VaultItem(
                url: URL(fileURLWithPath: "/v/C.md"), relativePath: "C.md",
                kind: .markdown, name: "C"
            ),
        ]
        #expect(SidebarSelection.visibleOrder(of: tree, expanded: []) == ["Folder", "C.md"])
        #expect(
            SidebarSelection.visibleOrder(of: tree, expanded: ["Folder"])
                == ["Folder", "Folder/A.md", "C.md"]
        )
    }

    @Test("Modifiers pick the click, and shift wins over command")
    func modifiersMap() {
        #expect(SidebarSelection.click(command: false, shift: false) == .plain)
        #expect(SidebarSelection.click(command: true, shift: false) == .toggle)
        #expect(SidebarSelection.click(command: false, shift: true) == .extend)
        #expect(SidebarSelection.click(command: true, shift: true) == .extend)
    }

    @Test("A selected row is lit even while another note is open")
    func selectionOwnsTheLight() {
        // Once files are picked out by hand, that is what the light is about.
        // Lighting the open note as well would hide one of the files that is
        // about to be trashed.
        #expect(SidebarHighlight.litsFile(
            "A.md", highlighted: nil, current: "B.md",
            selected: SidebarSelection(paths: ["A.md"])
        ))
        #expect(!SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md",
            selected: SidebarSelection(paths: ["A.md"])
        ))
        // And with nothing selected the older rules are untouched.
        #expect(SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md"
        ))
        // A folder-only selection is navigation and does not claim the light,
        // so the open note stays visible while a folder is being browsed.
        #expect(SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md",
            selected: SidebarSelection(paths: ["Folder"], folders: ["Folder"])
        ))
        // One file among the folders is enough to make it a choice again.
        #expect(!SidebarHighlight.litsFile(
            "B.md", highlighted: nil, current: "B.md",
            selected: SidebarSelection(paths: ["Folder", "A.md"], folders: ["Folder"])
        ))
    }

    /// A click records whether the row was a folder, because nothing else can
    /// tell afterwards: a selection is a set of paths, and a path does not say
    /// what it points at.
    @Test("A click remembers which rows were folders")
    func clicksRecordFolders() {
        let visible = ["Folder", "Folder/A.md", "B.md"]
        let folders: Set<String> = ["Folder"]

        // A plain click on a folder is navigation and chooses nothing, but it
        // still moves the anchor a later shift-click measures from.
        var selection = SidebarSelection()
        selection.click("Folder", .plain, visible: visible, folders: folders)
        #expect(selection.isEmpty)
        #expect(selection.anchor == "Folder")
        #expect(!selection.holdsFile)

        // Command-clicking one is a choice, and is remembered as a folder.
        selection.click("Folder", .toggle, visible: visible, folders: folders)
        #expect(selection.folders == ["Folder"])
        #expect(!selection.holdsFile)

        selection.click("B.md", .toggle, visible: visible, folders: folders)
        #expect(selection.folders == ["Folder"])
        #expect(selection.holdsFile)

        // Extending re-derives the whole set, so the folders come with it, and
        // a range that began on a browsed folder still has its anchor.
        var extended = SidebarSelection()
        extended.click("Folder", .plain, visible: visible, folders: folders)
        extended.click("Folder/A.md", .extend, visible: visible, folders: folders)
        #expect(extended.paths == ["Folder", "Folder/A.md"])
        #expect(extended.folders == ["Folder"])
        #expect(extended.holdsFile)

        // Dropping the file again leaves only folders behind.
        var toggled = SidebarSelection()
        toggled.click("Folder", .toggle, visible: visible, folders: folders)
        toggled.click("B.md", .toggle, visible: visible, folders: folders)
        toggled.click("B.md", .toggle, visible: visible, folders: folders)
        #expect(toggled.paths == ["Folder"])
        #expect(!toggled.holdsFile)
    }

    /// Only the rows a click can reach, so a shift-click and the folder set it
    /// is measured against describe the same tree.
    @Test("The visible folders follow what is expanded")
    func visibleFoldersMatchTheDrawnRows() {
        let tree = [
            VaultItem(
                url: URL(fileURLWithPath: "/v/Folder"), relativePath: "Folder", kind: .folder, name: "Folder",
                children: [
                    VaultItem(
                        url: URL(fileURLWithPath: "/v/Folder/Nested"), relativePath: "Folder/Nested",
                        kind: .folder, name: "Nested", children: []
                    )
                ]
            ),
            VaultItem(
                url: URL(fileURLWithPath: "/v/B.md"), relativePath: "B.md", kind: .markdown, name: "B.md",
                children: []
            ),
        ]
        #expect(SidebarSelection.visibleFolders(of: tree, expanded: []) == ["Folder"])
        #expect(
            SidebarSelection.visibleFolders(of: tree, expanded: ["Folder"])
                == ["Folder", "Folder/Nested"]
        )
    }

    /// The weaker mark, and the thing it exists for: a folder browsed into is
    /// what ⌘⌫ acts on, and since opening one stopped lighting it there was
    /// nothing on screen saying so.
    @Test("The row the keys act on is marked, and unmarked when they go back")
    func keyTargetIsMarkedUntilTheKeysGoBack() async throws {
        let root = try vaultRoot(["Folder/A.md": "a\n", "C.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "C.md"),
            host: ScriptedHost()
        ))
        defer { model.closeWorkspace() }

        let folder = try #require(
            model.tree?.flattened().first { $0.relativePath == "Folder" }
        )
        model.sidebarKeyboardTarget = folder.url
        #expect(model.keyTargetPath == "Folder", "the tree is told which row the keys point at")
        #expect(SidebarHighlight.marksKeyTarget(isTarget: true, lit: false))

        // Typing in the note hands the keys back, and the mark goes with them.
        model.releaseSidebarKeys()
        #expect(model.keyTargetPath == nil)
    }

    @Test("The weaker mark yields to anything stronger")
    func keyTargetYields() {
        // A lit row says it already, and marking it twice would only make the
        // light look inconsistent.
        #expect(!SidebarHighlight.marksKeyTarget(isTarget: true, lit: true))
        // With rows chosen by hand, those are what the keys act on, so the
        // last-clicked row has no claim on the reader's attention.
        #expect(!SidebarHighlight.marksKeyTarget(
            isTarget: true, lit: false, selected: SidebarSelection(paths: ["A.md"])
        ))
        #expect(!SidebarHighlight.marksKeyTarget(isTarget: false, lit: false))
    }

}
