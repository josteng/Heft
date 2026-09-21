import Foundation
import Testing
@testable import HeftCore

/// What the Recent list is built from: the index's dates and first lines,
/// and the dating that groups and labels them.
@Suite("Recent list sources")
struct RecentListTests {

    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try write(text, to: root.appendingPathComponent(path)) }
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Two writes inside one clock tick would share a modification time.
    private func settle() { Thread.sleep(forTimeInterval: 0.02) }

    private func build(_ root: URL, reusing previous: VaultIndex? = nil) -> VaultIndex {
        VaultIndex.build(root: VaultScanner.scan(root: root), reusing: previous)
    }

    // MARK: Excerpts

    @Test("The excerpt is the first line of prose, read as prose")
    func excerptReadsAsProse() {
        #expect(NoteText.excerpt("---\ntitle: x\n---\n# Heading\n\n- [ ] Buy **milk** at [[Shop|the shop]]\n") == "Buy milk at the shop")
        #expect(NoteText.excerpt("> 1. See [[Note]] and [docs](https://example.com)") == "See Note and docs")
        #expect(NoteText.excerpt("```\ncode\n```\n![[picture.png]]\nAfter the fence") == "After the fence")
        #expect(NoteText.excerpt("# Only\n## Headings\n") == "")
    }

    @Test("A long first line is cut with an ellipsis")
    func excerptIsCut() {
        let long = String(repeating: "word ", count: 60)
        let cut = NoteText.excerpt(long, limit: 20)
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= 21)
    }

    // MARK: The index

    @Test("Notes come newest edit first, and carry their date and first line")
    func indexOrdersByLastEdit() throws {
        let root = try makeVault(["Old.md": "first", "Sub/New.md": "# T\nsecond"])
        defer { try? FileManager.default.removeItem(at: root) }
        settle()
        try write("first, again", to: root.appendingPathComponent("Old.md"))

        let index = build(root)
        #expect(index.notesByLastEdit.map(\.relativePath) == ["Old.md", "Sub/New.md"])
        #expect(index.excerpt(of: "Old.md") == "first, again")
        #expect(index.excerpt(of: "Sub/New.md") == "second")
        let date = try #require(index.modificationDate(of: "Old.md"))
        #expect(abs(date.timeIntervalSinceNow) < 5)
        #expect(index.modificationDate(of: "Missing.md") == nil)
    }

    @Test("A rebuild that read nothing still knows every first line")
    func excerptSurvivesReuse() throws {
        let root = try makeVault(["A.md": "alpha", "B.md": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = build(root)
        let second = build(root, reusing: first)
        #expect(second.notesRead == 0)
        #expect(second.excerpt(of: "A.md") == "alpha")
        #expect(second.excerpt(of: "B.md") == "beta")
    }

    // MARK: Dating

    private var dating: RecentDating {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 15))!
        return RecentDating(calendar: calendar, locale: Locale(identifier: "en_US"), now: now)
    }

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        let d = dating.calendar.date(byAdding: .day, value: -days, to: dating.now)!
        return dating.calendar.date(bySettingHour: hour, minute: 3, second: 0, of: d)!
    }

    @Test("Sections get coarser the further back a note was written")
    func sectionsCoarsen() {
        let d = dating
        #expect(d.section(for: d.now) == .today)
        #expect(d.section(for: daysAgo(0, hour: 0)) == .today)
        #expect(d.section(for: d.now.addingTimeInterval(3600)) == .today)
        #expect(d.section(for: daysAgo(1, hour: 23)) == .yesterday)
        #expect(d.section(for: daysAgo(2)) == .previousSevenDays)
        #expect(d.section(for: daysAgo(7)) == .previousSevenDays)
        #expect(d.section(for: daysAgo(8)) == .previousThirtyDays)
        #expect(d.section(for: daysAgo(30)) == .previousThirtyDays)
        #expect(d.section(for: daysAgo(31)) == .month(8))
        #expect(d.section(for: daysAgo(400)) == .year(2025))
        #expect(d.title(of: .month(8)) == "August")
        #expect(d.title(of: .year(2025)) == "2025")
        #expect(d.title(of: .previousSevenDays) == "Previous 7 Days")
    }

    @Test("A row's date is the time today, the weekday this week, the date beyond")
    func labelsFitTheDistance() {
        let d = dating
        #expect(d.label(for: d.now).contains("3:00"))
        #expect(d.label(for: daysAgo(1)) == "Yesterday")
        #expect(d.label(for: daysAgo(3)) == "Thursday")
        #expect(d.label(for: daysAgo(20)) == "08/31/2026")
        var german = d.calendar
        german.locale = Locale(identifier: "de_DE")
        let de = RecentDating(calendar: german, locale: Locale(identifier: "de_DE"), now: d.now)
        #expect(de.label(for: daysAgo(20)) == "31.08.2026")
    }

    @Test("Grouping keeps consecutive runs and files undated notes as Earlier")
    func groupingRuns() {
        let d = dating
        let items: [(String, Date?)] = [
            ("a", d.now), ("b", daysAgo(0, hour: 1)), ("c", daysAgo(3)), ("d", daysAgo(400)), ("e", nil),
        ]
        let groups = d.grouped(items) { $0.1 }
        #expect(groups.map(\.section) == [.today, .previousSevenDays, .year(2025), .earlier])
        #expect(groups.map { $0.items.map(\.0) } == [["a", "b"], ["c"], ["d"], ["e"]])
        #expect(d.title(of: .earlier) == "Earlier")
    }
}
