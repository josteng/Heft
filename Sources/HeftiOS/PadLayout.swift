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
/// A note or a day the iPad's note pane showed.
enum PadPlace: Equatable, Sendable {
    case note(String)
    case day(Date)
}

struct PadRootView: View {
    @Binding var selection: MobileRoute?
    @Binding var day: Date?
    @Environment(MobileVault.self) private var vault
    @SceneStorage("pad.mode") private var mode: PadSidebarMode = .recent
    @SceneStorage("pad.calendar") private var showsCalendar = true
    /// The note this window last showed, to show again when it reopens.
    @SceneStorage("pad.note") private var lastNote = ""
    /// The month starts folded to one week, as on the phone, so the list
    /// keeps most of the sidebar.
    @SceneStorage("pad.calendar.expanded") private var calendarExpanded = false
    @Environment(\.mobileCapture) private var capture
    @State private var settings: SettingsRequest?
    @State private var showsSearch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchModel = SearchModel()
    @State private var expandedFolders: Set<String> = []
    @State private var expandedTags: Set<String> = []
    @State private var creating: NewNoteRequest?
    @State private var action: ItemAction?
    @State private var detailPath: [MobileRoute] = []
    /// The note in the pane, which the panel beside it is about.
    @State private var panelNote: PanelNote?
    /// The notes and days this window has shown, for Back and Forward.
    @State private var history = NavigationHistory<PadPlace>()
    @State private var preferences = BrowsingPreferences.shared

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
            .onPreferenceChange(PanelNoteKey.self) { panelNote = $0 }
            // Outline and Linked From, as the Mac's right sidebar. On the
            // pane, outside its stack: on the note inside it, the note
            // stopped scrolling and the panel took no taps.
            .inspector(isPresented: $preferences.showsNotePanel) {
                notePanel.inspectorColumnWidth(min: 220, ideal: 280, max: 380)
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
                lastNote = path
            default:
                // A folder or tag chosen from search opens in the sidebar,
                // not in the note pane.
                open(route)
            }
        }
        .onChange(of: place, initial: true) { _, place in
            if let place { history.visit(place) }
        }
        .onAppear(perform: applyLaunchRequest)
        .overlay {
            if showsSearch {
                SearchPanel(isPresented: $showsSearch, open: { open($0) }, model: searchModel)
                    .environment(\.mobileLibrary, library)
                    // One quick fade, barely growing from the top, as the
                    // Mac's bar comes and goes; a plain fade under Reduce Motion.
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsSearch)
        .focusedSceneValue(\.heftLibrary, library)
        .environment(\.mobileLibrary, library)
    }

    /// What this window can do, for the menu bar and the search's commands.
    private var library: LibraryActions {
        LibraryActions(
            newNote: { creating = NewNoteRequest(folder: vault.newNoteFolder) },
            newFolder: { creating = NewNoteRequest(folder: vault.newNoteFolder, makesFolder: true) },
            capture: capture,
            today: { pick(Date()) },
            search: { scope in
                searchModel.scope = scope
                showsSearch = true
            },
            show: { chosen in mode = chosen },
            toggleCalendar: { withAnimation(.snappy) { showsCalendar.toggle() } },
            calendarShown: showsCalendar,
            settings: { settings = SettingsRequest() },
            refresh: { vault.refresh() },
            back: { go(history.back(skipping: unusable)) },
            forward: { go(history.forward(skipping: unusable)) },
            canGoBack: history.canGoBack,
            canGoForward: history.canGoForward,
            numbered: { number in
                if showsSearch {
                    searchModel.choose(chip: number)
                } else if let chosen = [PadSidebarMode.files, .recent, .tags].dropFirst(number - 1).first {
                    mode = chosen
                }
            }
        )
    }

    // MARK: Sidebar

    /// The pill, the list and the month stacked rather than layered: as
    /// overlays on the list, rows scrolled on under the pill and the month,
    /// and showed through them.
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $mode) {
                ForEach(PadSidebarMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            List(selection: $selection) {
                switch mode {
                case .recent:
                    RecentSections { action = $0 }
                case .files:
                    PadTreeRows(items: vault.tree?.children ?? [], expanded: $expandedFolders) { action = $0 }
                case .tags:
                    PadTagRows(expanded: $expandedTags)
                }
            }
            .overlay {
                if vault.recent.isEmpty, vault.isScanning {
                    ProgressView(vault.status ?? "Reading your vault…")
                }
            }
            // Said outright: inside the stack the list is no longer the
            // column's own, and fell back to taller, padded rows.
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)
            .refreshable { vault.refresh() }
            ScanStatus()
            if showsCalendar {
                Divider()
                PadMonth(chosen: day, expanded: $calendarExpanded, perform: { action = $0 }) { pick($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $settings) { SettingsView(page: $0.page) }
        .navigationTitle(vault.name)
        .navigationBarTitleDisplayMode(.inline)
        // The keyboard belongs to the note beside it: without this the
        // month rose with the editor's strip.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbar {
            // More on the leading side, as Notes keeps Edit there, so it does
            // not sit between New Note and Search.
            ToolbarItem(placement: .topBarLeading) {
                VaultMenu(calendarShown: $showsCalendar, capture: capture)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NewNoteButton { creating = NewNoteRequest(folder: vault.newNoteFolder) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") {
                    searchModel.scope = nil
                    showsSearch = true
                }
                    .tint(.primary)
            }
        }
        .newNoteSheet($creating)
        .itemActionHost($action)
    }

    // MARK: Note pane

    @ViewBuilder
    private var notePanel: some View {
        if let document = panelNote?.document {
            NotePanelView(document: document, backlinks: vault.index.backlinks(to: document.path)) {
                open(.note($0))
            }
        } else {
            ContentUnavailableView("No Note Open", systemImage: "doc.text",
                                   description: Text("A note's outline and the notes linking to it show here."))
        }
    }

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

    /// What the Mac shows with no note open: how many notes, and the two
    /// ways in, Quick Open and today's note.
    private var nothingChosen: some View {
        let count = vault.index.notes.count
        return VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(count == 1 ? "1 note" : "\(count) notes") in \(vault.name)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            HStack {
                Button("Quick Open…") { library.search(.notes) }
                Button("Today's Note") { library.today() }
            }
            .buttonStyle(.glass)
            .tint(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Routing

    /// What the note pane shows, as Back and Forward remember it.
    private var place: PadPlace? {
        if let day { return .day(day) }
        switch selection {
        case .note(let path), .newNote(let path): return .note(path)
        default: return nil
        }
    }

    /// Shows a place from the history. The history has already moved, so
    /// the visit this change reports is the place it is on, and records
    /// nothing.
    private func go(_ place: PadPlace?) {
        switch place {
        case .note(let path): open(.note(path))
        case .day(let date): pick(date)
        case nil: break
        }
    }

    /// A note deleted or moved since it was shown.
    private func unusable(_ place: PadPlace) -> Bool {
        if case .note(let path) = place { return vault.note(at: path) == nil }
        return false
    }

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
            mode = .files
            var parent = ""
            for part in path.split(separator: "/") {
                parent = parent.isEmpty ? String(part) : parent + "/" + part
                expandedFolders.insert(parent)
            }
            if selection == route { selection = nil }
        case .tag(let tag):
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
        switch BrowsingPreferences.shared.start {
        case .today:
            if selection == nil, day == nil { pick(Date()) }
        case .recent, .files:
            mode = BrowsingPreferences.shared.start == .files ? .files : .recent
            if selection == nil, day == nil, !lastNote.isEmpty, vault.note(at: lastNote) != nil {
                selection = .note(lastNote)
            }
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["HEFT_IOS_PAD_MODE"], let chosen = PadSidebarMode(rawValue: raw) {
            mode = chosen
        }
        if let note = environment["HEFT_IOS_NOTE"] { selection = .note(note) }
        if let shift = environment["HEFT_IOS_DAY"].flatMap(Int.init) {
            pick(Calendar.current.date(byAdding: .day, value: shift, to: Date()) ?? Date())
        }
        if environment["HEFT_IOS_QUERY"] != nil { showsSearch = true }
        if environment["HEFT_IOS_PAD_MONTH"] != nil { calendarExpanded = true }
        // `HEFT_IOS_PAD_STEPS=A.md,B.md,back` opens notes and goes back or
        // forward, a step a second, as a reader clicking through would.
        if let steps = environment["HEFT_IOS_PAD_STEPS"]?.split(separator: ",") {
            for (offset, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(offset)) {
                    switch step {
                    case "back": library.back?()
                    case "forward": library.forward?()
                    case "wait": break
                    case _ where step.hasPrefix("tag:"): open(.tag(String(step.dropFirst(4))))
                    case _ where step.hasPrefix("taptag:"):
                        // As a tap on a tag while reading: the text view
                        // takes the keyboard, the tag is followed, and the
                        // keyboard is handed back.
                        let textView = panelNote?.document.textView
                        if environment["HEFT_IOS_CARET_TOP"] != nil {
                            textView?.selectedRange = NSRange(location: 0, length: 0)
                        }
                        (textView as? MobileTextView)?.refusesFocus = true
                        textView?.becomeFirstResponder()
                        open(.tag(String(step.dropFirst(7))))
                        DispatchQueue.main.async { (textView as? MobileTextView)?.refusesFocus = false }
                    default: open(.note(String(step)))
                    }
                }
            }
        }
        #endif
    }
}

/// The vault as a tree, folders opening in place: a sidebar has the room
/// for the whole hierarchy, where the phone goes a folder at a time.
private struct PadTreeRows: View {
    let items: [VaultItem]
    @Binding var expanded: Set<String>
    let perform: (ItemAction) -> Void
    @Environment(MobileVault.self) private var vault

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
                        // A note dropped here moves into this folder, its
                        // links repointed as Move does.
                        .dropDestination(for: String.self) { texts, _ in
                            var moved = false
                            for text in texts {
                                guard let note = NoteDrag.note(in: text, vault: vault) else { continue }
                                if (try? vault.move(note.relativePath, into: item.relativePath)) != nil { moved = true }
                            }
                            return moved
                        }
                }
            } else if item.kind == .markdown {
                NavigationLink(value: MobileRoute.note(item.relativePath)) {
                    Label(item.name, systemImage: "doc.text")
                }
                .itemActions(ItemRef(path: item.relativePath, isFolder: false), perform)
                .draggableNote(item.relativePath, vault: vault)
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

/// The calendar at the foot of the sidebar, as the Mac keeps it there: a
/// dot for each day with a note, and a tap to open that day beside it.
/// Folded to the week by default, as on the phone; the title opens the
/// month, and a swipe or the arrows page by what is showing.
private struct PadMonth: View {
    let chosen: Date?
    @Binding var expanded: Bool
    let perform: (ItemAction) -> Void
    let pick: (Date) -> Void
    @Environment(MobileVault.self) private var vault
    /// Any day in what is showing: its week when folded, its month open.
    @State private var anchor = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { expanded.toggle() }
                } label: {
                    // The title folds and opens, as on the phone, with no
                    // arrow of its own beside the paging ones.
                    Text(anchor.formatted(.dateTime.month(.wide).year()))
                        .font(.headline)
                        .contentTransition(.numericText(value: anchor.timeIntervalSinceReferenceDate))
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? "Folds the month to one week" : "Shows the whole month")
                Spacer()
                Group {
                    Button(expanded ? "Previous Month" : "Previous Week", systemImage: "chevron.left") { page(-1) }
                    // Today between the arrows, always there so nothing
                    // moves: in the accent when it would go somewhere,
                    // dimmed when today is chosen and in view.
                    Button("Today", systemImage: "circle.fill") {
                        withAnimation(.snappy) { anchor = Date() }
                        pick(Date())
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(showsToday ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(showsToday)
                    Button(expanded ? "Next Month" : "Next Week", systemImage: "chevron.right") { page(1) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(.primary)
                .hoverEffect(.highlight)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        // Up and down page, as the phone's calendar does; sideways too,
        // since the folded week reads as a strip.
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            let x = drag.translation.width, y = drag.translation.height
            if abs(y) > abs(x), abs(y) > 30 { page(y < 0 ? 1 : -1) }
            else if abs(x) > 30 { page(x < 0 ? 1 : -1) }
        })
        .onChange(of: chosen) { _, chosen in
            guard let chosen else { return }
            withAnimation(.snappy) { anchor = chosen }
        }
    }

    private func cell(_ date: Date) -> some View {
        let inMonth = !expanded || calendar.isDate(date, equalTo: anchor, toGranularity: .month)
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
        // A trackpad's pointer lights the day under it, as the system's
        // own buttons do.
        .hoverEffect(.highlight)
        .contextMenu { DayMenu(date: date, perform: perform) }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    private func page(_ direction: Int) {
        withAnimation(.snappy) {
            anchor = calendar.date(byAdding: expanded ? .month : .weekOfYear, value: direction, to: anchor) ?? anchor
        }
    }

    /// Today chosen and in view, when Today has nothing to do.
    private var showsToday: Bool {
        let today = Date()
        let chosenToday = chosen.map { calendar.isDateInToday($0) } ?? false
        let inView = expanded
            ? calendar.isDate(anchor, equalTo: today, toGranularity: .month)
            : calendar.isDate(anchor, equalTo: today, toGranularity: .weekOfYear)
        return chosenToday && inView
    }

    /// The week's day letters in the order this locale starts its week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The week holding `anchor` when folded; open, every whole week
    /// touching its month, so each row has seven days.
    private var weeks: [[Date]] {
        func week(from start: Date) -> [Date] {
            (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
        guard !expanded else {
            guard let interval = calendar.dateInterval(of: .month, for: anchor),
                  var start = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start
            else { return [] }
            var weeks: [[Date]] = []
            while start < interval.end {
                weeks.append(week(from: start))
                guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
                start = next
            }
            return weeks
        }
        guard let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [] }
        return [week(from: start)]
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
