import HeftCore
import SwiftUI

/// A month of daily notes. A dot marks a day that has one; tapping a day
/// without one offers to make it from the daily template.
struct CalendarView: View {
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var offered: Date?
    @State private var problem: String?

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                grid
                Button {
                    open(Date())
                } label: {
                    Label("Today's Note", systemImage: "sun.max")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                monthNotes
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Calendar")
        .confirmationDialog(
            offered.map { "No note for \($0.formatted(date: .complete, time: .omitted))" } ?? "",
            isPresented: .constant(offered != nil), titleVisibility: .visible
        ) {
            Button("Create Note") {
                if let day = offered { open(day) }
                offered = nil
            }
            Button("Cancel", role: .cancel) { offered = nil }
        }
        .alert("Can't Open Daily Note", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let firstWeekday = calendar.firstWeekday
        let leading = WeekLayout.leadingDays(
            firstOfMonth: calendar.component(.weekday, from: month), firstWeekday: firstWeekday
        )
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        return LazyVGrid(columns: columns, spacing: 6) {
            // One sequence with ids of its own: separate ForEach loops over
            // the padding and the days reused ids 1 and 2, and the grid
            // silently dropped the first days of the month.
            ForEach(WeekLayout.symbols(firstWeekday: firstWeekday), id: \.self) {
                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(-leading..<days, id: \.self) { offset in
                if offset < 0 {
                    Color.clear.frame(height: 40)
                } else {
                    dayCell(calendar.date(byAdding: .day, value: offset, to: month)!)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let today = calendar.isDateInToday(date)
        let exists = existing(date) != nil
        return Button {
            if exists { open(date) } else { offered = date }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : .primary)
                    .frame(width: 34, height: 34)
                    .background(today ? Color.accentColor : .clear, in: .circle)
                Circle()
                    .fill(exists ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(exists ? "Has a note" : "")
    }

    /// The month's notes as a list too, which is where their names show.
    @ViewBuilder
    private var monthNotes: some View {
        let days = (calendar.range(of: .day, in: .month, for: month) ?? 1..<2).compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: month)
        }
        let notes = days.reversed().compactMap(existing)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(notes) { note in
                    NavigationLink(value: MobileRoute.note(note.relativePath)) {
                        HStack {
                            Text(note.name)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func existing(_ date: Date) -> NoteRef? {
        guard let dailyNotes = vault.dailyNotes else { return nil }
        return vault.index.note(atRelativePath: dailyNotes.relativePath(for: date))
    }

    private func open(_ date: Date) {
        do {
            push(.note(try vault.dailyNote(for: date).relativePath))
        } catch {
            problem = error.localizedDescription
        }
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }
}
