import Combine
import Foundation
import HeftCore
import Testing
@testable import Heft

/// A disk event that changes nothing must cost the windows nothing.
///
/// Every published property of the session reaches each window's model
/// through `objectWillChange`, and redrawing the chrome costs more than the
/// scan does. An iCloud vault raises several such events per save, so a
/// reload that finds the vault as it was has to stay silent.
@MainActor
@Suite("Vault session reloads")
struct VaultSessionReloadTests {

    @Test("A reload that finds nothing changed publishes nothing")
    func quietReloadPublishesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("A.md")
        try "First [[B]]".write(to: note, atomically: true, encoding: .utf8)

        let session = VaultSession(root: root)
        await session.awaitReload()
        #expect(session.index.notes.count == 1)

        var published = 0
        let subscription = session.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }

        session.reload(immediately: true)
        await session.awaitReload()
        #expect(published == 0, "nothing changed, so nothing should reach the windows")

        try "First [[B]] and [[C]]".write(to: note, atomically: true, encoding: .utf8)
        session.reload(immediately: true)
        await session.awaitReload()
        #expect(published > 0, "a changed note must still get through")
        #expect(session.index.outgoingLinks(from: "A.md").count == 2)
    }

    /// Most saves are prose. The note is re-read, and that is where it ends.
    @Test("A save that changes no link, tag or mention publishes nothing")
    func proseSavePublishesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("A.md")
        // The prose lives on its own line. A backlink carries the text of the
        // line it was found on, so typing beside the link *is* a new answer.
        try "First [[B]] #tag\n\nProse below.".write(to: note, atomically: true, encoding: .utf8)

        let session = VaultSession(root: root)
        await session.awaitReload()

        var published = 0
        let subscription = session.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }

        try "First [[B]] #tag\n\nProse below, and a sentence more."
            .write(to: note, atomically: true, encoding: .utf8)
        session.reload(immediately: true)
        await session.awaitReload()
        #expect(published == 0, "the same links and tags are the same answers")
        #expect(session.latestIndex.notesRead == 1, "the note was still read")

        // The unpublished build is the one the next reload starts from,
        // otherwise the saved note would be read again on every event.
        session.reload(immediately: true)
        await session.awaitReload()
        #expect(session.latestIndex.notesRead == 0)
        #expect(published == 0)

        try "First [[B]] #tag #another\n\nProse below, and a sentence more."
            .write(to: note, atomically: true, encoding: .utf8)
        session.reload(immediately: true)
        await session.awaitReload()
        #expect(published > 0, "a new tag is a new answer")
        #expect(session.index.tags(of: "A.md").count == 2)
    }
}
