import Foundation
@testable import Heft
import HeftCore
import Testing

/// Learning where a vault already keeps its attachments, which is what makes
/// the default rule need no configuration.
///
/// Shaped after a real vault that keeps files in `Thesis_Figures`,
/// `Covers` and `Attachemnts` — three names, one misspelled — because
/// that is the case a single configured folder name cannot describe.
@Suite("Learning where attachments go")
struct AttachmentInferenceTests {

    private func withVault(
        _ files: [String: String], _ body: (VaultIndex) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        try body(VaultIndex.build(root: VaultScanner.scan(root: root)))
    }

    private var vault: [String: String] {
        [
            "Thesis/Thesis_Figures/plot.png": "x",
            "Thesis/Meetings/2026-05-05.md": "See ![[plot.png]] and ![[plot.png]]",
            "Thesis/Meetings/2026-06-30.md": "![[plot.png]]",
            "Books/Covers/Dune.jpg": "x",
            // A property, not an embed. An embed-only scan misses this folder
            // entirely, which is how a real vault of book covers went unseen.
            "Books/Dune.md": "---\nCover: Books/Covers/Dune.jpg\n---\n",
            "Misc/Attachemnts/note.pdf": "x",
            "Misc/Scratch.md": "[[note.pdf]]",
            "Daily Notes/2026-09-03.md": "nothing here",
        ]
    }

    @Test("Each folder is told its own habit, whatever it is called")
    func learnsPerFolder() throws {
        try withVault(vault) { index in
            #expect(index.attachmentDestination(near: "Thesis/Meetings")
                == "Thesis/Thesis_Figures")
            #expect(index.attachmentDestination(near: "Books") == "Books/Covers")
            #expect(index.attachmentDestination(near: "Misc") == "Misc/Attachemnts")
        }
    }

    /// A note in a folder with no history of its own inherits the habit of the
    /// folder above it, which is where a new meeting folder gets its answer.
    @Test("A new folder inherits from the one above it")
    func walksUp() throws {
        var files = vault
        files["Thesis/Meetings/2026-09-03/new.md"] = "nothing yet"
        try withVault(files) { index in
            #expect(index.attachmentDestination(near: "Thesis/Meetings/2026-09-03")
                == "Thesis/Thesis_Figures")
        }
    }

    /// The vault root is never consulted as a level. Aggregated there the
    /// answer is whatever the busiest corner of the vault does, so a daily note
    /// would be told to file its screenshots with the thesis. Better to have no
    /// answer and let the next rule speak.
    @Test("A folder with no habit gets no answer, not the vault's busiest one")
    func doesNotFallBackToTheWholeVault() throws {
        try withVault(vault) { index in
            #expect(index.attachmentDestination(near: "Daily Notes") == nil)
            #expect(index.attachmentDestination(near: "") == nil)
        }
    }

    @Test("The busier destination wins when a folder uses two")
    func mostUsedWins() throws {
        var files = vault
        files["Thesis/Meetings/stray.png"] = "x"
        files["Thesis/Meetings/odd.md"] = "![[stray.png]]"
        try withVault(files) { index in
            #expect(index.attachmentDestination(near: "Thesis/Meetings")
                == "Thesis/Thesis_Figures")
        }
    }

    @Test("Filenames are found however they are written")
    func findsEveryMention() {
        let names = AttachmentNames.mentioned(in: """
            ![[chart.png|500]] and ![alt](Assets/photo.JPG) and
            Cover: Books/Covers/Dune.jpg, plus a bare recording.m4a
            """)
        #expect(names == ["chart.png", "photo.jpg", "dune.jpg", "recording.m4a"])
        // A note is not an attachment: linking one says nothing about files.
        #expect(AttachmentNames.mentioned(in: "[[Some Note]] and [[Other.md]]").isEmpty)
    }
}

/// The whole path a paste takes, through the app-layer type the settings pane
/// previews with: real folders on disk, a real index, real rules.
@Suite("Where a paste would land")
@MainActor
struct AttachmentDestinationTests {

    /// Contents matter here: a helper that wrote the same embed into every
    /// note gave the daily note a habit too, and the first run of this test
    /// failed because the inference correctly believed it.
    private func withVault(
        _ files: [String: String], _ body: (URL, VaultIndex) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        try body(root, VaultIndex.build(root: VaultScanner.scan(root: root)))
    }

    @Test("A note in a folder with a habit follows it; one without falls to the root")
    func resolvesThroughTheAppLayer() throws {
        try withVault([
            "Thesis/Thesis_Figures/plot.png": "x",
            "Thesis/Meetings/2026-05-05.md": "![[plot.png]]",
            "Daily Notes/2026-09-03.md": "no attachments here",
        ]) { root, index in
            let destination = Attachments.Destination(
                rules: .standard, index: index, settings: ObsidianSettings()
            )
            let thesis = destination.resolve(
                vaultRoot: root,
                noteURL: root.appendingPathComponent("Thesis/Meetings/2026-05-05.md")
            )
            #expect(thesis.folder == "Thesis/Thesis_Figures")
            #expect(!thesis.needsCreating, "the folder it learned is one that exists")

            let daily = destination.resolve(
                vaultRoot: root,
                noteURL: root.appendingPathComponent("Daily Notes/2026-09-03.md")
            )
            #expect(daily.folder == "")
            #expect(daily.rule == .vaultRoot)
        }
    }

    /// The promise the pane makes in as many words: only the explicit rule
    /// creates anything, so a rule naming a folder that is not there hands on.
    @Test("A folder is never made for a rule that may not make one")
    func neverCreatesUnbidden() throws {
        try withVault(["Notes/note.md": "plain text"]) { root, index in
            let rules = AttachmentRules(rules: [.named("Attachments"), .vaultRoot])
            let chosen = Attachments.Destination(
                rules: rules, index: index, settings: ObsidianSettings()
            ).resolve(vaultRoot: root, noteURL: root.appendingPathComponent("Notes/note.md"))
            #expect(chosen.rule == .vaultRoot)
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Attachments").path
            ))
        }
    }
}
