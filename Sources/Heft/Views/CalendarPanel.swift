import AppKit
import HeftCore
import SwiftUI

/// Month grid over the vault's daily notes. A filled dot means the note
/// exists; clicking an empty day offers to create it from the configured template.
struct CalendarPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var isWarningPresented = false

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
        HStack(spacing: 5) {
            Text(MomentFormat.format(model.calendarMonth, pattern: "MMMM YYYY"))
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .padding(.leading, 6)

            if calendarWarning != nil {
                Button { isWarningPresented.toggle() } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Calendar warning")
                .popover(isPresented: $isWarningPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar warning").font(.headline)
                        Text(calendarWarning ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !model.hasDailyNoteTemplate {
                            Divider().padding(.vertical, 2)
                            Button(model.settings.dailyNoteTemplate == nil
                                   ? "Set Up Daily Notes…"
                                   : "Repair Daily Note Template…") {
                                isWarningPresented = false
                                DispatchQueue.main.async {
                                    model.presentDailyNotesSettings()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(width: 280, alignment: .leading)
                    .padding(14)
                }
            }

            Spacer(minLength: 6)

            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 15, height: 18)
            }
            .buttonStyle(.plain)
            .help("Previous month")

            Button { goToCurrentMonth() } label: {
                Text("Today")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(height: 18)
            }
            .buttonStyle(.plain)
            .help("Jump to this month")

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 15, height: 18)
            }
            .buttonStyle(.plain)
            .help("Next month")
        }
        .foregroundStyle(.secondary)
    }

    private var calendarWarning: String? {
        var warnings: [String] = []
        if !model.dailyNotesAreInScope {
            warnings.append("This window is focused on \(model.scopeName), but the vault's daily notes are outside that folder. Opening a day may leave this workspace scope.")
        }
        if model.settings.dailyNoteTemplate == nil {
            warnings.append("No daily-note template is configured in this vault. New daily notes receive a plain heading.")
        } else if !model.hasDailyNoteTemplate {
            warnings.append("The configured daily-note template could not be found. New daily notes receive a plain heading.")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
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
                    note: note(for: day.date),
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
        guard model.openDailyNote(for: day.date) else { return }
        if !day.isInMonth {
            withAnimation(.snappy(duration: 0.18)) { model.calendarMonth = day.date }
        }
    }

    private func goToCurrentMonth() {
        withAnimation(.snappy(duration: 0.18)) { model.calendarMonth = Date() }
    }

    private var weekdaySymbols: [String] {
        // Monday-first, two letters, matching the ISO grid above.
        ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    }

    /// Looked up in the in-memory index rather than on the filesystem: this
    /// runs for every visible day on every redraw. The day's own menu needs
    /// the note itself, not just whether there is one.
    private func note(for date: Date) -> NoteRef? {
        guard let daily = model.dailyNotes else { return nil }
        return model.index.note(atRelativePath: daily.relativePath(for: date))
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

struct DailyNotesSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var dailyFolder = ""
    @State private var filenameFormat = ""
    @State private var templatePath = ""
    @State private var templateBody = ""
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var isVariableHelpPresented = false
    @State private var copiedVariable: String?

    private static let starterTemplate = """
    # {{title}}

    > {{date:dddd, MMMM Do YYYY}}

    ## Daily Log

    <!-- heft:daily-log -->

    ## Notes

    """

    /// `{{title}}` and `{{date}}` mean something specific to a daily note, so
    /// they are described here rather than taken from the shared list.
    private let placeholders: [PlaceholderToken] =
        [
            PlaceholderToken(token: "{{title}}", meaning: "Daily note filename"),
            PlaceholderToken(token: "{{date}}", meaning: "Date using the filename format"),
        ] + PlaceholderReference.dateTokens.filter { $0.token != "{{date}}" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isConfigured ? "Daily Note Settings" : "Set Up Daily Notes")
                    .font(.title2.weight(.semibold))
                Text(isConfigured
                     ? "These settings belong to \(model.vaultName)."
                     : "Heft will create the missing folders and configuration. Existing unrelated files are never overwritten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Daily notes folder")
                    TextField("Daily", text: $dailyFolder)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Filename")
                    TextField("YYYY-MM-DD", text: $filenameFormat)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Template file")
                    TextField("Templates/Daily Note.md", text: $templatePath)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $templateBody)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 150)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 5) {
                        Button { isVariableHelpPresented.toggle() } label: {
                            Label("Template variables", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $isVariableHelpPresented, arrowEdge: .bottom) {
                            variableReference
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(DailyNoteCapture.insertionMarker)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button { copy(DailyNoteCapture.insertionMarker) } label: {
                            Image(systemName: copiedVariable == DailyNoteCapture.insertionMarker
                                  ? "checkmark"
                                  : "doc.on.doc")
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy daily-log marker")
                        Text("Spotlight daily-note captures are inserted immediately above this marker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } label: {
                Text("Template contents")
            }

            GroupBox("Preview for today · \(previewPath)") {
                ScrollView {
                    Text(previewBody.isEmpty ? "Empty template" : previewBody)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(previewBody.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(height: 90)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isConfigured ? "Save" : "Create & Use") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(templatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || filenameFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear { loadDefaultsOnce() }
    }

    private var sampleTitle: String {
        let format = filenameFormat.isEmpty ? "YYYY-MM-DD" : filenameFormat
        return MomentFormat.format(Date(), pattern: format)
    }

    private var isConfigured: Bool {
        model.settings.dailyNoteTemplate != nil
    }

    private var variableReference: some View {
        PlaceholderReference(
            title: "Template Variables",
            tokens: placeholders,
            footnote: PlaceholderReference.momentTokenFootnote
        )
        .frame(width: 470, alignment: .leading)
        .padding(14)
    }

    private func copy(_ variable: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(variable, forType: .string)
        copiedVariable = variable
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedVariable == variable { copiedVariable = nil }
        }
    }

    private var previewPath: String {
        let folder = dailyFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return folder.isEmpty ? "\(sampleTitle).md" : "\(folder)/\(sampleTitle).md"
    }

    private var previewBody: String {
        MomentFormat.expandTemplate(
            templateBody,
            date: Date(),
            title: sampleTitle,
            dateFormat: filenameFormat.isEmpty ? "YYYY-MM-DD" : filenameFormat
        )
    }

    private func loadDefaultsOnce() {
        guard !didLoad else { return }
        didLoad = true
        // Whatever the vault is really doing, including Heft's own default
        // for a vault that has never been configured.
        dailyFolder = model.vaultRoot.map {
            DailyNotes(vaultRoot: $0, settings: model.settings).folder
        } ?? DailyNotes.defaultFolder
        filenameFormat = model.settings.dailyNoteFormat

        if let configured = model.settings.dailyNoteTemplate {
            templatePath = configured + (configured.lowercased().hasSuffix(".md") ? "" : ".md")
        } else {
            let templatesFolder = model.settings.templatesFolder ?? "Templates"
            templatePath = "\(templatesFolder)/Daily Note.md"
        }
        templateBody = model.templateBody(at: templatePath) ?? Self.starterTemplate
    }

    private func save() {
        do {
            try model.configureDailyNotes(
                folder: dailyFolder,
                format: filenameFormat,
                templatePath: templatePath,
                templateBody: templateBody
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DayCell: View {
    @Environment(\.appAccent) private var accent

    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let note: NoteRef?
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
                    .fill(note != nil ? AnyShapeStyle(accent) : AnyShapeStyle(.clear))
                    // A padding day's note still gets a dot, but a faint one:
                    // it belongs to a month that is not on screen.
                    .opacity(isOutsideMonth ? 0.4 : 1)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.25))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(MomentFormat.format(date, pattern: "dddd, MMMM Do YYYY"))
        .contextMenu { DayMenu(date: date, note: note, onCreate: action) }
        // A day that has a note drags it out, the way its row in the file list
        // would. An empty day has nothing to drag: creating a note by dragging
        // one would be a surprise, and clicking already does that. The note may
        // leave Heft but not be rearranged inside it, for the reason `DayMenu`
        // gives for withholding Rename and Move to….
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { _ in
                    guard let note else { return }
                    beginFileDrag(for: note.url, allowsInternalMove: false)
                }
        )
    }
}

/// Actions on one day of the calendar.
///
/// Deliberately not the file list's whole menu. A daily note's *filename* is
/// its date, and that is how the calendar finds it again, so Rename, Move to…
/// and Duplicate would quietly detach a note from the day it belongs to: the
/// note would survive, the day would lose its dot, and clicking that day would
/// offer to create a second one. The rest of that menu makes as much sense
/// here as it does there.
private struct DayMenu: View {
    @EnvironmentObject private var model: AppModel
    let date: Date
    let note: NoteRef?
    /// Creating and opening are one action: clicking a day already does
    /// whichever applies, and the menu should not disagree with the click.
    let onCreate: () -> Void

    var body: some View {
        if let note {
            Button("Open") { model.open(note) }
            Divider()
            Button("Copy Wikilink") {
                model.copyToPasteboard("[[\(note.name)]]", describedAs: "wikilink")
            }
            // The vault-relative path is what a link needs, the absolute one
            // what a terminal or another app needs, as in the file list.
            Button("Copy Path") {
                model.copyToPasteboard(note.relativePath, describedAs: "path")
            }
            Button("Copy Absolute Path") {
                model.copyToPasteboard(note.url.path, describedAs: "absolute path")
            }
            Button("Reveal in Finder") { model.revealInFinder(note.url) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                model.delete(VaultItem(
                    url: note.url, relativePath: note.relativePath,
                    kind: note.kind, name: note.name
                ))
            }
        } else {
            Button("Create Note for \(MomentFormat.format(date, pattern: "MMMM Do"))") {
                onCreate()
            }
        }
    }
}
