import Foundation
import Testing
@testable import HeftCore

/// Obsidian keeps where new notes go in the vault itself, which is what lets
/// the phone agree with it: Heft's own Mac setting stays on the Mac.
@Suite("Obsidian's new note location")
struct NewNoteLocationSettingTests {

    private func location(_ appJSON: String?) throws -> NewNoteLocation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewNoteLocation-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let appJSON {
            try appJSON.write(to: config.appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
        }
        return ObsidianSettings.load(vaultRoot: root).newNoteLocation
    }

    @Test("No setting is the vault root, as in Obsidian")
    func unset() throws {
        #expect(try location(nil) == .vaultRoot)
        #expect(try location(#"{"newFileLocation": "root"}"#) == .vaultRoot)
    }

    @Test("Current folder is beside the open note")
    func current() throws {
        #expect(try location(#"{"newFileLocation": "current"}"#) == .besideTheOpenNote)
    }

    @Test("A named folder is kept, and an empty one is the root")
    func folder() throws {
        #expect(try location(#"{"newFileLocation": "folder", "newFileFolderPath": "/Notes/Ideas/"}"#)
            == .folder("Notes/Ideas"))
        #expect(try location(#"{"newFileLocation": "folder", "newFileFolderPath": ""}"#) == .vaultRoot)
    }
}
