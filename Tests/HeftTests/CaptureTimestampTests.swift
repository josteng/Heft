import Foundation
import HeftCore
import Testing

/// Whether a captured line carries the time it arrived. One answer for both
/// captures, because both write the same kind of line.
@Suite("Capture timestamps")
struct CaptureTimestampTests {

    private let noon = Date(timeIntervalSince1970: 1_757_160_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! #require(TimeZone(identifier: "UTC"))
        return calendar
    }

    private func suite() throws -> UserDefaults {
        let name = "dev.stenglein.Heft.timestamp-test-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    // MARK: - The setting

    @Test("A store nobody has written to stamps the time")
    func onByDefault() throws {
        // Every capture has done this until now, so absent must mean on.
        let defaults = try suite()
        #expect(CaptureTimestampPreference.isOn(in: defaults))
    }

    @Test("Turning it off is remembered, and turning it back on")
    func remembersTheChoice() throws {
        let defaults = try suite()
        CaptureTimestampPreference.set(false, in: defaults)
        #expect(!CaptureTimestampPreference.isOn(in: defaults))
        CaptureTimestampPreference.set(true, in: defaults)
        #expect(CaptureTimestampPreference.isOn(in: defaults))
    }

    // MARK: - The inbox

    @Test("An inbox capture carries the time when it is on")
    func inboxStamps() throws {
        let written = try InboxCapture.contents(
            byCapturing: "a thought", in: "", at: noon, calendar: utc, timestamped: true
        )
        #expect(written.contains("- 12:00 a thought"))
    }

    @Test("An inbox capture is a plain item when it is off")
    func inboxWithoutATime() throws {
        let written = try InboxCapture.contents(
            byCapturing: "a thought", in: "", at: noon, calendar: utc, timestamped: false
        )
        #expect(written.contains("- a thought"))
        #expect(!written.contains("12:00"))
        // Not `-  a thought`: the second space would read as indentation to a
        // Markdown parser, which is a different list.
        #expect(!written.contains("-  "))
    }

    @Test("The day heading stays whether or not the time does")
    func theDayHeadingSurvives() throws {
        // The date is how an inbox stays readable; only the time is optional.
        let written = try InboxCapture.contents(
            byCapturing: "a thought", in: "", at: noon, calendar: utc, timestamped: false
        )
        #expect(written.contains("## 2025-09-06"))
    }

    // MARK: - Today's note

    @Test("A daily capture carries the time when it is on")
    func dailyStamps() throws {
        let written = try DailyNoteCapture.contents(
            byCapturing: "a thought", in: "# Tuesday\n", at: noon, calendar: utc,
            timestamped: true
        )
        #expect(written.contains("- 12:00 a thought"))
    }

    @Test("A daily capture is a plain item when it is off")
    func dailyWithoutATime() throws {
        let written = try DailyNoteCapture.contents(
            byCapturing: "a thought", in: "# Tuesday\n", at: noon, calendar: utc,
            timestamped: false
        )
        #expect(written.contains("- a thought"))
        #expect(!written.contains("12:00"))
        #expect(!written.contains("-  "))
    }

    @Test("A continuation line keeps its indent either way")
    func continuationsAreUntouched() throws {
        for stamped in [true, false] {
            let written = try DailyNoteCapture.contents(
                byCapturing: "first\nsecond", in: "# Tuesday\n", at: noon, calendar: utc,
                timestamped: stamped
            )
            #expect(written.contains("  second"), Comment(rawValue: "stamped: \(stamped)"))
        }
    }
}
