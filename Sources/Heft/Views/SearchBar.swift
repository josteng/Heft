import Combine
import HeftCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The one search sheet: ⌘T with no scope, ⌘O for note names, ⌘P for
/// commands, ⇧⌘F for text in notes, and tags and single tags as scopes of
/// their own. What it lists is decided in `AppModel.barRows`; this view holds
/// the field, the chip, the selection and the motion.
struct SearchBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed so a change in Settings redraws a bar already open.
    @ObservedObject private var settings = GeneralSettings.shared

    @State private var scope: BarScope?
    @State private var query = ""
    @State private var selection = 0
    /// Scoped by default, like the folder the window is focused on; the
    /// toggle and the row offering the rest of the vault say why a note is
    /// missing.
    @State private var searchesEntireVault = false
    @State private var contents = ContentSearchResult.empty()
    /// Which scope `contents` was searched in, so a result never shows in
    /// another one that happens to share the query.
    @State private var contentsScope: BarScope?
    /// Set once the bar with no scope has searched text for this query, and
    /// cleared with the field or a change of scope.
    @State private var textStuck = false
    /// Moved to ask the field to select all it holds: what was typed comes
    /// along to a scope a shortcut switched to, selected, so the next key
    /// either uses it or replaces it.
    @State private var selectAllRequest = 0
    @State private var isSearching = false
    /// Whether the highlighted row was reached by the arrows or a click
    /// rather than by being first. Space enters a scope row the reader
    /// moved to whatever they typed; one that is merely first needs the
    /// query to be the start of its name.
    @State private var isSelectionChosen = false
    /// Whether a chat with the agent fills the bar, rather than the list of
    /// chats. The field is its reply box then.
    @State private var inChat = false
    /// The field's height and the hint line's, measured: the field is drawn
    /// over the rest so it can move, and the rest keeps it room.
    @State private var fieldHeight: CGFloat = 46
    @State private var footerHeight: CGFloat = 0

    /// Whether a chat fills the bar, with the field under it as its reply box.
    private var chatting: Bool { inChat && scope == .ask }

    /// Into a chat or out of it, the field sliding to its new place.
    private func setInChat(_ value: Bool) {
        guard value != inChat else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { inChat = value }
    }

    init(scope: BarScope?) {
        _scope = State(initialValue: scope)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Which scopes share one list for animation: Notes with the Recent and
    /// Frequent its headings lead into, and every other scope alone.
    private var listFamily: String {
        switch scope {
        case .notes, .recent, .frequent: "notes"
        default: String(describing: scope)
        }
    }

    /// Whether this query reads note text as the reader types. With no
    /// scope that is only when names found little, and once it has started
    /// it stays for this search, so the text does not blink in and out as
    /// the count of names crosses the line.
    private var searchesText: Bool { textStuck || wantsText }

    /// Whether the scope's own text search is the summary's subject, which
    /// it is everywhere text is searched except the bar with no scope.
    private var showsTextSummary: Bool { scope == .contents || scope?.searchesTextToo == true }

    /// The list, built once per change of what it depends on and kept.
    ///
    /// It was a computed property, and the draw, the first selection, the
    /// Space check and the text threshold each asked for it, so every
    /// keystroke ranked the vault four times over on the main thread.
    @State private var rows: [BarRow] = []
    /// Whether names left room for text, from the same pass.
    @State private var wantsText = false

    private func refreshRows() {
        // The last text answer stays up while the next is searched, so the
        // list does not drop to names only and back on every letter.
        let text = contentsScope == scope && !trimmed.isEmpty ? contents : nil
        rows = model.barRows(
            scope: scope, query: query, entireVault: searchesEntireVault,
            orders: settings.scopeOrders, start: settings.startList, text: text
        )
        wantsText = model.barWantsText(
            scope: scope, query: query, entireVault: searchesEntireVault
        )
    }

    var body: some View {
        let rows = rows
        let chatting = chatting
        // The field is one view drawn over the rest, so opening a chat slides
        // it from the top, where a search is typed, to the bottom, under the
        // latest answer, as a chat is typed into. Moved between two places
        // in the layout instead it would be two fields, and the typing, the
        // caret and the focus would all start over.
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if chatting {
                    chatHeader
                } else {
                    Color.clear.frame(height: fieldHeight)
                    if scope == nil { scopeStrip }
                }
                Divider()
                if chatting {
                    AgentConversationView(runner: model.agent, onLeave: { dismiss() })
                        .transition(.opacity)
                    Divider()
                    Color.clear.frame(height: fieldHeight)
                } else {
                    list(rows)
                }
                if settings.showsKeyHints {
                    Divider()
                    footer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
            }
            field
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
                .frame(maxHeight: .infinity, alignment: chatting ? .bottom : .top)
                // Above the hint line and the rule over it.
                .padding(.bottom, chatting && settings.showsKeyHints ? footerHeight + 1 : 0)
        }
        // One height whatever the scope: the chip row leaving gives its room
        // to the list rather than shrinking the sheet under the pointer.
        .frame(width: PaletteMetrics.barWidth, height: PaletteMetrics.barHeight, alignment: .top)
        // ⌘1 to ⌘5 go to the chips by their place in the row, from any scope,
        // as Spotlight's categories are numbered. Invisible buttons, since a
        // shortcut needs something to belong to.
        .background { chipShortcuts }
        .background(PaletteSheetBackground())
        .presentationBackground(.clear)
        .onAppear {
            model.agent.load(vaultRoot: model.vaultRoot)
            // Back in the chat it was left in, if the bar opens on Ask; no
            // slide, as nothing was anywhere else before.
            inChat = scope == .ask && model.agent.chat != nil
            refreshRows()
            selectFirst()
        }
        // A finished run, or one deleted, changes the list of chats.
        .onReceive(model.agent.$chats) { _ in refreshRows() }

        // Esc closes the bar wherever the focus is in it. Text clicked into
        // in a chat takes the focus and the key, and neither the field's own
        // handling nor a cancel shortcut ever heard it, so the bar listens
        // ahead of everything in its window.
        .background(EscapeCloses { dismiss() })
        // A file dropped anywhere on the bar is something to ask about: its
        // path goes into the question, which lets the agent read it.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard BarScope.asksAgent else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in addDropped(url) }
                }
            }
            return true
        }
        // A bar opened before the vault finished loading fills in when it
        // has, rather than staying empty until something is typed.
        .onChange(of: model.index.notes.count) { refreshRows(); selectFirst() }
        // A rename, move or new note from a row's menu, or anything else on
        // disk, reaches the list without a keystroke.
        .onReceive(model.session?.contentChanges.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()) { _ in refreshRows() }
        .onChange(of: model.bar?.generation) {
            // A shortcut pressed with the bar already open narrows it.
            guard let request = model.bar else { return }
            enter(request.scope, carrying: query)
            if !trimmed.isEmpty { selectAllRequest += 1 }
        }
        .onChange(of: settings.scopeOrders) { refreshRows(); selectFirst() }
        .onChange(of: settings.startList) { refreshRows(); selectFirst() }
        // Keyed on whether text is wanted too: that is settled when the list
        // is rebuilt, which can land after the query has already changed.
        .task(id: "\(trimmed)|\(searchesEntireVault)|\(String(describing: scope))|\(wantsText)") {
            await searchContents()
        }
    }

    // MARK: The field

    /// The height of one line of the field, which everything beside it is
    /// centred on, so they stay with the first line as the field grows.
    private static let lineHeight: CGFloat = 22

    private var field: some View {
        HStack(alignment: .top, spacing: 8) {
            // The magnifier says "search" until a chip says what is searched;
            // then the chip takes its place, as a browser's search mode does,
            // rather than standing beside a second mark.
            if scope == nil {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .frame(height: Self.lineHeight)
                    .transition(.opacity)
            }
            // In a chat the chip is in the header over it, with the title.
            if let scope, !chatting {
                ScopeChip(scope: scope)
                    // One identity per scope, so going from the tags into a
                    // tag pops a new chip in rather than relabelling the old.
                    .id(scope)
                    .frame(height: Self.lineHeight)
                    // The chip alone springs; the field's text and the clear
                    // button slide over with the plain ease of the change, so
                    // only the new thing moves with any life.
                    .transition(.asymmetric(
                        // From its own middle, so it swells evenly rather
                        // than growing out of one corner.
                        insertion: .scale(scale: 0.7, anchor: .center)
                            .combined(with: .opacity)
                            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.4)),
                        removal: .opacity
                    ))
            }
            BarField(
                text: $query,
                placeholder: inChat && scope == .ask
                    ? "Reply" : scope?.placeholder ?? BarScope.unscopedPlaceholder,
                onSubmit: { inChat && scope == .ask ? reply() : choose(at: selection) },
                onMove: move,
                onCancel: { dismiss() },
                onTab: goIntoSelection,
                onBackspaceWhenEmpty: leaveScope,
                // ← out of a chat, as Backspace, when there is nothing to move through.
                onLeftWhenEmpty: { chatting ? leaveScope() : false },
                selectAllRequest: selectAllRequest
            )
            .padding(.vertical, -BarField.edge)
            .onChange(of: query) { old, new in
                if scope == nil, let entered = BarScope.entered(byTyping: new),
                   entered != .ask || BarScope.asksAgent {
                    enter(entered, carrying: "")
                } else if new == old + " ", let target = spaceTarget(after: old) {
                    enter(target, carrying: "")
                } else {
                    refreshRows()
                    selectFirst()
                }
            }
            if searchesText {
                if isSearching {
                    ProgressView().controlSize(.small)
                        .frame(height: Self.lineHeight)
                } else if showsTextSummary, !trimmed.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(height: Self.lineHeight)
                }
            }
            PaletteDismissButton(query: $query) { dismiss() }
                .frame(height: Self.lineHeight)
            if model.scopePath != nil, scope?.followsFolderFocus ?? true, !chatting {
                Button { searchesEntireVault.toggle(); refreshRows(); selectFirst() } label: {
                    Image(systemName: searchesEntireVault ? "globe" : "scope")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(searchesEntireVault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(searchesEntireVault ? "Showing the entire vault" : "Showing \(model.scopeName)")
                .frame(height: Self.lineHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, BarField.edge)
    }

    /// A chat's top line: the chip it is in, and which chat this is.
    private var chatHeader: some View {
        HStack(spacing: 8) {
            ScopeChip(scope: .ask)
                .frame(height: Self.lineHeight)
            Text(model.agent.chat?.title ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button { continueInSidebar() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            // Grey as the bar's other marks are; the accent made it the
            // loudest thing in the header.
            .foregroundStyle(.secondary)
            .help("Continue in the right sidebar (⌘J)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, BarField.edge + 4)
        .transition(.opacity)
    }

    private var summary: String {
        let matchWord = contents.totalOccurrences == 1 ? "match" : "matches"
        let noteWord = contents.matchedNotes == 1 ? "note" : "notes"
        return "\(contents.totalOccurrences) \(matchWord) in \(contents.matchedNotes) \(noteWord)"
    }

    /// The scopes as chips under the field, so the bar with no scope shows
    /// where else it can look without spending list rows on it.
    private var scopeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) { scopeChips }
            .padding(.bottom, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(BarScope.shownChips, id: \.self) { candidate in
                Button {
                    enter(candidate, carrying: "")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: candidate.symbol).font(.system(size: 10, weight: .semibold))
                        Text(candidate.title).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(keys(for: candidate).map { "\(candidate.title)  \($0)" } ?? candidate.title)
            }
        }
        .padding(.horizontal, 16)
    }

    /// The scope Space after `old` would enter: the highlighted row's, when
    /// it is a scope, a tag or a heading, and the reader either moved to it
    /// or typed the start of its name. Otherwise Space is a space.
    private func spaceTarget(after old: String) -> BarScope? {
        // Not refreshed yet, so still the list for `old`: the row the reader
        // was looking at when they pressed Space.
        guard rows.indices.contains(selection) else { return nil }
        let row = rows[selection]
        switch row {
        case .scope(let target):
            return isSelectionChosen || target.isNamed(byPrefix: old) ? target : nil
        case .tag(let name, _):
            return isSelectionChosen || BarScope.tag(name).isNamed(byPrefix: old) ? .tag(name) : nil
        case .folder(let path, _):
            let target = BarScope.folder(path)
            return isSelectionChosen || target.isNamed(byPrefix: old) ? target : nil
        default:
            return nil
        }
    }

    // MARK: The list

    private func list(_ rows: [BarRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty, !trimmed.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: trimmed)
                        .padding(.top, 90)
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isSelected: index == selection)
                                .id(row.id)
                                .onTapGesture {
                                    guard row.isSelectable else { return }
                                    selection = index
                                    isSelectionChosen = true
                                    choose(at: index)
                                }
                                // Right-click is where a Mac reader looks for
                                // what can be done to a row: for a note or a
                                // folder, the sidebar's own menu, so the two
                                // can never offer different things.
                                .contextMenu { rowMenu(row) }
                        }
                    }
                    .padding(6)
                    #if os(macOS)
                    .background(OverlayScrollerConfiguration())
                    #endif
                }
            }
            // No anchor, so the list scrolls the least it can to reveal the
            // row and holds still while the selection is already visible.
            // Naming one asks for the row to be put *there* on every move,
            // which scrolls from the first arrow press and pins the
            // selection mid-list, unlike every other menu on the system.
            .onChange(of: selection) {
                if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
            }
        }
        // A sheet's scrolling subtree can retain its initial children while
        // the query updates, so the list takes the query as its identity,
        // and the family of its scope. Within one family, Notes and its own
        // Recent and Frequent, entering is animated row by row, keeping what
        // both share and fading the rest. Across families the list is
        // replaced: a tag the reader uses sat in ⌘T's Frequent and, kept,
        // travelled to the top of the tags while every other row faded in.
        .id("\(trimmed)#\(searchesEntireVault)#\(listFamily)")
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: BarRow, isSelected: Bool) -> some View {
        switch row {
        case .heading(let title):
            SectionLabel(title: title)
        case .note(let note):
            NoteResultRow(note: note, isSelected: isSelected, isPinned: model.isPinned(row))
                // A result is a file, and dragging one out beats opening it
                // to find its path. Simultaneous so a click still opens it,
                // and only once the pointer has travelled.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in beginFileDrag(for: note.url) }
                )
        case .command(let command):
            CommandRow(
                command: command, title: command.title(on: model),
                isSelected: isSelected, isPinned: model.isPinned(row),
                isEnabled: command.isEnabled(on: model)
            )
        case .tag(let name, let count):
            ActionRow(
                symbol: "number", title: name,
                detail: isSelected
                    ? "Space to search"
                    : (count == 1 ? "1 note" : "\(count) notes"),
                isSelected: isSelected, isPinned: model.isPinned(row)
            )
        case .folder(let path, let count):
            ActionRow(
                symbol: "folder", title: path,
                detail: isSelected
                    ? "Space to search"
                    : (count == 1 ? "1 note" : "\(count) notes"),
                isSelected: isSelected, isPinned: model.isPinned(row)
            )
        case .scope(let target):
            // As Chrome says "Press Tab to search" on a keyword's row.
            ActionRow(
                symbol: target.symbol, title: target.title,
                detail: isSelected ? "Space to search" : keys(for: target),
                isSelected: isSelected
            )
        case .hit(let hit):
            HitRow(hit: hit, query: trimmed, isSelected: isSelected)
                // Arriving after the names, a match fades in where it lands;
                // nothing around it moves.
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.18)))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in beginFileDrag(for: hit.note.url) }
                )
        case .searchText(let text, let matches):
            ActionRow(
                symbol: "text.magnifyingglass",
                title: matches.map { $0 == 1 ? "1 match in text" : "All \($0) matches in text" }
                    ?? "Search text in notes for \u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D}",
                detail: AppCommandShortcut.searchVault.display, isSelected: isSelected
            )
        case .elsewhere(let count):
            ActionRow(
                symbol: "globe",
                title: "None in \(model.scopeName). Show \(count) in the entire vault",
                detail: nil, isSelected: isSelected
            )
        case .ask(let text):
            ActionRow(
                symbol: "sparkles",
                title: "Ask \u{201C}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}",
                detail: askScopeName, isSelected: isSelected
            )
        case .draftNote(let text):
            ActionRow(
                symbol: "square.and.pencil",
                title: "Draft a note from \u{201C}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}",
                detail: "Proposed for review", isSelected: isSelected
            )
        case .chat(let id, let title, let updatedAt):
            ActionRow(
                symbol: "bubble.left.and.text.bubble.right", title: title,
                detail: model.agent.isRunning(id)
                    ? "Answering…" : updatedAt.formatted(.relative(presentation: .named)),
                isSelected: isSelected
            )
        }
    }

    /// Where a new chat would read, as the Ask row says it.
    private var askScopeName: String {
        newChatScope.isEmpty ? "Whole vault" : "In \(newChatScope)"
    }

    /// The folder a new chat reads in: the window's focus, unless the bar
    /// was widened to the whole vault.
    private var newChatScope: String {
        searchesEntireVault ? "" : (model.scopePath ?? "")
    }

    private var chipShortcuts: some View {
        ZStack {
            ForEach(BarScope.shownChips, id: \.self) { chip in
                if let number = chip.chipNumber {
                    Button("") { switchToChip(chip) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            // ⌘D pins or unpins the selected row, as it bookmarks in Safari.
            Button("") { togglePinOfSelection() }
                .keyboardShortcut("d", modifiers: .command)
            // ⌘N in Ask starts a new chat; the app's own ⌘N waits while the
            // bar is open.
            Button("") { newChat() }
                .keyboardShortcut("n", modifiers: .command)
            // ⌘↑ back from a chat up to the chats, as Finder goes up to the
            // enclosing folder, from wherever focus is. Not ⌘[: on a German
            // keyboard [ is ⌥5.
            Button("") { if chatting { newChat() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
            // ⌘J hands the chat to the right sidebar, as Raycast's Quick AI
            // continues in its chat window.
            Button("") { if chatting { continueInSidebar() } }
                .keyboardShortcut("j", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Pins the selected row, or unpins it, and keeps it selected wherever
    /// the list now puts it.
    /// A row's right-click menu. Notes, text matches and folders get the
    /// file tree's menus themselves; the inline actions the tree performs in
    /// place, renaming and new notes or folders, are the window's own here.
    @ViewBuilder
    private func rowMenu(_ row: BarRow) -> some View {
        switch row {
        case .note(let note):
            noteMenu(note.relativePath, row: row)
        case .hit(let hit):
            noteMenu(hit.note.relativePath, row: row)
        case .folder(let path, _):
            pinItem(row)
            if let item = model.items(for: [path]).first {
                Divider()
                FolderMenu(
                    item: item,
                    onCreateNote: { model.createNote(in: item.url) },
                    onCreateFolder: { model.createFolder(in: item.url) },
                    onRename: { _ = model.rename(item) },
                    onLeave: { dismiss() },
                    showsPin: false
                )
            }
        case .chat(let id, let title, _):
            Button("Rename Chat…", systemImage: "pencil") {
                guard let chat = model.agent.chats.first(where: { $0.id == id }),
                      let name = model.host.name(
                        title: "Rename Chat", message: "A name for this chat.", initial: title, confirm: "Rename"
                      )
                else { return }
                model.agent.rename(chat, to: name)
            }
            Button("Delete Chat", systemImage: "trash", role: .destructive) {
                guard let chat = model.agent.chats.first(where: { $0.id == id }) else { return }
                model.agent.delete(chat)
            }
        default:
            pinItem(row)
        }
    }

    @ViewBuilder
    private func noteMenu(_ path: String, row: BarRow) -> some View {
        pinItem(row)
        if let item = model.items(for: [path]).first {
            Divider()
            // Opening a note from here closes the bar, as choosing its row does.
            FileMenu(item: item, onOpened: { dismiss() }, showsPin: false)
        }
    }

    /// Pin or unpin, first in every row's menu: it is what the bar's pins
    /// are for, so it leads, plainly named, with the key that does it shown.
    /// The key is drawn, not bound: a context menu is built as it opens, and
    /// ⌘D is the bar's own.
    @ViewBuilder
    private func pinItem(_ row: BarRow) -> some View {
        if let pin = model.pin(for: row) {
            let pinned = model.isPinned(row)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                togglePin(pin, keeping: row.id)
            }
            .keyboardShortcut("d", modifiers: .command)
        }
    }

    private func togglePinOfSelection() {
        guard rows.indices.contains(selection), let pin = model.pin(for: rows[selection]) else { return }
        togglePin(pin, keeping: rows[selection].id)
    }

    private func togglePin(_ pin: Pins.Pin, keeping id: String) {
        model.togglePin(pin)
        refreshRows()
        if let moved = rows.firstIndex(where: { $0.id == id }) { selection = moved }
    }

    // MARK: The hint line

    /// What the keys do to the row in hand, along the bottom, as Raycast and
    /// Linear show it: Return, pinning, leaving a scope, the chips. Pinning
    /// was ⌘D and nothing else, which nobody would find; the hint is also a
    /// button.
    private var footer: some View {
        // In a chat the list is not on screen, so nothing about its rows is.
        let chatting = inChat && scope == .ask
        let row = !chatting && rows.indices.contains(selection) ? rows[selection] : nil
        return HStack(spacing: 14) {
            if let row, let action = returnHint(for: row) {
                KeyHint(key: "↵", label: action)
            }
            if let row, model.pin(for: row) != nil {
                Button { togglePinOfSelection() } label: {
                    KeyHint(key: "⌘D", label: model.isPinned(row) ? "Unpin" : "Pin")
                }
                .buttonStyle(.plain)
                .help(model.isPinned(row) ? "Unpin, so it no longer comes first" : "Pin, so it comes first here and in ⌘T")
            }
            if chatting {
                KeyHint(key: "↵", label: "Reply")
                if model.agent.isRunning { KeyHint(key: "⌘.", label: "Stop") }
                KeyHint(key: "⌘N", label: "New chat")
                Button { continueInSidebar() } label: {
                    KeyHint(key: "⌘J", label: "Sidebar")
                }
                .buttonStyle(.plain)
                .help("Continue this chat in the right sidebar, beside the note")
            }
            if chatting || (scope != nil && trimmed.isEmpty) {
                // Backspace goes back while there is nothing to delete, in a
                // chat as anywhere; once something is typed, ⌘↑ still does.
                KeyHint(key: chatting && !trimmed.isEmpty ? "⌘↑" : "⌫", label: chatting ? "Chats" : "Back")
            }
            Spacer(minLength: 8)
            KeyHint(key: "⌘1–\(BarScope.shownChips.count)", label: "Scopes")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func returnHint(for row: BarRow) -> String? {
        switch row {
        case .note, .hit: "Open"
        case .command: "Run"
        case .heading: nil
        case .tag, .folder, .scope, .searchText: "Search in"
        case .elsewhere: "Show"
        case .ask: "Ask"
        case .draftNote: "Draft"
        case .chat: "Open"
        }
    }

    /// A chip chosen by its number, keeping what was typed, selected, as a
    /// shortcut switching the scope does.
    private func switchToChip(_ chip: BarScope) {
        guard chip != scope else { return }
        enter(chip, carrying: query)
        if !trimmed.isEmpty { selectAllRequest += 1 }
    }

    /// The ways into a scope, typed or pressed.
    private func keys(for scope: BarScope) -> String? {
        let shortcut: AppCommandShortcut? = switch scope {
        case .notes: .quickOpen
        case .commands: .commandPalette
        case .contents: .searchVault
        default: nil
        }
        return [scope.trigger.map(String.init), scope.chipNumber.map { "⌘\($0)" }, shortcut?.display]
            .compactMap { $0 }
            .joined(separator: "  ")
    }

    // MARK: Choosing

    private func selectFirst() {
        isSelectionChosen = false
        selection = rows.firstIndex { row in
            if case .heading = row { return false }
            return row.isSelectable
        } ?? 0
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var next = selection
        repeat {
            next += delta
        } while rows.indices.contains(next) && !rows[next].isSelectable
        if rows.indices.contains(next) {
            selection = next
            isSelectionChosen = true
        }
    }

    private func choose(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if let target = row.scope {
            if case .searchText(let text, _) = row {
                enter(target, carrying: text)
            } else {
                enter(target, carrying: "")
            }
            return
        }
        switch row {
        case .note(let note):
            model.open(note)
            dismiss()
        case .command(let command):
            guard command.isEnabled(on: model) else { return }
            command.perform(on: model)
            dismiss()
        case .hit(let hit):
            // Land on the line that matched, not at the top of the note.
            model.open(hit.note, revealingLine: hit.line)
            dismiss()
        case .elsewhere:
            searchesEntireVault = true
            selectFirst()
        case .ask(let text):
            startChat(text)
        case .draftNote(let text):
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            startChat("Draft a note from \u{201C}\(shown)\u{201D}", instruction: Self.draftPrompt(text))
        case .chat(let id, _, _):
            guard let chat = model.agent.chats.first(where: { $0.id == id }) else { return }
            model.agent.open(chat)
            model.recordChatUse(id)
            enter(.ask, carrying: "")
            setInChat(true)
        default:
            break
        }
    }

    // MARK: Ask

    /// A new chat with `question`, in the bar's place for its list.
    private func startChat(_ question: String, instruction: String? = nil) {
        guard model.vaultRoot != nil else { return }
        model.startChat(question, instruction: instruction, scope: newChatScope)
        enter(.ask, carrying: "")
        setInChat(true)
    }

    /// A dropped file's path, added to what is being asked.
    private func addDropped(_ url: URL) {
        if scope != .ask {
            enter(.ask, carrying: query)
            setInChat(model.agent.chat != nil)
        }
        query = AppModel.appending(model.askText(forDropped: url), to: query)
    }

    /// The field's text as the next turn of the open chat.
    private func reply() {
        if model.replyToChat(query, newChatScope: newChatScope) { query = "" }
    }

    /// The bar closes and the chat goes on in the right sidebar, the same
    /// chat with the same run, beside the note it is about.
    private func continueInSidebar() {
        guard model.agent.chat != nil else { return }
        model.showInspector(.chats)
        dismiss()
    }

    private func newChat() {
        guard scope == .ask else { return }
        model.agent.close()
        setInChat(false)
        refreshRows()
        selectFirst()
    }

    /// What "Draft a note from" asks: a whole note, named and filed by the
    /// agent, as a proposal to accept or reject like any other.
    static func draftPrompt(_ text: String) -> String {
        """
        Draft a new note from this: \u{201C}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}

        Choose a short, fitting title and the folder it belongs in, from how the vault is already \
        organised. Write it the way the vault's other notes are written, with links to related \
        notes where they help. Propose it as a new note rather than asking me anything, then say \
        in one line where you put it.
        """
    }

    /// Tab goes into whatever the selected row is a way into, and does
    /// nothing on a row that is not: focus has nowhere else to go.
    private func goIntoSelection() -> Bool {
        if rows.indices.contains(selection), rows[selection].scope != nil {
            choose(at: selection)
        }
        return true
    }

    /// Backspace in an empty field leaves the scope: a tag for the list of
    /// tags, anything else for the bar with none.
    private func leaveScope() -> Bool {
        // In a chat, Backspace goes back to the list of chats first; the run
        // carries on.
        if inChat, scope == .ask {
            newChat()
            return true
        }
        guard let scope else { return false }
        enter(scope.parent, carrying: "", isLeaving: true)
        return true
    }

    private func enter(_ target: BarScope?, carrying text: String, isLeaving: Bool = false) {
        // Eased, not sprung: a bounce made the chip, the text and the clear
        // button all wobble, where sliding them aside is the whole effect.
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.22)
        if target != .ask { setInChat(false) }
        withAnimation(animation) {
            scope = target
            query = text
            textStuck = false
            contents = .empty()
            refreshRows()
        }
        selectFirst()
        if !isLeaving, let target { model.recordScopeUse(target) }
    }


    // MARK: Text in notes

    private func searchContents() async {
        if trimmed.isEmpty { textStuck = false }
        guard searchesText, !trimmed.isEmpty else {
            isSearching = false
            contents = .empty()
            return
        }
        let term = trimmed
        isSearching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, trimmed == term else { return }
        let searched = scope
        let notes = model.barSearchableNotes(scope: searched, entireVault: searchesEntireVault)
        let result = await Task.detached(priority: .userInitiated) {
            ContentSearch.run(notes: notes, query: term, limit: 500)
        }.value
        guard !Task.isCancelled, trimmed == term, scope == searched else { return }
        // Not in an animation: one animated the list's whole layout, which
        // opened out from the middle where every other change is instant.
        // The new rows fade by themselves instead (`HitRow`'s transition).
        contentsScope = searched
        if searched == nil { textStuck = true }
        contents = ContentSearchResult(
            query: term, matches: result.matches,
            totalOccurrences: result.totalOccurrences, matchedNotes: result.matchedNotes,
            totalMatches: result.totalMatches
        )
        refreshRows()
        // The answer can put a heading where the selection was, or shorten
        // the list under it. A selection the reader did not move goes back
        // to the first row, which is now the first match rather than the
        // Text heading or the "all matches" row that held its place; one
        // they moved stays, unless it now sits on a label.
        if !isSelectionChosen || !rows.indices.contains(selection) || !rows[selection].isSelectable {
            selectFirst()
        }
        isSearching = false
    }
}

// MARK: - The field

/// An AppKit text view, because the bar needs keys a SwiftUI field does not
/// hand over: Tab to go into a scope and Backspace in an empty field to leave
/// one, as well as the arrows, Return and Escape.
///
/// A text view in a scroll view rather than a text field. The field it
/// replaced wrapped once it was allowed to grow, but did not scroll by
/// trackpad, clipped its text short of its edges and had no way to move
/// between its lines; this is how a chat prompt such as Siri's is built.
struct BarField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void
    let onTab: () -> Bool
    let onBackspaceWhenEmpty: () -> Bool
    /// ← in an empty field; false leaves it to the text view.
    var onLeftWhenEmpty: () -> Bool = { false }
    let selectAllRequest: Int
    /// The bar's sizes, or the right sidebar's smaller ones.
    var metrics: Metrics = .bar
    /// Bumped to put the keyboard in the field with the caret at the end,
    /// after what was just added, rather than selecting it all.
    var focusRequest = 0
    @Environment(\.colorScheme) private var colorScheme
    /// Whether it takes the keyboard on appearing, as the bar's field does;
    /// the sidebar's would take it from the note every time it opened.
    var focusesOnAppear = true

    /// A field's type and room. The bar's and the right sidebar's reply
    /// field are the same field at two sizes.
    struct Metrics {
        let font: NSFont
        /// The row everything beside the field is centred on; one line of
        /// text is centred in it by the inset.
        let rowHeight: CGFloat
        /// The padding above and below the field. The field reaches into it
        /// and insets its text by as much, so text scrolled out of the way
        /// goes on to the edge and the divider, under a fade, instead of
        /// stopping short of them, while at rest it sits where it did.
        let edge: CGFloat
        /// Lines the field grows to before it scrolls, as Siri's prompt does.
        var maximumLines = 5

        static let bar = Metrics(font: .systemFont(ofSize: 16), rowHeight: 22, edge: 13)
        static let sidebar = Metrics(font: .systemFont(ofSize: NSFont.systemFontSize), rowHeight: 20, edge: 10, maximumLines: 8)

        var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }
        var inset: CGFloat { max(0, (rowHeight - lineHeight) / 2) }

        /// How tall the field is for `text` at `width`: one line at least,
        /// and at most `maximumLines`, past which it scrolls within itself.
        /// Laid out the way the text view lays it out, so the two agree on
        /// every wrap.
        func height(for text: String, width: CGFloat) -> CGFloat {
            height(for: NSAttributedString(string: text, attributes: [.font: font]), width: width)
        }

        /// The same for text as the field draws it, a collapsed path and all.
        func height(for text: NSAttributedString, width: CGFloat) -> CGFloat {
            let storage = NSTextStorage(attributedString: text.length == 0
                ? NSAttributedString(string: " ", attributes: [.font: font]) : text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let used = ceil(layout.usedRect(for: container).height)
            let lines = min(max(used, lineHeight), lineHeight * CGFloat(maximumLines))
            return lines + inset * 2
        }
    }

    static var font: NSFont { Metrics.bar.font }
    static var rowHeight: CGFloat { Metrics.bar.rowHeight }
    static var lineHeight: CGFloat { Metrics.bar.lineHeight }
    static var inset: CGFloat { Metrics.bar.inset }
    static var edge: CGFloat { Metrics.bar.edge }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        Metrics.bar.height(for: text, width: width)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        // Measured as drawn, so a path collapsed to its name does not hold
        // the field open to the lines it would take spelled out.
        let drawn = (nsView.documentView as? NSTextView)?.textStorage
        let height = drawn.flatMap { $0.string == text ? metrics.height(for: $0, width: width) : nil }
            ?? metrics.height(for: text, width: width)
        return CGSize(width: width, height: height + metrics.edge * 2)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FadingScrollView()
        scroll.fade = metrics.edge
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: metrics.edge, left: 0, bottom: metrics.edge, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: metrics.edge, left: 0, bottom: metrics.edge, right: 0)

        // TextKit 1, as `height(for:width:)` measures with it, so the frame
        // and the lines it holds cannot disagree by a wrap.
        let view = NSTextView(usingTextLayoutManager: false)
        view.font = metrics.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        // A query is not prose to rewrite: as a multi-line text view the
        // field drew the Writing Tools button beside its first line.
        view.writingToolsBehavior = .none
        view.textContainerInset = NSSize(width: 0, height: metrics.inset)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.string = text
        view.delegate = context.coordinator
        view.setAccessibilityPlaceholderValue(placeholder)
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.placeholder.font = metrics.font
        if focusesOnAppear {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        view.appearance = NSAppearance.plain(dark: colorScheme == .dark)
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.highlightPaths()
        context.coordinator.placeholder.stringValue = placeholder
        context.coordinator.placeholder.isHidden = !text.isEmpty
        context.coordinator.attachPlaceholder()
        view.setAccessibilityPlaceholderValue(placeholder)
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
        if selectAllRequest != context.coordinator.selectAllRequest {
            context.coordinator.selectAllRequest = selectAllRequest
            DispatchQueue.main.async { view.selectAll(nil) }
        }

    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BarField
        var selectAllRequest = 0
        var focusRequest = 0
        weak var view: NSTextView?
        /// Drawn as a label inside the text view, where a text field draws its
        /// own; a text view has none.
        let placeholder: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.font = BarField.font
            label.textColor = .placeholderTextColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }()

        init(_ parent: BarField) {
            self.parent = parent
            selectAllRequest = parent.selectAllRequest
            focusRequest = parent.focusRequest
        }

        func attachPlaceholder() {
            guard let view, placeholder.superview !== view else { return }
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                placeholder.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
                placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: parent.metrics.inset),
            ])
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView,
                  parent.text != view.string
            else { return }
            parent.text = view.string
            highlightPaths()
        }

        /// A path to a file in the text, dropped or typed, drawn as its
        /// name in the link colour, as the chat shows it once sent. The
        /// folders before the name keep their place in the text, which the
        /// agent is sent whole, and are drawn collapsed, the way the editor
        /// hides markup: a hairline font, no colour.
        func highlightPaths() {
            guard let view, let storage = view.textStorage, !view.hasMarkedText() else { return }
            let font = parent.metrics.font
            let text = view.string as NSString
            let link = AppearanceSettings.shared.linkColor
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor],
                                  range: NSRange(location: 0, length: storage.length))
            for found in AgentFiles.occurrences(in: view.string) {
                storage.addAttribute(.foregroundColor, value: link, range: found.range)
                var path = text.substring(with: found.range)
                if path.hasSuffix("/") { path.removeLast() }
                let slash = (path as NSString).range(of: "/", options: .backwards)
                guard slash.location != NSNotFound else { continue }
                storage.addAttributes(
                    [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear],
                    range: NSRange(location: found.range.location, length: slash.location + 1)
                )
            }
            // A wikilink as its name, the brackets collapsed the same way.
            let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
            for range in AnswerText.wikilinkRanges(in: view.string) {
                storage.addAttribute(.foregroundColor, value: link, range: range)
                storage.addAttributes(hidden, range: NSRange(location: range.location, length: 2))
                storage.addAttributes(hidden, range: NSRange(location: NSMaxRange(range) - 2, length: 2))
            }
            storage.endEditing()
            // What is typed next is plain, whatever it follows.
            view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }

        /// A query is one line of meaning however many it is shown on, so a
        /// pasted line break becomes a space.
        func textView(
            _ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard let replacement = replacementString,
                  replacement.rangeOfCharacter(from: .newlines) != nil
            else { return true }
            let flat = replacement.components(separatedBy: .newlines).joined(separator: " ")
            view.insertText(flat, replacementRange: range)
            return false
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                // Up moves between the field's own lines first, and to the
                // list from the top one; Down likewise from the bottom one.
                guard isOnEdgeLine(view, top: true) else { return false }
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                guard isOnEdgeLine(view, top: false) else { return false }
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.deleteBackward(_:)):
                guard view.string.isEmpty else { return false }
                return parent.onBackspaceWhenEmpty()
            case #selector(NSResponder.moveLeft(_:)):
                guard view.string.isEmpty else { return false }
                return parent.onLeftWhenEmpty()
            default:
                return false
            }
            return true
        }

        /// Whether the caret is on the first line (or the last), where a text
        /// view's own Up (or Down) has nowhere to go.
        private func isOnEdgeLine(_ view: NSTextView, top: Bool) -> Bool {
            guard let layout = view.layoutManager, let container = view.textContainer,
                  !view.string.isEmpty
            else { return true }
            let caret = view.selectedRange().location
            let length = (view.string as NSString).length
            let glyphs = layout.numberOfGlyphs
            guard glyphs > 0 else { return true }
            let glyph = min(layout.glyphIndexForCharacter(at: min(caret, max(length - 1, 0))), glyphs - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = layout.usedRect(for: container)
            // A caret after a trailing space can sit past the last fragment.
            if caret >= length, !top { return true }
            return top ? line.minY <= used.minY + 0.5 : line.maxY >= used.maxY - 0.5
        }
    }
}

/// A scroll view whose content fades out over `fade` points at its top and
/// bottom, so text scrolled into the field's margins softens toward the
/// sheet's edge and the divider instead of being cut off there. At rest the
/// text sits inside the margins and the fade touches nothing.
private final class FadingScrollView: NSScrollView {
    var fade: CGFloat = 0
    private let gradient = CAGradientLayer()

    override func layout() {
        super.layout()
        guard fade > 0, bounds.height > fade * 2 else { return }
        wantsLayer = true
        if layer?.mask !== gradient {
            gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            layer?.mask = gradient
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let edge = fade / bounds.height
        gradient.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }
}

// MARK: - Rows

/// The scope at the start of the field.
///
/// A new chip springs in from the leading edge, which is the whole of its
/// entrance. A highlight swept across it afterwards, as Dia does, read as a
/// second event once the chip had already arrived; a glow around the sheet
/// never fitted the corners AppKit gives it.
private struct ScopeChip: View {
    @Environment(\.appAccent) private var accent
    let scope: BarScope

    var body: some View {
        // The text keeps the text colour: a light accent such as yellow is
        // unreadable as text on a tint of itself.
        HStack(spacing: 4) {
            Image(systemName: scope.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(scope.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.22)))
        .fixedSize()
        .accessibilityLabel("Searching \(scope.title)")
    }
}

/// A heading that only labels, styled as a sidebar section is.
private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteResultRow: View {
    @Environment(\.appAccent) private var accent

    let note: NoteRef
    let isSelected: Bool
    var isPinned = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(note.name)
                .font(.system(size: 13))
                .lineLimit(1)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 8)
            if !note.folder.isEmpty {
                Text(note.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}

private struct CommandRow: View {
    @Environment(\.appAccent) private var accent

    let command: AppCommand
    let title: String
    let isSelected: Bool
    var isPinned = false
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 13))
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(.rect)
    }
}

/// A row that goes somewhere rather than naming a note or a command: a tag,
/// a scope, a search of the text, the rest of the vault.
private struct ActionRow: View {
    @Environment(\.appAccent) private var accent

    let symbol: String
    let title: String
    let detail: String?
    let isSelected: Bool
    var isPinned = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}

/// A line of a note that matched, two lines tall: where, then the line.
private struct HitRow: View {
    @Environment(\.appAccent) private var accent

    let hit: ContentMatch
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(hit.note.name).font(.system(size: 13)).fontWeight(.medium)
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    Spacer(minLength: 8)
                    if hit.occurrences > 1 {
                        Text("\(hit.occurrences) matches")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                            )
                    }
                }
                highlightedPreview
                    .font(.system(size: 12))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    private var location: String {
        hit.note.folder.isEmpty ? "Line \(hit.line)" : "\(hit.note.folder) · Line \(hit.line)"
    }

    private var highlightedPreview: Text {
        let plain = hit.preview
        var result = AttributedString(plain)
        var cursor = plain.startIndex
        while cursor < plain.endIndex,
              let range = plain.range(
                of: query, options: .caseInsensitive, range: cursor..<plain.endIndex
              ),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].font = .system(size: 12, weight: .bold)
            if !isSelected { result[lower..<upper].foregroundColor = accent }
            cursor = range.upperBound
        }
        return Text(result)
    }
}

#if os(macOS)
/// SwiftUI follows the system's scrollbar preference, which can select a
/// space-taking legacy scroller. A palette needs the macOS overlay treatment:
/// visible while scrolling, faded at rest, and never part of row geometry.
private struct OverlayScrollerConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? ConfiguringView)?.configureScroller()
    }

    private final class ConfiguringView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureNowOrRetry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureNowOrRetry()
        }

        @discardableResult
        func configureScroller() -> Bool {
            guard let scrollView = enclosingScrollView else { return false }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = true
            scrollView.verticalScroller?.controlSize = .small
            return true
        }

        private func configureNowOrRetry() {
            // `viewDidMoveToSuperview` normally has the NSScrollView ancestor
            // already, which lets us set overlay style before the first frame.
            // Keep one next-turn retry for SwiftUI hierarchy changes where the
            // representable is attached from the inside out.
            guard !configureScroller() else { return }
            DispatchQueue.main.async { [weak self] in
                self?.configureScroller()
            }
        }
    }
}
#endif

/// One key and what it does, for the bar's hint line.
private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            // Return and Delete as the system's symbols, which sit on the
            // text's middle; the font's ↵ and ⌫ glyphs sat low beside a word.
            switch key {
            case "↵": Image(systemName: "return").fontWeight(.semibold)
            case "⌫": Image(systemName: "delete.left").fontWeight(.semibold)
            default: Text(key).fontWeight(.semibold)
            }
            Text(label)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }
}

/// Closes the bar on Esc from anywhere in its window, before any view in it
/// sees the key. A view that is composing text with an input method keeps
/// Esc, which cancels the composition there.
private struct EscapeCloses: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = coordinator.view?.window, event.window === window
            else { return event }
            if let composing = window.firstResponder as? NSTextInputClient, composing.hasMarkedText() {
                return event
            }
            coordinator.close()
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.close = close
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    final class Coordinator {
        var close: () -> Void
        weak var view: NSView?
        var monitor: Any?
        init(close: @escaping () -> Void) { self.close = close }
    }
}
