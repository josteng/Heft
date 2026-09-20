import Foundation
import HeftCore
import Testing
@testable import Heft

/// Filtering the tree finds folders, not only notes.
///
/// The filter searched the index, which knows about notes, so a folder
/// could be typed in full and nothing came back: the one place a reader
/// looks for a folder by name was the one place that could not answer.
@MainActor
@Suite("Filtering the tree for folders")
struct SidebarFolderFilterTests {

    private func folders(matching query: String, in tree: VaultItem) -> [VaultItem] {
        FolderSearch.folders(matching: query, in: tree)
    }

    private func tree(_ folders: [String]) throws -> VaultItem {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-folder-filter-\(UUID().uuidString)")
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true
            )
            try Data("body".utf8).write(
                to: root.appendingPathComponent(folder).appendingPathComponent("Note.md")
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        return VaultScanner.scan(root: root)
    }

    @Test("A folder is found by name, wherever it sits")
    func foldersAreFound() throws {
        let tree = try tree(["Work", "Archive/Old Work", "Personal"])
        #expect(folders(matching: "work", in: tree).map(\.relativePath) == ["Work", "Archive/Old Work"])
        #expect(folders(matching: "personal", in: tree).map(\.name) == ["Personal"])
        #expect(folders(matching: "nothing", in: tree).isEmpty)
        #expect(folders(matching: "", in: tree).isEmpty, "an empty filter is the whole tree, not a search")
    }

    @Test("The nearest match comes first")
    func nearestFirst() throws {
        // A prefix beats a substring, wherever each sits, and among equals
        // the shallower one wins: "Deep Work" only contains the query, so it
        // sorts behind "Notes on Work", which is shallower.
        let tree = try tree(["Notes on Work", "Work", "Work/Deep Work"])
        #expect(
            folders(matching: "work", in: tree).map(\.relativePath)
                == ["Work", "Notes on Work", "Work/Deep Work"]
        )
    }

    /// The sidebar draws what this rule returns, so the rule and the view
    /// have to stay the same shape.
    @Test("The sidebar filters folders the same way")
    func theSidebarUsesThisRule() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("FolderSearch.folders(matching: filter, in: tree)"))
        #expect(
            source.contains("model.revealFolder(folder.relativePath)"),
            "clicking one shows where it lives, open"
        )
        #expect(
            source.contains("selectedFolderPath = revealed.relativePath"),
            "and a revealed folder becomes the chosen one"
        )
        #expect(
            source.contains("model.sidebarKeyboardTarget = revealed.url"),
            "marked the way a clicked folder is"
        )
    }
}
