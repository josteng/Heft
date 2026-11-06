import Foundation
import Testing
@testable import HeftCore

/// A capture into an inbox whose note opens with frontmatter. A new day's
/// section went above the `---` block, and Obsidian then read no properties.
@Suite("Inbox captures and frontmatter")
struct InboxFrontmatterTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test("Inbox with frontmatter: a new day keeps the frontmatter first")
    func frontmatterStaysFirst() throws {
        let inbox = "---\ntags: [inbox]\n---\n# Inbox\n\n## 2026-11-05\n- 09:00 old\n"
        let out = try InboxCapture.contents(byCapturing: "new", in: inbox, at: moment(6, 10), calendar: utc)
        #expect(out.hasPrefix("---\n"), "got: \(out)")
    }

    @Test("Inbox with frontmatter and CRLF: new day keeps the frontmatter first")
    func frontmatterCRLF() throws {
        let inbox = "---\r\ntags: [inbox]\r\n---\r\n\r\n## 2026-11-05\r\n- 09:00 old\r\n"
        let out = try InboxCapture.contents(byCapturing: "new", in: inbox, at: moment(6, 10), calendar: utc)
        #expect(out.hasPrefix("---\r\n"), "got: \(out.debugDescription)")
    }

    @Test("Late capture for a new past day with frontmatter YAML comment")
    func yamlComment() throws {
        let inbox = "---\n# a yaml comment\ntags: [x]\n---\n# Inbox\n\n## 2026-11-06\n- 09:00 a\n\n## 2026-11-03\n- 09:00 b\n"
        let out = try InboxCapture.contents(byCapturing: "late", in: inbox, at: moment(4, 10), calendar: utc, inTimeOrder: true)
        #expect(out.hasPrefix("---\n# a yaml comment\ntags: [x]\n---\n# Inbox\n"), "got: \(out)")
        #expect(out.contains("## 2026-11-04\n- 10:00 late"), "got: \(out)")
    }

    @Test("CRLF inbox, late capture into an existing day")
    func crlfLate() throws {
        let inbox = "# Inbox\r\n\r\n## 2026-11-06\r\n- 12:00 a\r\n- 08:00 b\r\n"
        let out = try InboxCapture.contents(byCapturing: "late", in: inbox, at: moment(6, 10), calendar: utc, inTimeOrder: true)
        #expect(out == "# Inbox\r\n\r\n## 2026-11-06\r\n- 12:00 a\r\n- 10:00 late\r\n- 08:00 b\r\n", "got: \(out.debugDescription)")
    }

    @Test("CRLF daily, late capture")
    func crlfDaily() throws {
        let note = "# D\r\n\r\n- 08:00 a\r\n- 12:00 b\r\n"
        let out = try DailyNoteCapture.contents(byCapturing: "late", in: note, at: moment(6, 10), calendar: utc, inTimeOrder: true)
        #expect(out == "# D\r\n\r\n- 08:00 a\r\n- 10:00 late\r\n- 12:00 b\r\n", "got: \(out.debugDescription)")
    }

    @Test("Multi-line capture in a CRLF inbox keeps CRLF")
    func crlfMultiline() throws {
        let inbox = "# Inbox\r\n\r\n## 2026-11-06\r\n- 12:00 a\r\n"
        let out = try InboxCapture.contents(byCapturing: "one\ntwo", in: inbox, at: moment(6, 13), calendar: utc)
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "got: \(out.debugDescription)")
    }
}
