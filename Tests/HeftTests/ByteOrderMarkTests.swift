import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A note whose file opens with a UTF-8 byte-order mark, as Notepad before
/// 2019 and some exporters write them. Foundation's UTF-8 read drops the
/// mark, so every writer that wrote the text back dropped it from the file.
@Suite("A byte-order mark stays exactly where the file had one")
@MainActor
struct ByteOrderMarkTests {

    private static let mark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private func vault(_ files: [String: [UInt8]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-bom-\(UUID().uuidString)")
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(bytes).write(to: url)
        }
        return root
    }

    private func marked(_ text: String) -> [UInt8] { Self.mark + Array(text.utf8) }

    private func bytes(_ root: URL, _ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(path)))
    }

    private func model(_ root: URL, _ note: String = "Note.md") -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: note)
        )
    }

    @Test("The editor's save keeps the mark and the text has none")
    func macSaveKeepsTheMark() throws {
        let root = try vault(["Note.md": marked("---\ntags: [a]\n---\n# Title\n")])
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        defer { model.closeWorkspace() }
        #expect(model.text == "---\ntags: [a]\n---\n# Title\n", "the mark is not in the buffer")
        model.text += "\nmore\n"
        model.save()

        #expect(try bytes(root, "Note.md") == marked("---\ntags: [a]\n---\n# Title\n\nmore\n"))
        // Reading back what was written is no change on disk.
        model.reloadCurrentIfChangedExternally()
        #expect(model.saveConflict == nil, "the mark raised a conflict")
        #expect(model.text == "---\ntags: [a]\n---\n# Title\n\nmore\n")
    }

    @Test("A note without a mark never gains one")
    func macSaveAddsNone() throws {
        let root = try vault(["Note.md": Array("# Title\n".utf8)])
        defer {
            DraftStore.discard(vault: root, relativePath: "Note.md")
            try? FileManager.default.removeItem(at: root)
        }
        let model = model(root)
        defer { model.closeWorkspace() }
        model.text = "# Title\nmore\n"
        model.save()
        #expect(try bytes(root, "Note.md") == Array("# Title\nmore\n".utf8))
    }

    @Test("Accepting a proposal for a closed note keeps its mark")
    func proposalKeepsTheMark() throws {
        let root = try vault([
            "Anchor.md": Array("anchor".utf8),
            "Note.md": marked("old\n"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try ProposalStore.write(
            Proposal(
                notePath: "Note.md", base: "old\n", body: "new\n",
                agent: "claude-code", summary: "Replace", kind: .edit
            ),
            in: root
        )
        let model = model(root, "Anchor.md")
        defer { model.closeWorkspace() }
        model.refreshProposals()
        let waiting = try #require(model.pendingProposals.edits.first)
        model.acceptAll(waiting)
        #expect(try bytes(root, "Note.md") == marked("new\n"))
    }

    @Test("The phone's save keeps the mark, and reading it back is no conflict")
    func noteFileKeepsTheMark() throws {
        let root = try vault(["Note.md": marked("# Title\n"), "Plain.md": Array("plain\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Note.md")

        let original = try NoteFile.read(url)
        #expect(original == "# Title\n")
        try NoteFile.write("# Title\nmore\n", to: url, replacing: original)
        #expect(try bytes(root, "Note.md") == marked("# Title\nmore\n"))
        // The next save compares against what the last one wrote.
        try NoteFile.write("# Title\nmore\nagain\n", to: url, replacing: "# Title\nmore\n")
        #expect(try bytes(root, "Note.md") == marked("# Title\nmore\nagain\n"))

        try NoteFile.overwrite("kept\n", at: url)
        #expect(try bytes(root, "Note.md") == marked("kept\n"))

        let plain = root.appendingPathComponent("Plain.md")
        try NoteFile.write("plain\nmore\n", to: plain, replacing: "plain\n")
        try NoteFile.overwrite("plain\nagain\n", at: plain)
        #expect(try bytes(root, "Plain.md") == Array("plain\nagain\n".utf8))
    }

    @Test("A line appended or captured into a marked note keeps the mark")
    func capturesKeepTheMark() throws {
        let root = try vault([
            "Note.md": marked("# Note\n"),
            "Inbox.md": marked("# Inbox\n"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        try NoteAppend.append("appended", to: "Note.md", in: root)
        #expect(try bytes(root, "Note.md") == marked("# Note\n\nappended\n"))

        try InboxCapture(vaultRoot: root, relativePath: "Inbox.md").capture("filed")
        let inbox = try bytes(root, "Inbox.md")
        #expect(Array(inbox.prefix(3)) == Self.mark)
        #expect(Array(inbox.dropFirst(3).prefix(3)) != Self.mark, "a second mark")
        #expect(String(decoding: inbox, as: UTF8.self).contains("filed"))

        let capture = DailyNoteCapture(vaultRoot: root, settings: ObsidianSettings())
        let date = Date()
        let daily = capture.dailyNotes.relativePath(for: date)
        let dailyURL = root.appendingPathComponent(daily)
        try FileManager.default.createDirectory(
            at: dailyURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(marked("# Today\n")).write(to: dailyURL)
        try capture.capture("logged", at: date)
        let written = try bytes(root, daily)
        #expect(Array(written.prefix(3)) == Self.mark)
        #expect(String(decoding: written, as: UTF8.self).contains("logged"))
    }

    @Test("The agent guide merged into a marked CLAUDE.md keeps the mark")
    func agentGuideKeepsTheMark() throws {
        let root = try vault(["CLAUDE.md": marked("# Mine\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        try AgentGuide.install(in: root, binaryPath: "/usr/local/bin/heft")
        #expect(Array(try bytes(root, "CLAUDE.md").prefix(6)) == marked("# M"))
        #expect(Array(try bytes(root, "AGENTS.md").prefix(3)) != Self.mark, "a new file gained one")
    }

    @Test("Setting up daily notes over a marked template keeps the mark")
    func templateKeepsTheMark() throws {
        let root = try vault([
            "Note.md": Array("note".utf8),
            "Templates/Daily.md": marked("old\n"),
            ".obsidian/daily-notes.json": Array(#"{"template": "Templates/Daily"}"#.utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root)
        defer { model.closeWorkspace() }
        try model.configureDailyNotes(
            folder: "Daily", format: "YYYY-MM-DD", templatePath: "Templates/Daily",
            templateBody: "new\n"
        )
        #expect(try bytes(root, "Templates/Daily.md") == marked("new\n"))
    }

    @Test("A rename's link rewrite keeps the mark")
    func renameKeepsTheMark() throws {
        let root = try vault([
            "Old.md": Array("a".utf8),
            "Links.md": marked("See [[Old]].\n"),
            "Plain.md": Array("See [[Old]].\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = VaultScanner.scan(root: root)
        let index = VaultIndex.build(root: tree)
        let note = try #require(tree.flattened().first { $0.relativePath == "Old.md" })

        let summary = try VaultRename.perform(item: note, to: "New.md", index: index, vaultRoot: root)
        #expect(summary.notes == 2)
        #expect(try bytes(root, "Links.md") == marked("See [[New]].\n"))
        #expect(try bytes(root, "Plain.md") == Array("See [[New]].\n".utf8))
    }

    /// The lenient read keeps a note with one stray byte searchable; it kept
    /// the mark as a character too, so the frontmatter and the first heading
    /// after it were not seen.
    @Test("Frontmatter and a heading after a mark are recognised")
    func frontmatterAfterTheMark() throws {
        let invalid: [UInt8] = [0xFF]
        let root = try vault([
            "Strict.md": marked("---\ntags: [one]\n---\n# Strict\n"),
            "Lenient.md": marked("---\ntags: [two]\n---\n# Lenient\n") + invalid,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        for (path, title) in [("Strict.md", "Strict"), ("Lenient.md", "Lenient")] {
            let text = try #require(NoteText.readLeniently(root.appendingPathComponent(path)))
            #expect(NoteText.splitFrontmatter(text).frontmatter != nil, "\(path): no frontmatter")
            let body = NoteText.splitFrontmatter(text).body
            #expect(NoteText.headings(in: body).first?.text == title, "\(path): no heading")
        }
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        #expect(index.tags(of: "Strict.md") == ["one"])
        #expect(index.tags(of: "Lenient.md") == ["two"])
    }
}
