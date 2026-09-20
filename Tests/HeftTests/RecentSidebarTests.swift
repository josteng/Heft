import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The Recent list's app side: the preview row draws its extra lines, the
/// settings default to what Notes does, and a save reaches the list although
/// it publishes nothing.
@MainActor
@Suite("Recent list in the sidebar", .serialized)
struct RecentSidebarTests {

    private func coverage(_ row: NoteRow) throws -> Int {
        let renderer = ImageRenderer(content: row.frame(width: 240, height: 64))
        renderer.scale = 2
        let rendered = try #require(renderer.nsImage)
        let data = try #require(rendered.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var painted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.alphaComponent > 0.1 { painted += 1 }
            }
        }
        return painted
    }

    @Test("A preview row paints its date, first line and folder under the name")
    func previewRowDrawsMore() throws {
        let plain = try coverage(NoteRow(
            name: "Quarterly Notes", detail: nil, isSelected: false, depth: 0, symbol: "doc.text", action: {}
        ))
        let preview = try coverage(NoteRow(
            name: "Quarterly Notes", detail: nil, isSelected: false, depth: 0, symbol: "doc.text",
            preview: NotePreview(date: "Thursday", excerpt: "Numbers for the quarter", location: .init(name: "Work", symbol: "folder")),
            action: {}
        ))
        #expect(preview > plain * 2, "plain \(plain), preview \(preview)")
    }

    @Test("A note in the root names the vault, not a folder of the same name")
    func rootNotesNameTheVault() {
        let root = URL(fileURLWithPath: "/tmp/heft-example-vault")
        let inRoot = try! #require(NoteRef(url: root.appendingPathComponent("Note.md"), vaultRoot: root))
        let inFolder = try! #require(NoteRef(url: root.appendingPathComponent("Work/Note.md"), vaultRoot: root))
        #expect(NotePreview.Location.of(inRoot, inVaultNamed: "PersonalVault")
            == .init(name: "PersonalVault", symbol: "books.vertical"))
        #expect(NotePreview.Location.of(inFolder, inVaultNamed: "PersonalVault")
            == .init(name: "Work", symbol: "folder"))
    }

    @Test("Recent is ordered by last edit and shown as a preview unless asked otherwise")
    func defaultsFollowNotes() {
        let orderKey = "dev.stenglein.Heft.sidebar.recentOrder"
        let layoutKey = "dev.stenglein.Heft.sidebar.recentLayout"
        #expect(HeftDefaults.shared.string(forKey: orderKey) != nil
            || AppearanceSettings.shared.recentOrder == .edited)
        #expect(HeftDefaults.shared.string(forKey: layoutKey) != nil
            || AppearanceSettings.shared.recentLayout == .preview)
    }

    @Test("An opening is dated, so the opened order can be grouped by day too")
    func openingsAreDated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-recent-opened-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "one".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "two".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let cacheDirectory = root.appendingPathComponent(".cache", isDirectory: true)
        let session = VaultSession(root: root, cache: IndexCache(directory: cacheDirectory))
        defer {
            HeftDefaults.shared.removeObject(forKey: "dev.stenglein.Heft.recents.\(root.path)")
            HeftDefaults.shared.removeObject(forKey: "dev.stenglein.Heft.recentOpenedAt.\(root.path)")
            try? FileManager.default.removeItem(at: root)
        }
        await session.awaitReload()

        // The same clock time a day earlier, which is yesterday whatever the
        // hour. Counting back a fixed 26 hours is yesterday only after two in
        // the morning, and lands on the day before that between midnight and
        // then, which is how this first failed.
        let yesterday = try #require(
            Calendar.current.date(byAdding: .day, value: -1, to: Date())
        )
        session.recordRecent("A.md", at: yesterday)
        session.recordRecent("B.md")
        #expect(session.lastOpened("A.md").map { abs($0.timeIntervalSince(yesterday)) < 1 } == true)
        #expect(session.lastOpened("B.md").map { abs($0.timeIntervalSinceNow) < 5 } == true)
        #expect(session.lastOpened("Gone.md") == nil)

        // The two openings are a day apart, so the list has two headings.
        let dating = RecentDating()
        let sections = dating.grouped(["B.md", "A.md"]) { session.lastOpened($0) }.map(\.section)
        #expect(sections == [.today, .yesterday])

        // A rename takes the date with it, and a fresh session reads it back.
        session.replaceRecentPath("A.md", with: "Moved.md")
        #expect(session.lastOpened("A.md") == nil)
        #expect(session.lastOpened("Moved.md").map { abs($0.timeIntervalSince(yesterday)) < 1 } == true)
        let reopened = VaultSession(root: root, cache: IndexCache(directory: cacheDirectory))
        #expect(reopened.lastOpened("Moved.md").map { abs($0.timeIntervalSince(yesterday)) < 1 } == true)
    }

    @Test("A save that changes only prose still reorders the edited list")
    func proseSaveReachesTheList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-recent-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "one".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(20))
        try "two".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let cacheDirectory = root.appendingPathComponent(".cache", isDirectory: true)
        let session = VaultSession(root: root, cache: IndexCache(directory: cacheDirectory))
        defer { try? FileManager.default.removeItem(at: root) }
        await session.awaitReload()
        #expect(session.recentlyEdited.map(\.relativePath) == ["B.md", "A.md"])

        var signals = 0
        let subscription = session.contentChanges.sink { signals += 1 }
        defer { subscription.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        try "one, edited".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        // The watcher ignores this process's own writes; ask, as a save does.
        session.reload(immediately: true)
        await session.awaitReload()

        #expect(signals == 1)
        #expect(session.recentlyEdited.map(\.relativePath) == ["A.md", "B.md"])
        #expect(session.latestIndex.excerpt(of: "A.md") == "one, edited")
        // No answer changed, so nothing was published: the list is what listened.
        #expect(session.index.excerpt(of: "A.md") == "one")
    }
}
