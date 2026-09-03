import Foundation

/// Which day a week starts on in the calendar grid.
///
/// `.system` rather than a fixed default: the grid used to be hard-wired to
/// ISO (Monday), which is right for a German vault and wrong for an American
/// one, and neither of them should have to find a setting to get the layout
/// their operating system already knows they want.
public enum FirstWeekday: String, CaseIterable, Sendable, Identifiable {
    case system
    case monday
    case sunday
    case saturday

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .monday: return "Monday"
        case .sunday: return "Sunday"
        case .saturday: return "Saturday"
        }
    }

    /// `Calendar.firstWeekday` numbering: 1 is Sunday through 7 is Saturday.
    /// Nil follows the current locale.
    public var weekdayIndex: Int? {
        switch self {
        case .system: return nil
        case .sunday: return 1
        case .monday: return 2
        case .saturday: return 7
        }
    }

    public func resolved(locale: Locale = .current) -> Int {
        weekdayIndex ?? Calendar(identifier: .gregorian).firstWeekdayForLocale(locale)
    }
}

extension Calendar {
    fileprivate func firstWeekdayForLocale(_ locale: Locale) -> Int {
        var calendar = self
        calendar.locale = locale
        return calendar.firstWeekday
    }
}

/// The pure arithmetic behind the month grid.
///
/// Separated from the view because "which column does the 1st fall in" is
/// exactly the kind of off-by-one that is invisible until a month starts on a
/// Sunday, and it is far cheaper to assert than to notice.
public enum WeekLayout {
    /// The two-letter column headings, rotated to start on `firstWeekday`.
    ///
    /// Written out rather than taken from `DateFormatter.shortWeekdaySymbols`
    /// so they stay two characters wide in a 7-column grid that is only about
    /// 200pt across, and so they agree with the English day names
    /// `MomentFormat` produces everywhere else in the app.
    public static func symbols(firstWeekday: Int) -> [String] {
        let sundayFirst = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let offset = wrapped(firstWeekday - 1)
        return (0..<7).map { sundayFirst[($0 + offset) % 7] }
    }

    /// How many days of the previous month pad the grid before the 1st.
    ///
    /// - Parameters:
    ///   - firstOfMonth: `Calendar.component(.weekday,)` of the 1st, 1 = Sunday.
    ///   - firstWeekday: the day the week starts on, same numbering.
    public static func leadingDays(firstOfMonth: Int, firstWeekday: Int) -> Int {
        wrapped(firstOfMonth - firstWeekday)
    }
}

/// Euclidean remainder over a week. Swift's `%` keeps the sign of the
/// dividend, so `(1 - 7) % 7` is -6 where the column index wanted is 1.
private func wrapped(_ value: Int) -> Int {
    let remainder = value % 7
    return remainder < 0 ? remainder + 7 : remainder
}
