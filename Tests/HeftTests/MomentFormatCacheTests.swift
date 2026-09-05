import Foundation
import Testing
@testable import HeftCore

/// The formatter keeps one symbol table per locale instead of building a
/// `DateFormatter` on every call. The cache has to be keyed by the locale, or
/// the first locale asked for would name every month from then on.
@Suite("Moment format symbol cache")
struct MomentFormatCacheTests {
    private let date = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01, a Monday
    private let utc = TimeZone(identifier: "UTC")!

    @Test("Symbols follow the locale asked for, not the one asked for first")
    func symbolsAreKeyedByLocale() {
        let english = Locale(identifier: "en_US_POSIX")
        let german = Locale(identifier: "de_DE")
        #expect(MomentFormat.format(date, pattern: "MMMM dddd", locale: english, timeZone: utc) == "January Monday")
        #expect(MomentFormat.format(date, pattern: "MMMM dddd", locale: german, timeZone: utc) == "Januar Montag")
        #expect(MomentFormat.format(date, pattern: "MMM ddd dd", locale: english, timeZone: utc) == "Jan Mon Mo")
        #expect(MomentFormat.format(date, pattern: "MMM ddd dd", locale: german, timeZone: utc) == "Jan Mo Mo")
    }
}
