import HeftCore
import SwiftUI

/// Month grid over the vault's daily notes. A filled dot means the note
/// exists; clicking an empty day creates it from the configured template.
struct CalendarPanel: View {
    @EnvironmentObject private var model: AppModel

    /// ISO calendar so weeks start on Monday, matching the vault's `YYYY-[W]WW`
    /// weekly notes.
    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayLabels
            grid
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)

            Spacer()
            // Doubles as the way back to the current month, which is what the
            // removed Today button was mostly used for. ⇧⌘T opens the note.
            Button { goToCurrentMonth() } label: {
                Text(MomentFormat.format(model.calendarMonth, pattern: "MMMM YYYY"))
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .help("Jump to this month")

            if model.settings.dailyNoteTemplate == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("No daily-note template configured in this vault; new notes get a plain heading.")
            }
            Spacer()

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
    }

    private var weekdayLabels: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days) { day in
                DayCell(
                    date: day.date,
                    isToday: calendar.isDateInToday(day.date),
                    isSelected: isOpen(day.date),
                    hasNote: hasNote(day.date),
                    isOutsideMonth: !day.isInMonth
                ) {
                    open(day)
                }
            }
        }
    }

    // MARK: - Data

    private struct CalendarDay: Identifiable {
        let date: Date
        /// False for the neighbouring months' days that pad the grid.
        let isInMonth: Bool
        var id: Date { date }
    }

    /// Always six weeks.
    ///
    /// Padding with blanks made the panel change height between a month that
    /// needs five rows and one that needs six, which moved the whole sidebar.
    /// Filling the edges with the neighbouring months' days instead, dimmed,
    /// keeps the height fixed and is what Obsidian and Calendar.app do.
    private var days: [CalendarDay] {
        guard let interval = calendar.dateInterval(of: .month, for: model.calendarMonth) else { return [] }
        let first = interval.start
        // weekday is 1=Sunday; shift so Monday is 0.
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: first) else { return [] }

        let month = calendar.component(.month, from: first)
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return CalendarDay(
                date: date, isInMonth: calendar.component(.month, from: date) == month
            )
        }
    }

    /// Opening a padding day follows it into its own month, so the grid does
    /// not end up showing a selected day that is not really part of it.
    private func open(_ day: CalendarDay) {
        if !day.isInMonth {
            withAnimation(.snappy(duration: 0.18)) { model.calendarMonth = day.date }
        }
        model.openDailyNote(for: day.date)
    }

    private func goToCurrentMonth() {
        withAnimation(.snappy(duration: 0.18)) { model.calendarMonth = Date() }
    }

    private var weekdaySymbols: [String] {
        // Monday-first, two letters, matching the ISO grid above.
        ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    }

    /// Checked against the in-memory index rather than the filesystem: this
    /// runs for every visible day on every redraw.
    private func hasNote(_ date: Date) -> Bool {
        guard let daily = model.dailyNotes else { return false }
        return model.index.note(atRelativePath: daily.relativePath(for: date)) != nil
    }

    private func isOpen(_ date: Date) -> Bool {
        guard let daily = model.dailyNotes, let current = model.current else { return false }
        return daily.relativePath(for: date).lowercased() == current.relativePath.lowercased()
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: model.calendarMonth) else { return }
        withAnimation(.snappy(duration: 0.18)) { model.calendarMonth = shifted }
    }
}

private struct DayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let hasNote: Bool
    var isOutsideMonth = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(MomentFormat.format(date, pattern: "D"))
                    .font(.system(size: 10, weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isOutsideMonth ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
                Circle()
                    .fill(hasNote ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                    // A padding day's note still gets a dot, but a faint one:
                    // it belongs to a month that is not on screen.
                    .opacity(isOutsideMonth ? 0.4 : 1)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(MomentFormat.format(date, pattern: "dddd, MMMM Do YYYY"))
    }
}
