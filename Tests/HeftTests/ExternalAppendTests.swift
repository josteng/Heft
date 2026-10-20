import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A line filed into the open note from outside, by `heft capture`, a Spotlight
/// or Siri capture, or the share sheet, while the reader is typing in it. The
/// capturing side has already reported success, so losing the line is silent.
@Suite("A captured line survives the open note")
@MainActor
struct ExternalAppendTests {

    private func vault(_ text: String = "# Today\n\nfirst\n") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func model(_ root: URL) -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
    }

    private func disk(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
    }

    /// The save compared the file with what it last saw and then wrote it,
    /// uncoordinated, so an append landing between the two was written over.
    @Test("An append racing a save is not written over")
    func appendBetweenReadAndWrite() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        #expect(model.current?.relativePath == "Note.md")
        model.text = "# Today\n\nfirst, edited\n"

        let appended = DispatchSemaphore(value: 0)
        model.beforeSaveWrites = {
            DispatchQueue.global().async {
                try? NoteAppend.append("- 10:00 call", to: "Note.md", in: root)
                appended.signal()
            }
            // Room for an uncoordinated append to finish before the write.
            // A coordinated save makes it wait instead, however long this is.
            Thread.sleep(forTimeInterval: 0.5)
        }
        model.save()
        model.beforeSaveWrites = nil
        #expect(appended.wait(timeout: .now() + 10) == .success, "the append never finished")

        #expect(try disk(root) == "# Today\n\nfirst, edited\n\n- 10:00 call\n", "the captured line was lost")
    }

    /// The usual case: typing in today's note while a capture lands in it.
    /// The poll found unsaved edits and a changed file and paused saving, and
    /// "keep mine" then wrote the buffer and dropped the captured line.
    @Test("An append while typing is merged by the poll, not a conflict")
    func appendWhileTypingIsMerged() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        #expect(model.current?.relativePath == "Note.md")
        model.text = "# Today\n\nfirst, edited\n"
        try NoteAppend.append("- 10:00 call", to: "Note.md", in: root)

        model.reloadCurrentIfChangedExternally()

        let merged = "# Today\n\nfirst, edited\n\n- 10:00 call\n"
        #expect(model.saveConflict == nil, "a disjoint append raised a conflict")
        #expect(model.text == merged, "the captured line did not reach the buffer")
        #expect(try disk(root) == merged, "the merge was not saved")
        #expect(model.flushPendingSave())
        #expect(DraftStore.draft(vault: root, relativePath: "Note.md") == nil)
    }

    /// The same, found by the autosave rather than the poll.
    @Test("An append found by a save is merged into it")
    func appendFoundBySave() throws {
        let root = try vault("# Today\n\nfirst")
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        #expect(model.current?.relativePath == "Note.md")
        // Typing on an unfinished last line, which the capture finishes.
        model.text = "# Today\n\nfirst, edi"
        try DailyNoteCapture.contents(
            byCapturing: "call", in: "# Today\n\nfirst", at: Date(), timestamped: false
        ).write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        model.save()

        let merged = "# Today\n\nfirst, edi\n- call\n"
        #expect(model.saveConflict == nil, "a disjoint append raised a conflict")
        #expect(model.text == merged)
        #expect(try disk(root) == merged)
    }

    /// A real conflict is still a person's call: both changed the same line.
    @Test("An overlapping change from outside still pauses saving")
    func overlappingChangeStillConflicts() throws {
        let root = try vault()
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        #expect(model.current?.relativePath == "Note.md")
        model.text = "# Today\n\nfirst, mine\n"
        try "# Today\n\nfirst, theirs\n".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )

        model.reloadCurrentIfChangedExternally()

        #expect(model.isSaveConflictAlertPresented, "no conflict was raised")
        #expect(model.text == "# Today\n\nfirst, mine\n", "the buffer was changed")
        #expect(try disk(root) == "# Today\n\nfirst, theirs\n", "the disk version was written over")
    }
}
