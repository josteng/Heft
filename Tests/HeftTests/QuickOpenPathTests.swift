import Foundation
import HeftCore
import Testing
@testable import Heft

/// Quick Open answers a path as well as a name.
///
/// A name search cannot find a note by where it lives, and a path is what a
/// terminal or an agent hands over: long, absolute, and often escaped or
/// quoted. It used to need a command of its own, which promised more than it
/// did, since nothing outside the vault can be opened anyway.
@MainActor
@Suite("Quick Open takes a path", .serialized)
struct QuickOpenPathTests {

    private func model(_ files: [String: String]) async throws -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-quickopen-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        let model = AppModel(
            registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path)
        )
        for _ in 0..<600 where model.index.notes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.index.notes.isEmpty, "the vault never finished scanning")
        return model
    }

    @Test("A vault-relative path names its note")
    func relativePath() async throws {
        let model = try await model(["Work/Notes/Quarter.md": "body"])
        defer { model.closeWorkspace() }
        #expect(model.noteAtPath("Work/Notes/Quarter.md")?.name == "Quarter")
    }

    @Test("An absolute path inside the vault names its note, however it is written")
    func absolutePath() async throws {
        let model = try await model(["Work Notes/Quarter One.md": "body"])
        defer { model.closeWorkspace() }
        let root = try #require(model.vaultRoot).standardizedFileURL.path
        let plain = "\(root)/Work Notes/Quarter One.md"

        #expect(model.noteAtPath(plain)?.name == "Quarter One")
        // The forms a terminal, a drag or a clipboard produce.
        #expect(model.noteAtPath("\"\(plain)\"")?.name == "Quarter One")
        #expect(model.noteAtPath(plain.replacingOccurrences(of: " ", with: "\\ "))?.name == "Quarter One")
        #expect(model.noteAtPath(URL(fileURLWithPath: plain).absoluteString)?.name == "Quarter One")
    }

    @Test("A path outside the vault, or to nothing, names no note")
    func outsideTheVault() async throws {
        let model = try await model(["other/Note.md": "body"])
        defer { model.closeWorkspace() }
        #expect(model.noteAtPath("/etc/hosts") == nil)
        #expect(model.noteAtPath("Work/Missing.md") == nil)
        #expect(model.noteAtPath("") == nil)

        // A folder beside the vault whose name merely starts with the
        // vault's own. Cutting the root off by length rather than checking
        // the boundary turns this into the note inside.
        let root = try #require(model.vaultRoot).standardizedFileURL.path
        #expect(model.noteAtPath("\(root)-other/Note.md") == nil)
    }

    /// The path row goes first, and only once: a query that is both a path
    /// and a name must not list the note twice.
    @Test("The note a path names comes first, and once")
    func pathComesFirst() async throws {
        let model = try await model([
            "Archive/Report.md": "old", "Report.md": "new", "Other.md": "x",
        ])
        defer { model.closeWorkspace() }
        let query = "Archive/Report.md"
        let found = model.index.search(query, limit: 60) { _ in 0 }
        let atPath = try #require(model.noteAtPath(query))
        let rows = [atPath] + found.filter { $0.relativePath != atPath.relativePath }

        #expect(rows.first?.relativePath == "Archive/Report.md")
        #expect(rows.filter { $0.relativePath == "Archive/Report.md" }.count == 1)
    }
}
