import AppIntents
import Foundation
import Testing
@testable import HeftCore

/// macOS 27 adds Ask Siri to every context menu, so the only question left to
/// an app is what the question arrives attached to. A row hands over the note
/// it shows, and a path is only worth handing over when it names a note in
/// the vault the entity queries read.
@Suite("What Siri is told a view is showing")
struct SiriContextTests {
    let vault = URL(fileURLWithPath: "/tmp/example-vault")
    let other = URL(fileURLWithPath: "/tmp/example-other-vault")

    @Test("A note in the capture vault goes over as itself")
    func noteCarriesItsPath() throws {
        let identifier = try #require(
            SiriContext.note("Projects/Roof.md", in: vault, capture: vault)
        )
        #expect(identifier.identifier == "Projects/Roof.md")
        // The schema note carries the body, so it is the one worth handing
        // over wherever it exists.
        if #available(macOS 27.0, *) {
            #expect(identifier.entityType == SiriNoteEntity.self)
        } else {
            #expect(identifier.entityType == NoteEntity.self)
        }
    }

    @Test("A window onto another vault hands over nothing")
    func otherVaultIsNotAnnotated() {
        // The same relative path exists in both vaults often enough: a note
        // resolved against the wrong one is a confident wrong answer, which
        // is worse than Siri saying it does not know which note is meant.
        #expect(SiriContext.note("Projects/Roof.md", in: other, capture: vault) == nil)
        #expect(SiriContext.note("Projects/Roof.md", in: vault, capture: nil) == nil)
        #expect(SiriContext.note("Projects/Roof.md", in: nil, capture: vault) == nil)
    }

    @Test("A vault written the long way round is still the same vault")
    func pathsAreComparedStandardised() {
        let roundabout = URL(fileURLWithPath: "/tmp/example-other-vault/../example-vault")
        #expect(SiriContext.resolves(roundabout, capture: vault))
    }

    @Test("A folder goes over as the Notes schema's folder")
    @available(macOS 27.0, *)
    func folderCarriesItsPath() throws {
        let identifier = try #require(SiriContext.folder("Projects", in: vault, capture: vault))
        #expect(identifier.identifier == "Projects")
        #expect(identifier.entityType == SiriFolderEntity.self)
        // The vault root is a folder too, and the schema calls it the empty
        // path, so right-clicking the root is still worth annotating.
        #expect(SiriContext.folder("", in: vault, capture: vault)?.identifier == "")
        #expect(SiriContext.folder("Projects", in: other, capture: vault) == nil)
    }
}
