import HeftCore
import SwiftUI

/// Calendar preferences: app-wide rather than per-vault, so a singleton for
/// the same reason `AppearanceSettings` and `TypingSettings` are ones. Every
/// open window's calendar has to move the moment the setting changes, not
/// when that window is next opened.
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()

    @Published var firstWeekday: FirstWeekday {
        didSet { HeftDefaults.shared.set(firstWeekday.rawValue, forKey: Self.firstWeekdayKey) }
    }

    /// Whether today is marked when its daily note does not exist yet.
    @Published var marksMissingToday: Bool {
        didSet { HeftDefaults.shared.set(marksMissingToday, forKey: Self.missingTodayKey) }
    }

    private static let firstWeekdayKey = "dev.stenglein.Heft.calendar.firstWeekday"
    private static let missingTodayKey = "dev.stenglein.Heft.calendar.marksMissingToday"

    private init() {
        let stored = HeftDefaults.shared.string(forKey: Self.firstWeekdayKey)
        firstWeekday = stored.flatMap(FirstWeekday.init(rawValue:)) ?? .system
        marksMissingToday = HeftDefaults.shared.object(forKey: Self.missingTodayKey) as? Bool ?? true
    }

    /// The calendar the month grid is laid out with.
    ///
    /// Gregorian with an explicit `firstWeekday`, not `.iso8601`: the ISO
    /// calendar fixes its own week rules and is the wrong thing to ask to
    /// start weeks on Sunday. Week *numbers* are unaffected either way, since
    /// `MomentFormat` computes those itself.
    var gridCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = firstWeekday.resolved()
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

struct CalendarSettingsView: View {
    @ObservedObject private var settings = CalendarSettings.shared
    @EnvironmentObject private var registry: VaultRegistry

    var body: some View {
        Form {
            Picker("Week starts on", selection: $settings.firstWeekday) {
                ForEach(FirstWeekday.allCases) { option in
                    if option == .system {
                        Text("\(option.label) (\(systemDayName))").tag(option)
                    } else {
                        Text(option.label).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)

            Toggle("Mark today when its note does not exist", isOn: $settings.marksMissingToday)
            Text("Today is always outlined. With this on, a hollow dot also shows "
                 + "that its daily note has not been created yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Where the daily-note folder, filename format and template live.
            //
            // Not here, and it would be wrong to move them: they belong to the
            // vault, not to this reader, and two vaults open at once want two
            // different answers. But this is where anyone would look for them
            // first, so say where they are and offer to open them.
            Section {
                LabeledContent {
                    Button("Open Daily Note Settings…") {
                        registry.frontmostModel?.presentDailyNotesSettings()
                    }
                    .disabled(registry.frontmostModel?.vaultRoot == nil)
                } label: {
                    Text("Folder, filename format and template")
                    Text(
                        "These belong to the vault rather than to you, so they "
                            + "live with the vault. Also on the calendar's own "
                            + "menu, and in the command palette."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var systemDayName: String {
        let index = FirstWeekday.system.resolved()
        return ["Sunday", "Monday", "Tuesday", "Wednesday",
                "Thursday", "Friday", "Saturday"][(index - 1 + 7) % 7]
    }
}
