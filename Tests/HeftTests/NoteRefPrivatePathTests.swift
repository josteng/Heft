import Foundation
import HeftCore
import Testing

/// An iOS vault is under `/private/var`, and `standardizedFileURL` drops
/// `/private` only from a path that exists: a note the index has not listed
/// yet, as one just renamed, was taken to be outside its vault.
@Suite("Notes under /private")
struct NoteRefPrivatePathTests {
    @Test("A note not on disk yet is still inside a vault under /private")
    func notYetListed() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("heft-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try #require(NoteRef(url: root.appendingPathComponent("Trips/Porto.md"), vaultRoot: root))
        #expect(ref.relativePath == "Trips/Porto.md")
        #expect(NoteRef(url: URL(fileURLWithPath: "/private/tmp/elsewhere.md"), vaultRoot: root) == nil)
    }
}
