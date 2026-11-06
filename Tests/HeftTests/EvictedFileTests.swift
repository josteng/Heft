import Foundation
import Testing
@testable import HeftCore

/// A file iCloud has evicted is only `.Name.icloud` on disk, and a
/// coordinated write does not fetch it first: treated as missing, a fresh
/// note was written where iCloud holds the real one.
@Suite("Evicted iCloud files")
struct EvictedFileTests {
    private func folder(under base: String) throws -> URL {
        let root = URL(fileURLWithPath: base).appendingPathComponent("heft-hunt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// iOS keeps evicted notes as `.Name.md.icloud`. The scanner lists the
    /// note as present; the daily note is still written fresh from the
    /// template, at the very path iCloud holds the real one.
    @Test("An evicted daily note is not created again from the template")
    func evictedDailyNoteRecreated() throws {
        let root = try folder(under: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: root) }
        let daily = DailyNotes(vaultRoot: root, settings: ObsidianSettings())
        let date = Date()
        let path = daily.relativePath(for: date)
        let name = (path as NSString).lastPathComponent
        let placeholder = root.appendingPathComponent((path as NSString).deletingLastPathComponent)
            .appendingPathComponent(".\(name).icloud")
        try FileManager.default.createDirectory(at: placeholder.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: placeholder)
        let tree = VaultScanner.scan(root: root)
        #expect(tree.flattened().contains { $0.relativePath == path && $0.needsDownload })

        _ = try daily.ensureNote(for: date)
        let written = try? String(contentsOf: daily.url(for: date), encoding: .utf8)
        #expect(written == nil, "a template note was written over the evicted daily note: \(written ?? "")")
    }

    /// The same for the inbox, which the iOS Capture sheet files into.
    @Test("A capture into an evicted inbox does not start a fresh inbox")
    func evictedInboxReplaced() throws {
        let root = try folder(under: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = InboxCapture(vaultRoot: root, relativePath: "Inbox.md")
        try Data("placeholder".utf8).write(to: root.appendingPathComponent(".Inbox.md.icloud"))

        _ = try? inbox.capture("buy milk")
        let written = try? String(contentsOf: inbox.url, encoding: .utf8)
        #expect(written == nil, "wrote a one-line inbox where iCloud holds the real one: \(written ?? "")")
    }
}
