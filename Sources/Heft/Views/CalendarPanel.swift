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
            footer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)

            Spacer()
            Text(MomentFormat.format(model.calendarMonth, pattern: "MMMM YYYY"))
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.numericText())
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
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(
                        date: day,
                        isToday: calendar.isDateInToday(day),
                        isSelected: isOpen(day),
                        hasNote: hasNote(day)
                    ) {
                        model.openDailyNote(for: day)
                    }
                } else {
                    Color.clear.frame(height: 22)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Today") {
                model.calendarMonth = Date()
                model.openDailyNote(for: Date())
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)

            if model.settings.dailyNoteTemplate == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("No daily-note template configured in this vault; new notes get a plain heading.")
            }
            Spacer()
        }
    }

    // MARK: - Data

    /// Leading `nil`s pad the grid so the first day lands under its weekday.
    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: model.calendarMonth) else { return [] }
        let first = interval.start
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        // weekday is 1=Sunday; shift so Monday is 0.
        let leading = (calendar.component(.weekday, from: first) + 5) % 7

        var result: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            result.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        return result
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(MomentFormat.format(date, pattern: "D"))
                    .font(.system(size: 10, weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                Circle()
                    .fill(hasNote ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
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
