import HeftCore
import SwiftUI
import UIKit

/// What the iPad's sidebar lists, switched by the pill at its top, as the
/// Mac's sidebar switches between the same three.
enum PadSidebarMode: String, CaseIterable, Identifiable {
    case files, recent, tags

    var id: Self { self }

    var title: String {
        switch self {
        case .files: "Files"
        case .recent: "Recent"
        case .tags: "Tags"
        }
    }
}

/// The iPad at full width: the Mac's layout, a sidebar and the note beside
/// it. The sidebar lists what the pill chooses, searches from its field and
/// keeps a month at its foot; the note pane shows what was chosen in either.
///
/// The phone's screens are reused for what goes in them. Only what a sidebar
/// does differently is here: rows select rather than push, folders and tags
/// open in place, and the calendar is a month rather than a tab.
struct PadRootView: View {
    @Binding var selection: MobileRoute?
    @Binding var day: Date?
    @Environment(MobileVault.self) private var vault
    @SceneStorage("pad.mode") private var mode: PadSidebarMode = .recent
    @SceneStorage("pad.calendar") private var showsCalendar = true
    @State private var query = ""
    @State private var expandedFolders: Set<String> = []
    @State private var expandedTags: Set<String> = []
    @State private var creating: NewNoteRequest?
    @State private var action: ItemAction?
    @State private var detailPath: [MobileRoute] = []
    @FocusState private var searching: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $detailPath) {
                detail
                    .navigationDestination(for: MobileRoute.self) { route in
                        if case .image(let path) = route { ImageFileView(path: path) }
                    }
            }
        }
        .environment(\.mobilePush) { open($0) }
        .environment(\.mobileReplace) { open($0) }
        .environment(\.mobileClose) {
            selection = nil
            day = nil
        }
        .onChange(of: selection) { _, route in
            guard let route else { return }
            switch route {
            case .note(let path), .newNote(let path):
                day = nil
                detailPath = []
                revealInTree(path)
            default:
                // A folder or tag chosen from search opens in the sidebar,
                // not in the note pane.
                open(route)
            }
        }
        .onAppear(perform: applyLaunchRequest)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResults(query: query)
            } else {
                switch mode {
                case .recent:
                    RecentSections { action = $0 }
                case .files:
                    PadTreeRows(items: vault.tree?.children ?? [], expanded: $expandedFolders) { action = $0 }
                case .tags:
                    PadTagRows(expanded: $expandedTags)
                }
            }
        }
        .overlay {
            if vault.recent.isEmpty, vault.isScanning {
                ProgressView(vault.status ?? "Reading your vault…")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Notes, #tags, text")
        .searchFocused($searching)
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $mode) {
                ForEach(PadSidebarMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                ScanStatus()
                if showsCalendar {
                    PadMonth(chosen: day) { pick($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle(vault.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { vault.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                CaptureButton()
                NewNoteButton { creating = NewNoteRequest(folder: vault.newNoteFolder) }
                    .keyboardShortcut("n")
                VaultMenu(calendarShown: $showsCalendar)
            }
        }
        // Shortcuts with nowhere to show: ⌘K to search, ⌘⇧T for today.
        .background {
            Group {
                Button("Search") { searching = true }
                    .keyboardShortcut("k")
                Button("Today") { pick(Date()) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .newNoteSheet($creating)
        .itemActionHost($action)
    }

    // MARK: Note pane

    @ViewBuilder
    private var detail: some View {
        if let day {
            PadDayDetail(day: day).id(day)
        } else if let selection {
            switch selection {
            case .note(let path): NoteView(path: path).id(path)
            case .newNote(let path): NoteView(path: path, startsTyping: true).id(path)
            case .image(let path): ImageFileView(path: path).id(path)
            default: nothingChosen
            }
        } else {
            nothingChosen
        }
    }

    private var nothingChosen: some View {
        ContentUnavailableView(
            "No Note Selected", systemImage: "doc.text",
            description: Text("Choose a note in the sidebar, or press ⌘N for a new one.")
        )
    }

    // MARK: Routing

    /// Where a link, a new note or an action leads, on a screen with a
    /// sidebar: notes into the note pane, folders and tags into the sidebar.
    private func open(_ route: MobileRoute) {
        switch route {
        case .note, .newNote:
            day = nil
            detailPath = []
            if selection != route { selection = route }
        case .image:
            detailPath = [route]
        case .folder(let path):
            query = ""
            mode = .files
            var parent = ""
            for part in path.split(separator: "/") {
                parent = parent.isEmpty ? String(part) : parent + "/" + part
                expandedFolders.insert(parent)
            }
            if selection == route { selection = nil }
        case .tag(let tag):
            query = ""
            mode = .tags
            expandedTags.insert(tag)
            if selection == route { selection = nil }
        }
    }

    /// The folders above a note open, so the tree shows where it is, as the
    /// Mac's sidebar follows the open note.
    private func revealInTree(_ path: String) {
        var parent = ""
        for part in path.split(separator: "/").dropLast() {
            parent = parent.isEmpty ? String(part) : parent + "/" + part
            expandedFolders.insert(parent)
        }
    }

    private func pick(_ date: Date) {
        let start = Calendar.current.startOfDay(for: date)
        selection = nil
        detailPath = []
        day = start
        if !showsCalendar { withAnimation(.snappy) { showsCalendar = true } }
    }

    private func applyLaunchRequest() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["HEFT_IOS_PAD_MODE"], let chosen = PadSidebarMode(rawValue: raw) {
            mode = chosen
        }
        if let note = environment["HEFT_IOS_NOTE"] { selection = .note(note) }
        if let shift = environment["HEFT_IOS_DAY"].flatMap(Int.init) {
            pick(Calendar.current.date(byAdding: .day, value: shift, to: Date()) ?? Date())
        }
        if let preset = environment["HEFT_IOS_QUERY"] { query = preset }
        #endif
    }
}

/// The vault as a tree, folders opening in place: a sidebar has the room
/// for the whole hierarchy, where the phone goes a folder at a time.
private struct PadTreeRows: View {
    let items: [VaultItem]
    @Binding var expanded: Set<String>
    let perform: (ItemAction) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.isFolder {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(item.relativePath) },
                    set: { open in
                        if open { expanded.insert(item.relativePath) } else { expanded.remove(item.relativePath) }
                    }
                )) {
                    // Through AnyView: a view's body cannot contain itself.
                    AnyView(PadTreeRows(items: item.children, expanded: $expanded, perform: perform))
                } label: {
                    Label(item.name, systemImage: expanded.contains(item.relativePath) ? "folder.fill" : "folder")
                        .itemActions(ItemRef(path: item.relativePath, isFolder: true), perform)
                }
            } else if item.kind == .markdown {
                NavigationLink(value: MobileRoute.note(item.relativePath)) {
                    Label(item.name, systemImage: "doc.text")
                }
                .itemActions(ItemRef(path: item.relativePath, isFolder: false), perform)
            } else if item.kind == .image {
                NavigationLink(value: MobileRoute.image(item.relativePath)) {
                    Label(item.name, systemImage: "photo")
                }
                .itemActions(ItemRef(path: item.relativePath, isFolder: false), perform)
            }
        }
    }
}

/// Every tag, most used first, each opening onto its notes, newest first.
private struct PadTagRows: View {
    @Binding var expanded: Set<String>
    @Environment(MobileVault.self) private var vault

    var body: some View {
        ForEach(vault.index.allTags, id: \.self) { tag in
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(tag) },
                set: { open in
                    if open { expanded.insert(tag) } else { expanded.remove(tag) }
                }
            )) {
                if expanded.contains(tag) {
                    let tagged = Set(vault.index.notes(taggedWith: tag).map(\.relativePath))
                    ForEach(vault.index.notesByLastEdit.filter { tagged.contains($0.relativePath) }) {
                        NoteRow(note: $0)
                    }
                }
            } label: {
                HStack {
                    Text("#\(tag)")
                    Spacer()
                    Text("\(vault.index.noteCount(forTag: tag))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// The month at the foot of the sidebar, as the Mac keeps it there: a dot
/// for each day with a note, and a tap to open that day beside it.
private struct PadMonth: View {
    let chosen: Date?
    let pick: (Date) -> Void
    @Environment(MobileVault.self) private var vault
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .contentTransition(.numericText(value: month.timeIntervalSinceReferenceDate))
                Spacer()
                Group {
                    Button("Previous Month", systemImage: "chevron.left") { page(-1) }
                    Button("Next Month", systemImage: "chevron.right") { page(1) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(.primary)
            }
            let symbols = weekdaySymbols
            HStack(spacing: 0) {
                ForEach(symbols.indices, id: \.self) { index in
                    Text(symbols[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { date in cell(date) }
                }
            }
        }
        .padding(12)
        // Solid enough to read over the list scrolling under it, as the
        // Mac's sidebar calendar is.
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: chosen) { _, chosen in
            guard let chosen, !calendar.isDate(chosen, equalTo: month, toGranularity: .month) else { return }
            withAnimation(.snappy) { month = calendar.dateInterval(of: .month, for: chosen)?.start ?? month }
        }
    }

    private func cell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isChosen = chosen.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let isToday = calendar.isDateInToday(date)
        let hasNote = vault.dailyNotes.map { vault.index.note(atRelativePath: $0.relativePath(for: date)) != nil } ?? false
        return Button { pick(date) } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isToday || isChosen ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white)
                                     : isToday ? AnyShapeStyle(.tint)
                                     : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 30, height: 30)
                    .background(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .circle)
                Circle()
                    .fill(hasNote ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    private func page(_ direction: Int) {
        withAnimation(.snappy) {
            month = calendar.date(byAdding: .month, value: direction, to: month) ?? month
        }
    }

    /// The week's day letters in the order this locale starts its week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whole weeks touching the month, so every row has seven days.
    private var weeks: [[Date]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              var start = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start
        else { return [] }
        var weeks: [[Date]] = []
        while start < interval.end {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
            start = next
        }
        return weeks
    }
}

/// A day chosen in the month: its note, or the offer to make it from the
/// daily template.
private struct PadDayDetail: View {
    let day: Date
    @Environment(MobileVault.self) private var vault
    @State private var problem: String?
    @State private var made: String?

    var body: some View {
        if let path = made ?? existing {
            NoteView(path: path).id(path)
        } else {
            ContentUnavailableView {
                Label("No Note", systemImage: "calendar.badge.plus")
            } description: {
                Text(day.formatted(date: .complete, time: .omitted))
            } actions: {
                Button("Create Note") {
                    do {
                        made = try vault.dailyNote(for: day).relativePath
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private var existing: String? {
        guard let dailyNotes = vault.dailyNotes else { return nil }
        let path = dailyNotes.relativePath(for: day)
        return vault.index.note(atRelativePath: path) != nil ? path : nil
    }
}
