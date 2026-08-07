import SwiftUI

/// Commands exposed through the searchable palette. Keeping metadata and
/// execution together makes adding a command a single, reviewable change.
enum AppCommand: String, CaseIterable, Identifiable {
    case openToday
    case toggleCalendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openToday: "Open today's note"
        case .toggleCalendar: "Toggle calendar"
        }
    }

    var symbol: String {
        switch self {
        case .openToday: "calendar.badge.clock"
        case .toggleCalendar: "calendar"
        }
    }

    private var searchTerms: String {
        switch self {
        case .openToday: "daily today note open"
        case .toggleCalendar: "calendar show hide toggle sidebar"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(title) \(searchTerms)".localizedCaseInsensitiveContains(query)
    }

    @MainActor
    func perform(on model: AppModel) {
        switch self {
        case .openToday:
            model.openDailyNote(for: Date())
        case .toggleCalendar:
            model.isCalendarVisible.toggle()
        }
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var results: [AppCommand] {
        AppCommand.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right.2")
                    .foregroundStyle(.secondary)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit(runSelection)
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        CommandRow(command: command, isSelected: index == selection)
                            .onTapGesture {
                                selection = index
                                runSelection()
                            }
                    }
                }
                .padding(6)
            }
            .frame(height: 180)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func runSelection() {
        guard results.indices.contains(selection) else { return }
        results[selection].perform(on: model)
        dismiss()
    }
}

private struct CommandRow: View {
    let command: AppCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: command.symbol)
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(command.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}
