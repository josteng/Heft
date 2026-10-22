import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A note an old editor saved in Latin-1: `é` is the lone byte E9, which is
/// not UTF-8. The editor opens it as Latin-1, so a save has to write it back
/// the same way or every byte above 127 changes.
@Suite("A Latin-1 note keeps its bytes")
@MainActor
struct NoteEncodingTests {

    /// `Café` in Latin-1.
    private static let cafe: [UInt8] = [0x43, 0x61, 0x66, 0xE9]

    private func vault(_ bytes: [UInt8]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-encoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(bytes).write(to: root.appendingPathComponent("Note.md"))
        return root
    }

    private func bytes(_ root: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent("Note.md")))
    }

    private func model(_ root: URL) -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
    }

    @Test("The editor's save writes Latin-1 back, with no conflict")
    func macSaveKeepsLatin1() throws {
        let root = try vault(Self.cafe + Array("\n".utf8))
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        defer { model.closeWorkspace() }
        #expect(model.text == "Café\n")
        model.text += "more\n"
        model.save()

        #expect(model.saveConflict == nil, "its own file read as a change on disk")
        #expect(try bytes(root) == Self.cafe + Array("\nmore\n".utf8))
        model.reloadCurrentIfChangedExternally()
        #expect(model.saveConflict == nil)
        #expect(model.text == "Café\nmore\n")
    }

    @Test("A character Latin-1 has no byte for is refused, and the file kept")
    func macSaveRefusesWhatLatin1CannotHold() throws {
        let original = Self.cafe + Array("\n".utf8)
        let root = try vault(original)
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        defer { model.closeWorkspace() }
        model.text += "5 €\n"
        model.save()

        #expect(try bytes(root) == original, "the file was converted")
        #expect(model.writeFailed)
        #expect(model.isDirty, "the edit was dropped")
        #expect(model.status.contains("Latin-1"))
    }

    @Test("A UTF-8 note stays UTF-8, and a new one is written as UTF-8")
    func utf8StaysUtf8() throws {
        let root = try vault(Array("Cafe\n".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        try "Café €\n".writeNote(to: note)
        #expect(try bytes(root) == Array("Café €\n".utf8))

        let fresh = root.appendingPathComponent("New.md")
        try "Café\n".writeNote(to: fresh)
        #expect(Array(try Data(contentsOf: fresh)) == Array("Café\n".utf8))
    }

    @Test("Every byte of a Latin-1 file reads and writes back unchanged")
    func everyByteRoundTrips() throws {
        let all = (0...255).map(UInt8.init).filter { $0 != 0 }
        let root = try vault(Self.cafe + all)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        let text = try #require(NoteEncoding.read(note))
        try text.writeNote(to: note)
        #expect(try bytes(root) == Self.cafe + all)
    }
}
