import AppIntents
import SwiftUI
import WidgetKit

/// Today's daily note on the Home Screen and the Lock Screen: its first
/// lines, tasks with their boxes, and a button that adds to it.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: TodaySnapshot.widgetKind, intent: TodayWidgetIntent.self,
                               provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "heft://today"))
        }
        .configurationDisplayName("Today's Note")
        .description("The start of today's daily note, and a button to add to it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

/// Which part of the note a widget shows, chosen in Edit Widget.
enum TodayWidgetPart: String, AppEnum {
    case latest, opening

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Part of Note"
    static let caseDisplayRepresentations: [TodayWidgetPart: DisplayRepresentation] = [
        .latest: "Latest",
        .opening: "Start of Note",
    ]
}

struct TodayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Today's Note"
    static let description = IntentDescription("Shows today's daily note.")

    @Parameter(title: "Show", default: .latest)
    var part: TodayWidgetPart
}

struct TodayEntry: TimelineEntry {
    let date: Date
    /// What the app last wrote, when it is about this entry's day.
    let snapshot: TodaySnapshot?
    var part: TodayWidgetPart = .latest
}

struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: TodaySnapshot(
            day: Date(), title: "", exists: true,
            lines: [.init(text: "Water the plants", done: false), .init(text: "Call back", done: true)]
        ))
    }

    func snapshot(for configuration: TodayWidgetIntent, in context: Context) async -> TodayEntry {
        entry(at: Date(), part: configuration.part)
    }

    /// Now, and again at midnight, when the note on show stops being today's.
    func timeline(for configuration: TodayWidgetIntent, in context: Context) async -> Timeline<TodayEntry> {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        return Timeline(
            entries: [entry(at: now, part: configuration.part), entry(at: midnight, part: configuration.part)],
            policy: .after(midnight)
        )
    }

    private func entry(at date: Date, part: TodayWidgetPart) -> TodayEntry {
        let snapshot = TodaySnapshot.load()
        let current = snapshot.map { Calendar.current.isDate($0.day, inSameDayAs: date) } ?? false
        return TodayEntry(date: date, snapshot: current ? snapshot : nil, part: part)
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.date, format: .dateTime.weekday(.wide).day().month())
                    .font(.headline)
                    .widgetAccentable()
                ForEach(shown(2), id: \.self) { line($0) }
                if lines.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                // The add button in the top corner, level with the date it
                // adds to, as a filled circle in the accent.
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.date, format: .dateTime.weekday(.wide))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(entry.date, format: .dateTime.day().month(.wide))
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // The plus is cut out of the circle, so the clear and tinted
                    // Home Screens, which draw a widget in one colour, still
                    // show it; a white plus on a filled circle became a dot.
                    Button(intent: OpenCaptureIntent(destination: .today)) {
                        if renderingMode == .fullColor {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .tint)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 30))
                                .widgetAccentable()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add to Today")
                }
                if lines.isEmpty {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(shown(family == .systemSmall ? 4 : 5), id: \.self) { line($0) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lines: [TodaySnapshot.Line] {
        entry.part == .opening ? entry.snapshot?.opening ?? [] : entry.snapshot?.lines ?? []
    }

    /// `count` lines, the latest or the first, without a heading left at the
    /// end with nothing under it.
    private func shown(_ count: Int) -> [TodaySnapshot.Line] {
        var shown = Array(entry.part == .opening ? lines.prefix(count) : lines.suffix(count))
        while shown.last?.heading == true { shown.removeLast() }
        return shown
    }

    private var emptyText: String {
        entry.snapshot?.exists == true ? "Nothing written yet." : "No note for today yet."
    }

    @ViewBuilder
    private func line(_ line: TodaySnapshot.Line) -> some View {
        if line.heading == true {
            Text(line.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
        } else {
            item(line)
        }
    }

    private func item(_ line: TodaySnapshot.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let done = line.done {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.caption)
            }
            Text(line.text)
                .font(.subheadline)
                .strikethrough(line.done == true)
                .foregroundStyle(line.done == true ? .secondary : .primary)
                .lineLimit(1)
        }
    }
}
