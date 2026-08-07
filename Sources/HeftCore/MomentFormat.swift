import Foundation

/// Formats dates with moment.js tokens, which is the syntax Obsidian uses in
/// daily-note filename formats and `{{date:...}}` template placeholders.
///
/// This deliberately does not delegate to `DateFormatter`. Several moment
/// tokens collide with ICU tokens that mean something *different*, so handing
/// an Obsidian pattern to DateFormatter yields a plausible-looking wrong date
/// instead of an error:
///
///   - moment `DD` is day-of-month; ICU `DD` is day-of-year.
///   - moment `WW` is the ISO week;  ICU `WW` is week-of-month.
///   - moment escapes literals with `[W]`; ICU uses `'W'`.
///
/// The vault's own template relies on all three (`{{date:YYYY-[W]WW}}`), so the
/// distinction is load-bearing rather than academic.
public enum MomentFormat {

    /// Obsidian formats with moment's default locale (English) unless the user
    /// installs a locale override. Matching that keeps generated weekday names
    /// consistent with notes already in the vault, regardless of system region.
    public static let defaultLocale = Locale(identifier: "en_US_POSIX")

    public static func format(
        _ date: Date,
        pattern: String,
        locale: Locale = defaultLocale,
        timeZone: TimeZone = .current
    ) -> String {
        let ctx = Context(date: date, locale: locale, timeZone: timeZone)
        var out = ""
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let ch = pattern[i]

            // moment escapes literal text in square brackets: [W] -> "W"
            if ch == "[" {
                if let close = pattern[i...].firstIndex(of: "]") {
                    out += pattern[pattern.index(after: i)..<close]
                    i = pattern.index(after: close)
                    continue
                }
                // Unterminated bracket: emit it literally rather than dropping input.
                out.append(ch)
                i = pattern.index(after: i)
                continue
            }

            if let (token, value) = matchToken(pattern, at: i, ctx: ctx) {
                out += value
                i = pattern.index(i, offsetBy: token.count)
                continue
            }

            out.append(ch)
            i = pattern.index(after: i)
        }
        return out
    }

    /// Replaces `{{date:FMT}}`, `{{time:FMT}}`, `{{date}}`, `{{time}}` and
    /// `{{title}}` in a template body. Obsidian also allows `{{date+3d:FMT}}`
    /// style offsets; those are intentionally not supported yet and are left
    /// untouched so nothing is silently mangled.
    public static func expandTemplate(
        _ template: String,
        date: Date,
        title: String,
        dateFormat: String = "YYYY-MM-DD",
        timeFormat: String = "HH:mm",
        locale: Locale = defaultLocale,
        timeZone: TimeZone = .current
    ) -> String {
        var result = ""
        var rest = Substring(template)

        while let open = rest.range(of: "{{") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                result += rest[open.lowerBound...]
                return result
            }

            let body = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += substitute(
                body, date: date, title: title,
                dateFormat: dateFormat, timeFormat: timeFormat,
                locale: locale, timeZone: timeZone
            ) ?? "{{\(body)}}"

            rest = rest[close.upperBound...]
        }

        result += rest
        return result
    }

    private static func substitute(
        _ body: String, date: Date, title: String,
        dateFormat: String, timeFormat: String,
        locale: Locale, timeZone: TimeZone
    ) -> String? {
        let (name, arg) = splitOnce(body, separator: ":")
        switch name.lowercased() {
        case "title":
            return title
        case "date":
            return format(date, pattern: arg ?? dateFormat, locale: locale, timeZone: timeZone)
        case "time":
            return format(date, pattern: arg ?? timeFormat, locale: locale, timeZone: timeZone)
        default:
            return nil  // Unknown placeholder: caller re-emits it verbatim.
        }
    }

    private static func splitOnce(_ s: String, separator: Character) -> (String, String?) {
        guard let idx = s.firstIndex(of: separator) else { return (s, nil) }
        return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
    }

    // MARK: - Token resolution

    private static func matchToken(_ pattern: String, at i: String.Index, ctx: Context) -> (String, String)? {
        // Longest-first so `DDDD` wins over `DDD`, and `MMMM` over `MM`.
        for token in sortedTokens {
            guard pattern[i...].hasPrefix(token) else { continue }
            return (token, ctx.value(for: token))
        }
        return nil
    }

    private static let sortedTokens: [String] = [
        "YYYY", "YY", "GGGG", "GG",
        "MMMM", "MMM", "MM", "M",
        "DDDD", "DDD", "DD", "Do", "D",
        "dddd", "ddd", "dd", "d",
        "WW", "W", "ww", "w",
        "HH", "H", "hh", "h",
        "mm", "m", "ss", "s", "SSS",
        "A", "a", "X", "x",
    ].sorted { $0.count > $1.count }

    // MARK: - Context

    private struct Context {
        let date: Date
        let locale: Locale
        let comps: DateComponents
        let symbols: Symbols

        init(date: Date, locale: Locale, timeZone: TimeZone) {
            self.date = date
            self.locale = locale
            // ISO-8601 calendar: Monday-first with a 4-day first week, which is
            // what moment's W/WW/GGGG report.
            var cal = Calendar(identifier: .iso8601)
            cal.timeZone = timeZone
            cal.locale = locale
            self.comps = cal.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .nanosecond,
                 .weekday, .weekOfYear, .yearForWeekOfYear, .dayOfYear],
                from: date
            )
            self.symbols = Symbols(locale: locale)
        }

        func value(for token: String) -> String {
            let year = comps.year ?? 0
            let month = comps.month ?? 1
            let day = comps.day ?? 1
            let hour24 = comps.hour ?? 0
            let weekdayIndex = (comps.weekday ?? 1) - 1  // 0 = Sunday

            switch token {
            case "YYYY": return pad(year, 4)
            case "YY":   return pad(abs(year) % 100, 2)
            case "GGGG": return pad(comps.yearForWeekOfYear ?? year, 4)
            case "GG":   return pad(abs(comps.yearForWeekOfYear ?? year) % 100, 2)

            case "MMMM": return symbols.months[safe: month - 1] ?? ""
            case "MMM":  return symbols.shortMonths[safe: month - 1] ?? ""
            case "MM":   return pad(month, 2)
            case "M":    return String(month)

            case "DDDD": return pad(comps.dayOfYear ?? 0, 3)
            case "DDD":  return String(comps.dayOfYear ?? 0)
            case "DD":   return pad(day, 2)
            case "Do":   return ordinal(day)
            case "D":    return String(day)

            case "dddd": return symbols.weekdays[safe: weekdayIndex] ?? ""
            case "ddd":  return symbols.shortWeekdays[safe: weekdayIndex] ?? ""
            case "dd":   return symbols.minWeekdays[safe: weekdayIndex] ?? ""
            case "d":    return String(weekdayIndex)

            // moment's w/ww are locale-week; Obsidian users overwhelmingly mean
            // the ISO week, and the ISO calendar is what we computed against.
            case "WW", "ww": return pad(comps.weekOfYear ?? 0, 2)
            case "W", "w":   return String(comps.weekOfYear ?? 0)

            case "HH": return pad(hour24, 2)
            case "H":  return String(hour24)
            case "hh": return pad(hour12(hour24), 2)
            case "h":  return String(hour12(hour24))
            case "mm": return pad(comps.minute ?? 0, 2)
            case "m":  return String(comps.minute ?? 0)
            case "ss": return pad(comps.second ?? 0, 2)
            case "s":  return String(comps.second ?? 0)
            case "SSS": return pad((comps.nanosecond ?? 0) / 1_000_000, 3)

            case "A": return hour24 < 12 ? "AM" : "PM"
            case "a": return hour24 < 12 ? "am" : "pm"
            case "X": return String(Int(date.timeIntervalSince1970))
            case "x": return String(Int(date.timeIntervalSince1970 * 1000))

            default: return token
            }
        }

        private func hour12(_ h: Int) -> Int {
            let m = h % 12
            return m == 0 ? 12 : m
        }

        private func pad(_ value: Int, _ width: Int) -> String {
            let negative = value < 0
            var s = String(abs(value))
            while s.count < width { s = "0" + s }
            return negative ? "-" + s : s
        }

        private func ordinal(_ n: Int) -> String {
            // English ordinals; 11/12/13 are the exceptions to the 1st/2nd/3rd rule.
            let suffix: String
            switch (n % 100, n % 10) {
            case (11, _), (12, _), (13, _): suffix = "th"
            case (_, 1): suffix = "st"
            case (_, 2): suffix = "nd"
            case (_, 3): suffix = "rd"
            default: suffix = "th"
            }
            return "\(n)\(suffix)"
        }
    }

    private struct Symbols {
        let months: [String]
        let shortMonths: [String]
        let weekdays: [String]
        let shortWeekdays: [String]
        let minWeekdays: [String]

        init(locale: Locale) {
            let df = DateFormatter()
            df.locale = locale
            months = df.standaloneMonthSymbols ?? []
            shortMonths = df.shortStandaloneMonthSymbols ?? []
            weekdays = df.standaloneWeekdaySymbols ?? []
            shortWeekdays = df.shortStandaloneWeekdaySymbols ?? []
            // moment's `dd` is a two-letter weekday; DateFormatter's "very short"
            // symbols are one letter, so derive rather than use them directly.
            minWeekdays = (df.standaloneWeekdaySymbols ?? []).map { String($0.prefix(2)) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
