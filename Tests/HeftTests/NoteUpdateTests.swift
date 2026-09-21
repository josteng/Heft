import Foundation
import Testing
@testable import HeftCore

/// A rewrite asked for by voice goes to review, not to the file.
///
/// Every other way in only adds a line, and cannot lose one. This one
/// replaces the note, and the person asking for it has not read what came
/// back: a misheard word could drop a paragraph and the file would not say
/// so. The base text travels with it so the review centre can tell that the
/// note moved underneath.
@Suite("Rewriting a note by asking")
struct NoteUpdateTests {

    private func vault(_ note: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try note.write(
            to: root.appendingPathComponent("Roof.md"), atomically: true, encoding: .utf8
        )
        return root
    }

    @Test("The note on disk is untouched, and the rewrite is waiting in review")
    func aRewriteIsProposed() throws {
        let root = try vault("The tiles go on in April.\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let proposal = try #require(
            try NoteUpdate.propose(
                "The tiles go on in May.\n", to: "Roof.md", in: root, agent: "Siri"
            )
        )
        let onDisk = try String(
            contentsOf: root.appendingPathComponent("Roof.md"), encoding: .utf8
        )
        #expect(onDisk == "The tiles go on in April.\n", "the rewrite was written straight in")

        #expect(proposal.kind == .edit)
        #expect(proposal.notePath == "Roof.md")
        #expect(proposal.agent == "Siri")
        #expect(proposal.base == "The tiles go on in April.\n", "no base, no diff to read")
        #expect(proposal.body == "The tiles go on in May.\n")
        #expect(proposal.summary.contains("Roof"))

        // And it is in the vault for the review centre to find, not only
        // returned to the caller.
        let waiting = ProposalStore.all(in: root)
        #expect(waiting.map(\.id) == [proposal.id])
    }

    @Test("A rewrite that changes nothing is not a review")
    func anIdenticalRewriteIsDropped() throws {
        let root = try vault("As it is.\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try NoteUpdate.propose("As it is.\n", to: "Roof.md", in: root, agent: "Siri") == nil)
        #expect(ProposalStore.all(in: root).isEmpty)
    }

    @Test("A note that is not there is refused, not created")
    func aMissingNoteIsRefused() throws {
        let root = try vault("Anything.\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: NoteAppend.Failure.self) {
            try NoteUpdate.propose("New text.\n", to: "Gone.md", in: root, agent: "Siri")
        }
        #expect(ProposalStore.all(in: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone.md").path))
    }
}
