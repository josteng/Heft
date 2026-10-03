import HeftCore
import SwiftUI

/// The right side's views: about the open note, where the left side is
/// about where things are.
enum InspectorMode: String, PanelMode {
    case backlinks, chats

    static let storageName = "inspector"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backlinks: "Backlinks"
        // Ask, as in the bar and in Settings: one name for the feature, and
        // "chat" only for one conversation in it. Stored as `chats`.
        case .chats: "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .backlinks: "link"
        case .chats: BarScope.ask.symbol
        }
    }

    /// Ask only while it is turned on.
    @MainActor var isAvailable: Bool { self != .chats || BarScope.asksAgent }
}

extension PanelLayout {
    /// The layout with the views that cannot be shown right now switched
    /// off, so the switch, the shortcuts and the view a window opens on all
    /// leave them out alike.
    func offering(_ isAvailable: (Mode) -> Bool) -> Self {
        var copy = self
        for index in copy.entries.indices where !isAvailable(copy.entries[index].mode) {
            copy.entries[index].isShown = false
        }
        return copy
    }
}

extension PanelLayout where Mode == InspectorMode {
    /// What the right side can show: Ask leaves while it is off.
    @MainActor var usable: Self { offering { $0.isAvailable } }
}

/// The right sidebar: Backlinks, and Ask with its chats beside the note
/// they are about.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var general = GeneralSettings.shared
    /// The view the reader's layout opens on. Read once per window, as
    /// `@State` keeps its first value.
    @State private var mode: InspectorMode = InspectorLayout.current().usable
        .initialMode(lastUsed: InspectorLayout.lastUsed())

    var body: some View {
        let layout = general.inspectorLayout.usable
        VStack(spacing: 0) {
            // Hidden when one view is all there is, as on the left.
            if layout.visible.count > 1 {
                SegmentedModePicker(mode: $mode, modes: layout.visible, hasEqualSegments: true)
                    .frame(height: 20)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            switch layout.shown(mode) {
            case .backlinks: BacklinksPanel()
            case .chats: ChatsPanel(runner: model.agent, selection: model.editorSelection)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .onChange(of: mode) { _, mode in InspectorLayout.recordLastUsed(mode) }
        // ⌥⌘1 and ⌥⌘2, or the bar handing its chat over. Read on appearing
        // too: a hidden right side has no view to hear the request until
        // showing it builds one.
        .onAppear(perform: takeRequest)
        .onChange(of: model.inspectorModeRequest) { takeRequest() }
    }

    private func takeRequest() {
        guard let request = model.inspectorModeRequest else { return }
        model.inspectorModeRequest = nil
        mode = request
    }
}

/// A chat with the agent, the open one or an empty one, with a field under
/// it to ask or reply in, and its title a menu of the others.
///
/// The same chat the search bar has open, from the same runner: a question
/// asked in ⌘T carries on here, beside the note it changes.
struct ChatsPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var runner: AgentRunner
    @ObservedObject private var settings = GeneralSettings.shared
    @ObservedObject var selection: EditorSelection
    @State private var draft = ""
    /// Bumped by New Chat, to put the keyboard in the field.
    @State private var focusRequest = 0
    /// A file dragged over the view, which takes it anywhere: the field is
    /// at the bottom, out of reach of a drag from the Dock.
    @State private var isDropTarget = false
    /// The chats in the chat's place, opened from the title.
    @State private var showsHistory = false

    /// Where a new chat reads: the window's focused folder, or the vault.
    private var newChatScope: String { model.scopePath ?? "" }

    var body: some View {
        // Chat first: the view is always a chat, an empty one when nothing
        // is open. Its title opens the others in its place, and + starts a
        // new one: no menu, and nothing opening out of one.
        VStack(spacing: 0) {
            header
            Divider()
            if showsHistory {
                ChatHistory(runner: runner, current: runner.chat?.id, open: open, close: { showsHistory = false }) {
                    chatMenu($0)
                }
            } else {
                if runner.chat != nil {
                    AgentConversationView(runner: runner, onLeave: {})
                } else {
                    emptyChat
                }
                Divider()
                field
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in addDropped(url) }
                }
            }
            return true
        }
        .onAppear {
            runner.load(vaultRoot: model.vaultRoot)
            takeAskInsert()
        }
        .onChange(of: model.askInsertRequest) { takeAskInsert() }
        .onChange(of: model.askNewChatRequest) {
            runner.close()
            showsHistory = false
            focusRequest += 1
        }
    }

    /// Ask About's item, into the field with the caret after it.
    private func takeAskInsert() {
        guard let text = model.askInsertRequest else { return }
        model.askInsertRequest = nil
        showsHistory = false
        draft = AppModel.appending(text, to: draft)
        focusRequest += 1
    }

    /// A dropped file's path, added to what is being written, as the bar
    /// adds it.
    private func addDropped(_ url: URL) {
        draft = AppModel.appending(model.askText(forDropped: url), to: draft)
        focusRequest += 1
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(showsHistory ? "Chats" : runner.chat.map { AnswerText.shownTitle($0.title) } ?? "New chat")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(runner.chat?.title ?? "")
                // The open chat's own menu, as its row in the history has
                // it; deleting it leaves a new chat in its place.
                .contextMenu {
                    if let chat = runner.chat, !showsHistory { chatMenu(chat) }
                }
            Spacer(minLength: 4)
            // A button for the history rather than the title: a title with
            // a chevron promised a menu and opened a panel.
            headerButton(showsHistory ? "xmark" : "clock.arrow.circlepath",
                         help: showsHistory ? "Back to the chat" : "Chats") { showsHistory.toggle() }
            headerButton("plus", help: "New chat") {
                runner.close()
                showsHistory = false
                focusRequest += 1
            }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 10)
        // Clear of the switch above, which it would otherwise read as part of.
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func open(_ chat: AgentChat) {
        runner.open(chat)
        model.recordChatUse(chat.id)
        showsHistory = false
    }

    /// A plain icon button, grey like the view's other marks, lit under the
    /// pointer. Glass circles stood out beside the left's, and out of the
    /// sidebar's glass they drew their icon off centre.
    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HeaderIconButton(symbol: symbol, help: help, action: action)
    }


    /// An empty chat: things to ask at the bottom, beside the field they
    /// go into, until the first question. Not generated, so they are there
    /// at once and the same every time; off in Settings ▸ Ask.
    private var emptyChat: some View {
        VStack(alignment: .leading, spacing: 1) {
            Spacer(minLength: 0)
            if settings.suggestsQuestions {
                sectionTitle("Try")
                ForEach(Self.suggestions(note: model.current?.name, hasSelection: selection.isActive), id: \.self) { question in
                    SuggestionButton(text: question) {
                        model.startChat(question, scope: newChatScope)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    /// With text selected, about that text, which every question is sent
    /// with; otherwise about the open note and the vault.
    static func suggestions(note: String?, hasSelection: Bool = false) -> [String] {
        if hasSelection {
            return [
                "Explain the selected text",
                "Summarise the selection",
                "Which notes relate to the selection?",
                "Suggest a clearer wording for it",
            ]
        }
        var questions: [String] = []
        if let note {
            questions.append("What is \u{201C}\(note)\u{201D} about?")
            questions.append("Which notes relate to \u{201C}\(note)\u{201D}?")
        }
        questions.append("What have I been working on lately?")
        questions.append("Which tasks are still open?")
        return questions
    }

    @ViewBuilder
    private func chatMenu(_ chat: AgentChat) -> some View {
        Button("Rename Chat…", systemImage: "pencil") {
            guard let name = model.host.name(
                title: "Rename Chat", message: "A name for this chat.", initial: chat.title, confirm: "Rename"
            ) else { return }
            runner.rename(chat, to: name)
        }
        Button("Delete Chat", systemImage: "trash", role: .destructive) {
            runner.delete(chat)
        }
    }

    private var field: some View {
        // Centred, so the placeholder and the button share a middle; along
        // the bottom the text sat lower than the button.
        HStack(alignment: .center, spacing: 6) {
            // The bar's own field at the sidebar's size: it grows to eight
            // lines, then scrolls under a fade, as ⌘T's does.
            BarField(
                text: $draft,
                placeholder: placeholder,
                onSubmit: send,
                onMove: { _ in },
                onCancel: {},
                onTab: { true },
                onBackspaceWhenEmpty: { false },
                selectAllRequest: 0,
                metrics: .sidebar,
                focusRequest: focusRequest,
                focusesOnAppear: false
            )
            // Send, or Stop while an answer comes, as chat apps do: one
            // place for both, which never moves.
            if runner.isRunning {
                Button { runner.cancel() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                // In the accent, as Send is: grey read as disabled.
                .foregroundStyle(.tint)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .disabled(!canSend)
                .help(runner.chat == nil ? "Ask" : "Reply")
            }
        }
        .padding(.horizontal, 10)
    }

    /// The field's prompt, which also says when the question carries the
    /// selection: in the prompt rather than a line of its own, which pushed
    /// everything above it up each time text was merely selected. The open
    /// note and today's note go along too, but always, and are expected.
    private var placeholder: String {
        if selection.isActive {
            return runner.chat == nil ? "Ask about your selection" : "Reply about your selection"
        }
        if runner.chat != nil { return "Reply" }
        return newChatScope.isEmpty ? "Ask about your notes" : "Ask about \(model.scopeName)"
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !runner.isRunning
    }

    private func send() {
        guard canSend else { return }
        if runner.chat == nil {
            model.startChat(draft, scope: newChatScope)
            draft = ""
        } else if model.replyToChat(draft, newChatScope: newChatScope) {
            draft = ""
        }
    }
}

/// Every chat in the chat's place: a filter on top, then the chats by when
/// they were last answered. Right-click renames or deletes one; Esc in the
/// filter goes back to the chat.
struct ChatHistory<RowMenu: View>: View {
    @ObservedObject var runner: AgentRunner
    let current: String?
    let open: (AgentChat) -> Void
    let close: () -> Void
    @ViewBuilder let rowMenu: (AgentChat) -> RowMenu
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var groups: [(title: String, chats: [AgentChat])] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let chats = query.isEmpty ? runner.chats
            : runner.chats.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Self.grouped(chats)
    }

    /// Today, Yesterday, the week before and the rest, as Recent groups
    /// notes; empty groups are left out.
    static func grouped(_ chats: [AgentChat], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, chats: [AgentChat])] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.date(byAdding: .day, value: -7, to: today)!
        let buckets: [(String, (Date) -> Bool)] = [
            ("Today", { $0 >= today }),
            ("Yesterday", { $0 >= yesterday && $0 < today }),
            ("Previous 7 Days", { $0 >= week && $0 < yesterday }),
            ("Earlier", { $0 < week }),
        ]
        return buckets.compactMap { title, contains in
            let found = chats.filter { contains($0.updatedAt) }
            return found.isEmpty ? nil : (title, found)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter chats", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onExitCommand(perform: close)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.06), in: .capsule)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if groups.isEmpty {
                        Text(runner.chats.isEmpty ? "No chats yet." : "No chat is called that.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.chats) { chat in
                            ChatListRow(chat: chat, isAnswering: runner.isRunning(chat.id), isCurrent: chat.id == current) {
                                open(chat)
                            }
                            .contextMenu { rowMenu(chat) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { filterFocused = true }
    }
}

/// An icon in a header, as a button: the symbol in grey, a soft circle
/// behind it under the pointer, centred by SwiftUI.
private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A question to ask with one click, lit under the pointer.
private struct SuggestionButton: View {
    let text: String
    let ask: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: ask) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: BarScope.ask.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Two lines at most, never its full height: fixed to it,
                // outside a scroll view, its height measured at no width
                // was a letter a line, and the window grew to the screen.
                Text(text)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.clear))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One past chat: its name, and when it was last answered.
private struct ChatListRow: View {
    let chat: AgentChat
    let isAnswering: Bool
    var isCurrent = false
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AnswerText.shownTitle(chat.title))
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(isAnswering ? "Answering…" : chat.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? AnyShapeStyle(Color.primary.opacity(0.1))
                        : isHovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.clear))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(chat.title)
    }
}
