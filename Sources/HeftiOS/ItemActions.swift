import HeftCore
import SwiftUI

/// A note or folder something can be done to.
struct ItemRef: Hashable {
    let path: String
    let isFolder: Bool

    /// As the reader knows it: a note without its `.md`.
    var name: String {
        let last = (path as NSString).lastPathComponent
        return isFolder || !last.lowercased().hasSuffix(".md") ? last : String(last.dropLast(3))
    }
}

enum ItemAction: Identifiable {
    case rename(ItemRef), move(ItemRef), delete(ItemRef)

    var id: String {
        switch self {
        case .rename(let item): "rename:" + item.path
        case .move(let item): "move:" + item.path
        case .delete(let item): "delete:" + item.path
        }
    }

    var item: ItemRef {
        switch self {
        case .rename(let item), .move(let item), .delete(let item): item
        }
    }
}

/// What came of an action, for a screen showing the item itself.
enum ItemOutcome {
    case moved(to: String), deleted
}

extension EnvironmentValues {
    /// Set by a note's own screen, so its "…" menu can rename, move and
    /// delete it; nil where a note shows inside another screen.
    @Entry var noteItemAction: ((ItemAction) -> Void)?
}

extension View {
    /// Long press for every action, and a swipe for Delete, on a row.
    func itemActions(_ item: ItemRef, _ perform: @escaping (ItemAction) -> Void) -> some View {
        modifier(ItemRowActions(item: item, perform: perform))
    }

    /// Asks for what an action needs, carries it out, and says if it failed.
    /// `prepare` runs first, so an open note can save before it moves.
    func itemActionHost(
        _ action: Binding<ItemAction?>,
        prepare: @escaping (ItemAction) async -> Void = { _ in },
        done: @escaping (ItemOutcome) -> Void = { _ in }
    ) -> some View {
        modifier(ItemActionHost(action: action, prepare: prepare, done: done))
    }
}

private struct ItemRowActions: ViewModifier {
    let item: ItemRef
    let perform: (ItemAction) -> Void
    @Environment(MobileVault.self) private var vault

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if !item.isFolder {
                    let pinned = vault.isPinned(item.path)
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                        vault.togglePin(item.path)
                    }
                    .tint(.primary)
                    Divider()
                }
                ItemActionButtons(item: item, perform: perform)
            }
            .swipeActions(edge: .trailing) {
                // Not the destructive role: that removes the row before the
                // confirmation has been answered.
                Button("Delete", systemImage: "trash") { perform(.delete(item)) }
                    .tint(.red)
            }
    }
}

/// Rename, Move and Delete, shared by a row's menu and a note's own.
struct ItemActionButtons: View {
    let item: ItemRef
    let perform: (ItemAction) -> Void

    var body: some View {
        // Neutral, as the note's own "…" menu is: the accent is for what is
        // chosen, not for every icon in a menu.
        Button("Rename…", systemImage: "pencil") { perform(.rename(item)) }
            .tint(.primary)
        Button("Move…", systemImage: "folder") { perform(.move(item)) }
            .tint(.primary)
        Button("Delete", systemImage: "trash", role: .destructive) { perform(.delete(item)) }
            .tint(.red)
    }
}

private struct ItemActionHost: ViewModifier {
    @Binding var action: ItemAction?
    let prepare: (ItemAction) async -> Void
    let done: (ItemOutcome) -> Void
    @Environment(MobileVault.self) private var vault
    @State private var newName = ""
    /// Kept from when the action was asked for: a dismissed alert clears
    /// the binding, and its button must still know what it was for.
    @State private var current: ItemAction?
    @State private var problem: String?
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presented(\.isRename)) {
                if case .rename(let item) = current {
                    RenameSheet(item: item, title: renameTitle, name: $newName) {
                        run(.rename(item))
                    }
                }
            }
            .sheet(isPresented: presented(\.isMove)) {
                if case .move(let item) = action {
                    MoveSheet(item: item) { folder in
                        run(.move(item), into: folder)
                    }
                }
            }
            // On a neutral carrier, so the dialogs' buttons are not in the
            // accent the list around them is tinted with.
            .background {
                Color.clear
                    .confirmationDialog(deleteTitle, isPresented: presented(\.isDelete),
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { if let current { run(current) } }
                    } message: {
                        Text(deleteMessage)
                    }
                    .alert("Couldn't Do That", isPresented: .constant(problem != nil)) {
                        Button("OK") { problem = nil }
                    } message: {
                        Text(problem ?? "")
                    }
                    .alert("Links Updated", isPresented: .constant(notice != nil)) {
                        Button("OK") { notice = nil }
                    } message: {
                        Text(notice ?? "")
                    }
                    .tint(.primary)
            }
            .onChange(of: action?.id, initial: true) {
                guard let action else { return }
                current = action
                if case .rename(let item) = action { newName = item.name }
            }
    }

    private func presented(_ kind: KeyPath<ItemAction, Bool>) -> Binding<Bool> {
        Binding(
            get: { action?[keyPath: kind] ?? false },
            set: { if !$0, action?[keyPath: kind] == true { action = nil } }
        )
    }

    private var renameTitle: String {
        action?.item.isFolder == true ? "Rename Folder" : "Rename Note"
    }

    private var deleteTitle: String {
        "Delete “\(action?.item.name ?? "")”?"
    }

    private var deleteMessage: String {
        guard let item = (action ?? current)?.item else { return "" }
        if item.isFolder { return "Everything in it goes to the Trash too." }
        let links = vault.index.backlinks(to: item.path).count
        return links == 0
            ? "It goes to the Trash."
            : "It goes to the Trash. \(links) link\(links == 1 ? "" : "s") to it will no longer find it."
    }

    private func run(_ action: ItemAction, into folder: String? = nil) {
        let name = newName
        Task {
            await prepare(action)
            do {
                switch action {
                case .rename(let item):
                    done(.moved(to: try vault.rename(item.path, to: name)))
                case .move(let item):
                    done(.moved(to: try vault.move(item.path, into: folder ?? "")))
                case .delete(let item):
                    try vault.delete(item.path)
                    done(.deleted)
                }
                if let summary = vault.lastSummary {
                    vault.lastSummary = nil
                    notice = summary
                }
            } catch {
                problem = error.localizedDescription
            }
            self.action = nil
        }
    }
}

private extension ItemAction {
    var isRename: Bool { if case .rename = self { true } else { false } }
    var isMove: Bool { if case .move = self { true } else { false } }
    var isDelete: Bool { if case .delete = self { true } else { false } }
}

/// Every folder the item could go to, its own place and its own inside
/// left out.
private struct MoveSheet: View {
    let item: ItemRef
    let chosen: (String) -> Void
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let parent = (item.path as NSString).deletingLastPathComponent
        let folders = vault.folderPaths.filter { folder in
            folder != parent && !(item.isFolder && (folder == item.path || folder.hasPrefix(item.path + "/")))
        }
        NavigationStack {
            List(folders, id: \.self) { folder in
                Button {
                    dismiss()
                    chosen(folder)
                } label: {
                    Label(folder.isEmpty ? vault.name : folder,
                          systemImage: folder.isEmpty ? "books.vertical" : "folder")
                }
                .tint(.primary)
            }
            .navigationTitle("Move “\(item.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The new name, and names suggested from the note under it, as the Mac's
/// rename prompt has them: the on-device model reads the note, and nothing
/// is offered without Apple Intelligence or for a folder.
private struct RenameSheet: View {
    let item: ItemRef
    let title: String
    @Binding var name: String
    let rename: () -> Void
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [String]?
    @FocusState private var naming: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($naming)
                        .submitLabel(.done)
                        .onSubmit(confirm)
                }
                if !item.isFolder, suggestions != [] {
                    Section("Suggested") {
                        if let suggestions {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { name = suggestion }
                                    .tint(.primary)
                            }
                        } else {
                            Text("Suggesting names…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename", systemImage: "checkmark", role: .confirm, action: confirm)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { naming = true }
            .task {
                guard !item.isFolder, let url = vault.note(at: item.path)?.url else {
                    suggestions = []
                    return
                }
                let text = await Task.detached { (try? MobileVault.read(url)) ?? "" }.value
                suggestions = await NameSuggester.suggestions(for: text, current: item.name)
            }
        }
        .presentationDetents([.medium])
    }

    private func confirm() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        rename()
    }
}

@MainActor
extension View {
    /// A note's row can be dragged: into a note it writes a link to it,
    /// onto a folder in the iPad's tree it moves it there.
    func draggableNote(_ path: String, vault: MobileVault) -> some View {
        draggable(NoteDrag.link(to: path, in: vault))
    }
}

/// What a dragged note carries: its link as text, which any text view takes
/// as a drop, and which a folder can resolve back to the note.
@MainActor
enum NoteDrag {
    static func link(to path: String, in vault: MobileVault) -> String {
        guard let note = vault.note(at: path) else { return path }
        return "[[\(vault.index.linkDestination(for: note))]]"
    }

    /// The note a dropped `[[link]]` names, if it is one.
    static func note(in text: String, vault: MobileVault) -> NoteRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") else { return nil }
        let target = String(trimmed.dropFirst(2).dropLast(2))
        return vault.index.resolve(WikiLink(target: target), from: nil)
    }
}
