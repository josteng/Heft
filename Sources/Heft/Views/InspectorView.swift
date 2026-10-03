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
        case .chats: "Chats"
        }
    }

    var symbol: String {
        switch self {
        case .backlinks: "link"
        case .chats: "bubble.left.and.text.bubble.right"
        }
    }

    /// Chats only while Ask is turned on.
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
    /// What the right side can show: Chats leaves while Ask is off.
    @MainActor var usable: Self { offering { $0.isAvailable } }
}

/// The right sidebar: Backlinks, and Chats with the agent beside the note
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
                SegmentedModePicker(mode: $mode, modes: layout.visible, drawsAsSidebar: true)
                    .frame(height: 20)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            switch layout.shown(mode) {
            case .backlinks: BacklinksPanel()
            case .chats: ChatsPanel(runner: model.agent)
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

/// Chats with the agent: the list of them, or the one open, with a field
/// under it to ask or reply in.
///
/// The same chat the search bar has open, from the same runner: a question
/// asked in ⌘T carries on here, beside the note it changes.
struct ChatsPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var runner: AgentRunner
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// Where a new chat reads: the window's focused folder, or the vault.
    private var newChatScope: String { model.scopePath ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            if let chat = runner.chat {
                header(chat)
                Divider()
                AgentConversationView(runner: runner, onLeave: {})
            } else {
                chatList
            }
            Divider()
            field
        }
        .onAppear { runner.load(vaultRoot: model.vaultRoot) }
    }

    private func header(_ chat: AgentChat) -> some View {
        HStack(spacing: 6) {
            Button { runner.close() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("All chats")
            Text(chat.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(chat.title)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        // Clear of the switch above, which it would otherwise read as part of.
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if runner.chats.isEmpty {
                    Text("No chats yet. Ask about your notes below, or with ⌘T.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(runner.chats) { chat in
                    ChatListRow(chat: chat, isAnswering: runner.isRunning(chat.id)) {
                        runner.open(chat)
                        model.recordChatUse(chat.id)
                    }
                    .contextMenu { chatMenu(chat) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
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
        HStack(alignment: .bottom, spacing: 6) {
            TextField(
                runner.chat == nil
                    ? (newChatScope.isEmpty ? "Ask about your notes" : "Ask about \(model.scopeName)")
                    : "Reply",
                text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($fieldFocused)
            .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .disabled(!canSend)
            .help(runner.chat == nil ? "Ask" : "Reply")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        fieldFocused = true
    }
}

/// One past chat: its name, and when it was last answered.
private struct ChatListRow: View {
    let chat: AgentChat
    let isAnswering: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.system(size: 12))
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
                    .fill(isHovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.clear))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
