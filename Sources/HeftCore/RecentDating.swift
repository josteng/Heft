import Foundation

/// Where a note falls in a list grouped by when it was last written: finer
/// for this week, coarser the further back, the way Notes groups its list.
public enum RecentSection: Hashable, Sendable {
    case today
    case yesterday
    case previousSevenDays
    case previousThirtyDays
    /// A month of the current year, 1 through 12.
    case month(Int)
    /// A whole earlier year.
    case year(Int)
}

/// Dates for the Recent list: which section a note belongs to and what its
/// row says. Built with a calendar, a locale and a `now` so the answers can
/// be checked; the sidebar builds one per draw with the defaults.
public struct RecentDating: Sendable {
    public let calendar: Calendar
    public let locale: Locale
    public let now: Date

    public init(calendar: Calendar = .current, locale: Locale = .current, now: Date = Date()) {
        self.calendar = calendar
        self.locale = locale
        self.now = now
    }

    private var startOfToday: Date { calendar.startOfDay(for: now) }

    private func daysBack(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday
    }

    public func section(for date: Date) -> RecentSection {
        // A date in the future, from a clock that was wrong, is still "today":
        // nothing above today would make sense to a reader.
        if date >= startOfToday { return .today }
        if date >= daysBack(1) { return .yesterday }
        if date >= daysBack(7) { return .previousSevenDays }
        if date >= daysBack(30) { return .previousThirtyDays }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return .month(calendar.component(.month, from: date))
        }
        return .year(year)
    }

    public func title(of section: RecentSection) -> String {
        switch section {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previousSevenDays: return "Previous 7 Days"
        case .previousThirtyDays: return "Previous 30 Days"
        case .month(let month):
            var named = calendar
            named.locale = locale
            return named.monthSymbols[max(0, min(month - 1, 11))]
        case .year(let year): return String(year)
        }
    }

    /// What the row says beside the preview: the time for today, the day's
    /// name within the week, the date beyond that. What a reader can place
    /// at a glance, no more.
    public func label(for date: Date) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch section(for: date) {
        case .today: return date.formatted(style.hour().minute())
        case .yesterday: return "Yesterday"
        case .previousSevenDays: return date.formatted(style.weekday(.wide))
        // Two digits each, as Notes writes it: the numeric style leaves the
        // day and month unpadded in some locales, and a column of dates
        // then no longer lines up.
        default: return date.formatted(style.year().month(.twoDigits).day(.twoDigits))
        }
    }

    /// Consecutive runs of `items` that share a section. The items are
    /// expected newest first; ones without a date form a final run with no
    /// section, so a note the index never read still appears.
    public func grouped<Item>(_ items: [Item], date: (Item) -> Date?) -> [(section: RecentSection?, items: [Item])] {
        var groups: [(section: RecentSection?, items: [Item])] = []
        for item in items {
            let section = date(item).map(section(for:))
            if let last = groups.indices.last, groups[last].section == section {
                groups[last].items.append(item)
            } else {
                groups.append((section, [item]))
            }
        }
        return groups
    }
}
