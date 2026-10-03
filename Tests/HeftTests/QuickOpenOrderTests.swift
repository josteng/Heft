import Foundation
import Testing
@testable import HeftCore

/// What ⌘O lists before anything is typed: a short block of recent or
/// frequent notes, then every other note ordered the other way.
@Suite("Quick Open order")
struct QuickOpenOrderTests {

    private func notes(_ names: [String]) -> [NoteRef] {
        names.map {
            NoteRef(
                relativePath: "\($0).md", url: URL(fileURLWithPath: "/vault/\($0).md"),
                name: $0, kind: .markdown
            )
        }
    }

    /// The complaint this exists for: a note opened once today sat below
    /// notes opened often last week, so the one just made was the one the
    /// switcher could not find.
    @Test("A note opened once just now leads, ahead of the heavily used")
    func recentLeads() {
        let byUse = notes(["Daily", "Thesis", "Inbox", "New"])
        let arranged = QuickOpenOrder(lead: .recent, count: 2).arrange(
            byUse, recent: ["New.md", "Daily.md", "Inbox.md"], limit: 60, isUsed: { _ in true }
        )
        #expect(arranged.lead.map(\.name) == ["New", "Daily"])
        #expect(arranged.rest.map(\.name) == ["Thesis", "Inbox"], "the rest keeps the use order")
        #expect(arranged.heading == .recent)
        #expect(arranged.restHeading == .frequent, "the rest is named after its own order")
    }

    /// "Recent" is when a note was opened; "Last edited" is when its file
    /// was written, so a note only read stays where its last change put it.
    @Test("A plain sort lists every note once, by name or by last edit, without headings")
    func plainSorts() {
        let byUse = notes(["Note 10", "beta", "Note 2", "Alpha"])
        let alphabetical = QuickOpenOrder.standard.with(mode: .alphabetical).arrange(
            byUse, recent: ["beta.md"], limit: 60, isUsed: { _ in true }
        )
        #expect(alphabetical.all.map(\.name) == ["Alpha", "beta", "Note 2", "Note 10"])
        #expect(alphabetical.heading == nil && alphabetical.lead.isEmpty)

        let edits: [String: Date] = [
            "Note 2": Date(timeIntervalSince1970: 300), "Alpha": Date(timeIntervalSince1970: 100),
            "beta": Date(timeIntervalSince1970: 200),
        ]
        let lastEdited = QuickOpenOrder.standard.with(mode: .lastEdited).arrange(
            byUse, recent: ["Alpha.md"], limit: 3, isUsed: { _ in true }, edited: { edits[$0.name] }
        )
        #expect(lastEdited.all.map(\.name) == ["Note 2", "beta", "Alpha"], "undated last, and cut at the limit")
        #expect(lastEdited.heading == nil)
    }

    @Test("No note is listed twice")
    func noDuplicates() {
        let byUse = notes(["A", "B", "C"])
        for lead in QuickOpenOrder.Lead.allCases {
            let all = QuickOpenOrder(lead: lead, count: 2).arrange(
                byUse, recent: ["C.md", "A.md"], limit: 60, isUsed: { _ in true }
            ).all.map(\.name)
            #expect(all.count == Set(all).count, "\(lead): \(all)")
            #expect(Set(all) == ["A", "B", "C"], "\(lead): every note is still listed")
        }
    }

    /// Frequent first, then by when last opened: the order Obsidian uses
    /// for its whole list, below a block of what is used most.
    @Test("Frequent leads with used notes only, then the rest by when opened")
    func frequentLeads() {
        let byUse = notes(["Thesis", "Daily", "Alpha", "Beta", "Zulu"])
        let used: Set = ["Thesis", "Daily"]
        let arranged = QuickOpenOrder(lead: .frequent, count: 5).arrange(
            byUse, recent: ["Zulu.md", "Daily.md", "Beta.md"], limit: 60,
            isUsed: { used.contains($0.name) }
        )
        // Five asked for, two used: the block is not padded alphabetically.
        #expect(arranged.lead.map(\.name) == ["Thesis", "Daily"])
        #expect(arranged.rest.map(\.name) == ["Zulu", "Beta", "Alpha"])
        #expect(arranged.heading == .frequent)
        #expect(arranged.restHeading == .recent)
    }

    /// Zero turns the block off and gives back the order there was before.
    @Test("A count of zero is the plain use order, without a heading")
    func zeroIsOff() {
        let byUse = notes(["Thesis", "Daily", "New"])
        let arranged = QuickOpenOrder(lead: .recent, count: 0).arrange(
            byUse, recent: ["New.md"], limit: 60, isUsed: { _ in true }
        )
        #expect(arranged.all == byUse)
        #expect(arranged.heading == nil)
    }

    /// The recent history is vault-wide and outlives deletions; the list it
    /// feeds is scoped and current.
    @Test("A recent path that is not listable is skipped, not shown")
    func unknownRecentsAreSkipped() {
        let byUse = notes(["Draft", "Outline"])
        let arranged = QuickOpenOrder(lead: .recent, count: 2).arrange(
            byUse, recent: ["Home/List.md", "Deleted.md", "Outline.md"], limit: 60,
            isUsed: { _ in true }
        )
        #expect(arranged.lead.map(\.name) == ["Outline"])
        #expect(arranged.rest.map(\.name) == ["Draft"])
    }

    @Test("The limit covers both parts, and a block with nothing after it has no heading")
    func limitAndHeading() {
        let byUse = notes(["A", "B", "C", "D"])
        let cut = QuickOpenOrder(lead: .recent, count: 2).arrange(
            byUse, recent: ["D.md", "C.md"], limit: 3, isUsed: { _ in true }
        )
        #expect(cut.all.map(\.name) == ["D", "C", "A"])

        let alone = QuickOpenOrder(lead: .recent, count: 5).arrange(
            notes(["A", "B"]), recent: ["B.md", "A.md"], limit: 60, isUsed: { _ in true }
        )
        #expect(alone.rest.isEmpty)
        #expect(alone.heading == nil, "a heading over the whole list says nothing")
    }

    // MARK: - Headings as rows

    /// Headings are rows the arrows reach, but the list still opens on a
    /// note, so Return straight away opens what is at the top.
    @Test("Both headings are rows, and the selection starts on the first note")
    func headingRows() {
        let byUse = notes(["Thesis", "Daily", "New"])
        let arranged = QuickOpenOrder(lead: .recent, count: 1).arrange(
            byUse, recent: ["New.md"], limit: 60, isUsed: { _ in true }
        )
        let n = byUse.reduce(into: [String: NoteRef]()) { $0[$1.name] = $1 }
        #expect(arranged.rows == [
            .heading(.recent), .note(n["New"]!),
            .heading(.frequent), .note(n["Thesis"]!), .note(n["Daily"]!),
        ])
        #expect(arranged.firstNoteRow == 1)

        let plain = QuickOpenOrder(lead: .recent, count: 0).arrange(
            byUse, recent: ["New.md"], limit: 60, isUsed: { _ in true }
        )
        #expect(plain.rows == byUse.map(QuickOpenOrder.Row.note))
        #expect(plain.firstNoteRow == 0)
    }

    /// A chosen heading lists its order in full, not capped at the block.
    @Test("A section lists its whole order: the history, or every used note")
    func sections() {
        let byUse = notes(["Thesis", "Daily", "Alpha", "Beta"])
        let used: Set = ["Thesis", "Daily"]
        let recent = QuickOpenOrder.section(
            .recent, of: byUse, recent: ["Beta.md", "Gone.md", "Thesis.md", "Alpha.md"],
            limit: 100, isUsed: { used.contains($0.name) }
        )
        #expect(recent.map(\.name) == ["Beta", "Thesis", "Alpha"])
        let frequent = QuickOpenOrder.section(
            .frequent, of: byUse, recent: [], limit: 100, isUsed: { used.contains($0.name) }
        )
        #expect(frequent.map(\.name) == ["Thesis", "Daily"])
    }

    // MARK: - Storage

    private func suite() throws -> UserDefaults {
        let name = "dev.stenglein.Heft.quickopen-test-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("Nothing stored reads as five recent notes")
    func defaultsToFiveRecent() throws {
        #expect(QuickOpenOrder.current(in: try suite()) == QuickOpenOrder(lead: .recent, count: 5))
    }

    @Test("A stored order reads back, zero included")
    func roundTrip() throws {
        let defaults = try suite()
        QuickOpenOrder(lead: .frequent, count: 0).save(in: defaults)
        #expect(QuickOpenOrder.current(in: defaults) == QuickOpenOrder(lead: .frequent, count: 0))
    }

    @Test("A count outside the range is clamped, and an unknown lead falls back")
    func clampsAndFallsBack() throws {
        #expect(QuickOpenOrder(lead: .recent, count: 99).count == QuickOpenOrder.countRange.upperBound)
        #expect(QuickOpenOrder(lead: .recent, count: -3).count == 0)
        let defaults = try suite()
        defaults.set("pinned", forKey: QuickOpenOrder.leadKey)
        defaults.set(7, forKey: QuickOpenOrder.countKey)
        #expect(QuickOpenOrder.current(in: defaults) == QuickOpenOrder(lead: .recent, count: 7))
    }
}
