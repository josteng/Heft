import Foundation
import Testing
@testable import HeftCore

/// A capture filed after the fact, from `--at` or a share queued on the
/// phone, lands in the inbox where it would have landed had it been
/// captured then: under its own day, among the days newest first, and
/// among that day's items newest first.
@Suite("Inbox time order")
struct InboxTimeOrderTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! #require(TimeZone(identifier: "UTC"))
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func late(
        _ inbox: String, _ at: Date, timestamped: Bool = true, text: String = "late"
    ) throws -> String {
        try InboxCapture.contents(
            byCapturing: text, in: inbox, at: at, calendar: utc,
            timestamped: timestamped, inTimeOrder: true)
    }

    private let days = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n\n## 2026-10-17\n- 10:00 b\n"

    @Test("A past day with no heading gets one between the days around it")
    func newDayBetweenDays() throws {
        #expect(try late(days, moment(18, 12)) == """
            # Inbox

            ## 2026-10-20
            - 09:00 a

            ## 2026-10-18
            - 12:00 late

            ## 2026-10-17
            - 10:00 b

            """)
    }

    @Test("Days with no blank line between them still get one around the new day")
    func newDayBetweenTightDays() throws {
        let tight = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n## 2026-10-17\n- 10:00 b\n"
        #expect(try late(tight, moment(18, 12)) == tight.replacingOccurrences(
            of: "## 2026-10-17\n", with: "\n## 2026-10-18\n- 12:00 late\n\n## 2026-10-17\n"))
    }

    @Test("A day older than every other goes last")
    func newDayAfterAllDays() throws {
        #expect(try late(days, moment(15, 8)) == days + "\n## 2026-10-15\n- 08:00 late\n")
        // Without a final line break the file still gets its blank line.
        #expect(try late(String(days.dropLast()), moment(15, 8))
            == days + "\n## 2026-10-15\n- 08:00 late\n")
    }

    @Test("A day newer than every other goes first, as any capture does")
    func newDayBeforeAllDays() throws {
        #expect(try late(days, moment(21, 8))
            == "# Inbox\n\n## 2026-10-21\n- 08:00 late\n\n" + days.dropFirst("# Inbox\n\n".count))
    }

    private let day = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n\n## 2026-10-18\n- 15:00 c\n- 09:00 d\n  more of d\n\n## 2026-10-17\n- 10:00 b\n"

    @Test("Into an existing day, between a later and an earlier item")
    func middleOfADay() throws {
        #expect(try late(day, moment(18, 12)) == day.replacingOccurrences(
            of: "- 15:00 c\n", with: "- 15:00 c\n- 12:00 late\n"))
    }

    @Test("Earlier than all of a day's items, after the last and its continuation")
    func endOfADay() throws {
        #expect(try late(day, moment(18, 8)) == day.replacingOccurrences(
            of: "  more of d\n", with: "  more of d\n- 08:00 late\n"))
        // The last day, at the very end of a file with no final break.
        let last = "# Inbox\n\n## 2026-10-18\n- 15:00 c"
        #expect(try late(last, moment(18, 8)) == last + "\n- 08:00 late")
    }

    @Test("Later than all of a day's items, at the top of it")
    func topOfADay() throws {
        #expect(try late(day, moment(18, 16)) == day.replacingOccurrences(
            of: "## 2026-10-18\n", with: "## 2026-10-18\n- 16:00 late\n"))
    }

    /// A live capture goes above the items already there at its minute,
    /// so a late one does too.
    @Test("Equal times go above the ones already there, as a live capture would")
    func equalTimes() throws {
        #expect(try late(day, moment(18, 9)) == day.replacingOccurrences(
            of: "- 15:00 c\n", with: "- 15:00 c\n- 09:00 late\n"))
        #expect(try late(day, moment(18, 15)) == day.replacingOccurrences(
            of: "## 2026-10-18\n", with: "## 2026-10-18\n- 15:00 late\n"))
    }

    @Test("Timestamps off: its own day still, at the top of it")
    func timestampsOff() throws {
        let plain = "# Inbox\n\n## 2026-10-20\n- a\n\n## 2026-10-17\n- b\n"
        #expect(try late(plain, moment(18, 12), timestamped: false)
            == "# Inbox\n\n## 2026-10-20\n- a\n\n## 2026-10-18\n- late\n\n## 2026-10-17\n- b\n")
        #expect(try late(day, moment(18, 8), timestamped: false) == day.replacingOccurrences(
            of: "## 2026-10-18\n", with: "## 2026-10-18\n- late\n"))
    }

    @Test("A CRLF inbox keeps its line breaks")
    func crlf() throws {
        let crlf = { (text: String) in text.replacingOccurrences(of: "\n", with: "\r\n") }
        #expect(try late(crlf(days), moment(18, 12)) == crlf(try late(days, moment(18, 12))))
        #expect(try late(crlf(day), moment(18, 12)) == crlf(try late(day, moment(18, 12))))
        #expect(try late(crlf(day), moment(18, 8)) == crlf(try late(day, moment(18, 8))))
        #expect(try late(crlf(days), moment(15, 8)) == crlf(try late(days, moment(15, 8))))
        let tight = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n## 2026-10-17\n- 10:00 b\n"
        #expect(try late(crlf(tight), moment(18, 12)) == crlf(try late(tight, moment(18, 12))))
    }

    @Test("A heading that is not a day is a boundary nothing moves across")
    func unknownHeadings() throws {
        let someday = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n\n## Someday\n- x\n\n## 2026-10-15\n- y\n"
        #expect(try late(someday, moment(18, 12)) == someday.replacingOccurrences(
            of: "## Someday\n", with: "## 2026-10-18\n- 12:00 late\n\n## Someday\n"))

        // Above every day, it leaves the late day where a capture goes.
        let pinned = "# Inbox\n\n## Pinned\n- x\n\n## 2026-10-20\n- 09:00 a\n"
        #expect(try late(pinned, moment(18, 12))
            == "# Inbox\n\n## 2026-10-18\n- 12:00 late\n\n## Pinned\n- x\n\n## 2026-10-20\n- 09:00 a\n")

        // A subheading belongs to the day above it, and is no boundary.
        let sub = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n### Links\n- x\n\n## 2026-10-15\n- y\n"
        #expect(try late(sub, moment(18, 12)) == sub.replacingOccurrences(
            of: "## 2026-10-15\n", with: "## 2026-10-18\n- 12:00 late\n\n## 2026-10-15\n"))
    }

    @Test("Headings and items inside a code block are neither")
    func codeBlocks() throws {
        // A day heading and a later time printed inside a fence.
        let fenced = "# Inbox\n\n## 2026-10-20\n- 09:00 a\n```\n## 2026-10-18\n- 23:00 printed\n```\n\n## 2026-10-17\n- 10:00 b\n"
        #expect(try late(fenced, moment(18, 12)) == fenced.replacingOccurrences(
            of: "## 2026-10-17\n", with: "## 2026-10-18\n- 12:00 late\n\n## 2026-10-17\n"))

        // A shell comment in a day's block does not end that day.
        let comment = "# Inbox\n\n## 2026-10-18\n- 15:00 c\n```sh\n# a comment\n```\n- 09:00 d\n"
        #expect(try late(comment, moment(18, 8)) == comment + "- 08:00 late\n")
    }

    /// Time order changes only where a capture lands among later lines,
    /// so a capture made now writes what it always has.
    @Test("A capture at the current time is unchanged, byte for byte")
    func nowIsUnchanged() throws {
        let inboxes = [
            "", "# Inbox\n", "# Inbox\n\n", days, day, "Older notes\n", "# Inbox\r\n\r\nOlder\r\n",
            "# Inbox\n\n## 2026-10-21\n- 08:00 x\n",
            "# Inbox\n\n## 2026-10-21\n- 23:00 x\n- 07:00 y\n",
            // An older layout, a blank line under the heading, that a capture tidies.
            "# Inbox\n\n## 2026-10-21\n\n- 08:00 x\n",
        ]
        let now = moment(21, 23, 30)
        for inbox in inboxes {
            for stamped in [true, false] {
                let ordered = try late(inbox, now, timestamped: stamped)
                let plain = try InboxCapture.contents(
                    byCapturing: "late", in: inbox, at: now, calendar: utc, timestamped: stamped)
                #expect(ordered == plain, "\(inbox.debugDescription)")
            }
        }
    }
}
