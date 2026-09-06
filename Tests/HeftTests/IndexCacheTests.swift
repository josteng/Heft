import Foundation
import Testing
@testable import HeftCore

/// The parse cache on disk: what a build reads is what the last one left,
/// and only files that changed since are read again.
@Suite("Index cache on disk")
struct IndexCacheTests {

    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-index-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func makeCache() throws -> IndexCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-index-cache-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return IndexCache(directory: directory)
    }

    @Test("A second process reads nothing the first already parsed")
    func secondOpenReadsNothing() throws {
        let root = try makeVault(["A.md": "See [[B]] #tag", "B.md": "b"])
        let cache = try makeCache()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache.directory)
        }

        let first = VaultIndex.open(vaultAt: root, cache: cache)
        #expect(first.notesRead == 2)

        let second = VaultIndex.open(vaultAt: root, cache: cache)
        #expect(second.notesRead == 0)
        #expect(second.backlinks(to: "B.md").count == 1)
        #expect(second.notes(taggedWith: "tag").count == 1)
    }

    @Test("A note that changed since the last process is read again")
    func changedNoteIsRead() throws {
        let root = try makeVault(["A.md": "See [[B]]", "B.md": "b", "C.md": "c"])
        let cache = try makeCache()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache.directory)
        }
        _ = VaultIndex.open(vaultAt: root, cache: cache)

        Thread.sleep(forTimeInterval: 0.02)
        try "See [[C]]".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        let again = VaultIndex.open(vaultAt: root, cache: cache)

        #expect(again.notesRead == 1)
        #expect(again.backlinks(to: "C.md").count == 1)
        #expect(again.backlinks(to: "B.md").isEmpty)
        // And the cache now holds the new parse.
        #expect(VaultIndex.open(vaultAt: root, cache: cache).notesRead == 0)
    }

    /// A file from an older layout is ignored, not decoded into nonsense.
    @Test("A cache file of another version is ignored")
    func otherVersionIsIgnored() throws {
        let root = try makeVault(["A.md": "a"])
        let cache = try makeCache()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache.directory)
        }
        _ = VaultIndex.open(vaultAt: root, cache: cache)
        #expect(cache.load(vault: root) != nil)

        let file = cache.url(for: root)
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\":\(IndexCache.version)", with: "\"version\":99")
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(cache.load(vault: root) == nil)

        try "garbage".write(to: file, atomically: true, encoding: .utf8)
        #expect(cache.load(vault: root) == nil)
        #expect(VaultIndex.open(vaultAt: root, cache: cache).notesRead == 1)
    }

    @Test("Two vaults keep separate files")
    func vaultsAreSeparate() throws {
        let one = try makeVault(["A.md": "one"])
        let two = try makeVault(["A.md": "two [[B]]", "B.md": "b"])
        let cache = try makeCache()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
            try? FileManager.default.removeItem(at: cache.directory)
        }
        _ = VaultIndex.open(vaultAt: one, cache: cache)
        _ = VaultIndex.open(vaultAt: two, cache: cache)
        #expect(cache.url(for: one) != cache.url(for: two))
        #expect(VaultIndex.open(vaultAt: one, cache: cache).notesRead == 0)
        #expect(VaultIndex.open(vaultAt: two, cache: cache).backlinks(to: "B.md").count == 1)
    }
}
