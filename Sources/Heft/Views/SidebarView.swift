import AppKit
import HeftCore
import SwiftUI

/// Which list the sidebar is showing.
///
/// Three ways into the same vault, because they answer different questions:
/// where a note lives, what was open lately, and what it is about.
enum SidebarMode: String, CaseIterable, Identifiable {
    case files, recent, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .recent: "Recent"
        case .tags: "Tags"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .recent: "clock"
        case .tags: "number"
        }
    }

    var filterPrompt: String {
        switch self {
        case .files: "Filter notes"
        case .recent: "Filter recent"
        case .tags: "Filter tags"
        }
    }
}

/// One row of the tag list, flattened.
///
/// Flat rather than a `ForEach` of tags each containing a `ForEach` of notes:
/// nested lazy stacks lost track of their children as tags were expanded, and
/// left blank gaps where a note should have been. One list of stably-identified
/// rows cannot get into that state.
private enum TagListRow: Identifiable {
    case tag(name: String, count: Int, isExpanded: Bool)
    case note(NoteRef, underTag: String)

    var id: String {
        switch self {
        case .tag(let name, _, _): "tag:\(name)"
        case .note(let note, let tag): "note:\(tag):\(note.relativePath)"
        }
    }
}

private struct SidebarInlineEdit: Equatable {
    let path: String
    var name: String
}

struct SidebarView: View {
    @Environment(\.appAccent) private var accent

    @EnvironmentObject private var model: AppModel
    @State private var filter = ""
    @State private var mode: SidebarMode = .files
    @State private var expandedTags: Set<String> = []
    @State private var inlineEdit: SidebarInlineEdit?
    /// A folder clicked in the file tree becomes the destination for the
    /// compact create menu. Nil means use the open note's folder, then the
    /// window's focused root when there is no open note in this scope.
    @State private var selectedFolderPath: String?
    /// Vault-relative path of the folder a drop would land in, or nil when
    /// nothing is being dragged over the tree.
    ///
    /// Held here rather than per row because the row under the pointer is
    /// often *not* the row that should light up: hovering a file means "drop
    /// beside it", so its enclosing folder is what highlights, exactly as
    /// Finder does it.
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            switch mode {
            case .tags: tagList
            case .recent: recentList
            case .files: if filter.isEmpty { treeList } else { filteredList }
            }

            if model.isCalendarVisible {
                VStack(spacing: 0) {
                    Divider()
                    CalendarPanel()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: model.isCalendarVisible)
        .clipped()
        .background(.ultraThinMaterial)
        .onChange(of: model.scopePath) {
            selectedFolderPath = nil
        }
        .onChange(of: model.tree) { _, tree in
            if let selectedFolderPath,
               tree?.flattened().contains(where: {
                   $0.isFolder && $0.relativePath == selectedFolderPath
               }) != true {
                self.selectedFolderPath = nil
            }
            // A successful rename keeps showing the edited name until the
            // rescan replaces the old path. Clearing here avoids flashing the
            // stale row between the filesystem move and that replacement.
            if let inlineEdit,
               tree?.flattened().contains(where: { $0.relativePath == inlineEdit.path }) != true {
                self.inlineEdit = nil
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // The picker comes first: it decides what the field below filters,
            // so reading top to bottom matches what the controls do.
            modePicker

            HStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(model.scopePath == nil ? mode.filterPrompt : "\(mode.filterPrompt) in \(model.scopeName)", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 6))

                if mode == .files, model.scopeRoot != nil {
                    Menu {
                        Button("New Note") { createNoteAtCreationTarget() }
                        Button("New Folder") { createFolderAtCreationTarget() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Create in \(creationTargetName)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let tree = model.scopedTree {
                    ForEach(tree.children) { child in
                        TreeRow(
                            item: child, depth: 0,
                            dropTarget: $dropTarget,
                            inlineEdit: $inlineEdit,
                            selectedFolderPath: $selectedFolderPath
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            // Leaves room above the first row for the drop highlight to sit
            // clear of it, and gives the list a little air under the header
            // the rest of the time.
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // This belongs to the viewport, not the lazy content. The tree can be
        // only a few rows tall; attaching here keeps every blank pixel below it
        // useful, regardless of window height.
        .contentShape(.rect)
        .contextMenu { rootContextActions }
        // Anything in the list that is not a row is the vault root, which is
        // how something gets moved back out of a folder. Attached to the
        // scroll view rather than to its contents so it covers the whole
        // visible area: the contents stop where the tree stops, and a drop
        // zone that ends halfway down the empty space is one you have to aim
        // at. Rows sit above this and take their own drops first.
        .dropDestination(for: URL.self) { urls, _ in
            dropTarget = nil
            guard let root = model.scopeRoot else { return false }
            model.move(urls, into: root)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? "" : nil
        }
        .overlay {
            if dropTarget == "" {
                // A wash rather than a hard outline. At this size a 2pt accent
                // border round the whole sidebar reads as an error state.
                RoundedRectangle(cornerRadius: 6)
                    .fill(accent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
                    )
                    // Inset less than the rows are, so the border always falls
                    // in the gap around them rather than across a row.
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var rootContextActions: some View {
        if let root = model.scopeRoot {
            Button("New Note") { beginCreatingNote(in: root) }
            Button("New Folder") { beginCreatingFolder(in: root) }
            Divider()
            Button("Copy Absolute Path") {
                model.copyToPasteboard(root.path, describedAs: "absolute path")
            }
            Button(model.scopePath == nil ? "Reveal Vault in Finder" : "Reveal Focused Folder in Finder") {
                model.revealInFinder(root)
            }
        }
    }

    private var creationTarget: URL? {
        if let selectedFolderPath, let vaultRoot = model.vaultRoot {
            let selected = vaultRoot.appendingPathComponent(selectedFolderPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: selected.path) { return selected }
        }
        if let current = model.current,
           model.isInScope(current) {
            return current.url.deletingLastPathComponent()
        }
        return model.scopeRoot
    }

    private var creationTargetName: String {
        guard let target = creationTarget else { return model.scopeName }
        return target == model.scopeRoot ? model.scopeName : target.lastPathComponent
    }

    /// Where the sidebar's own New Note button writes.
    ///
    /// A folder selected in the tree still wins: that is somebody pointing at
    /// a place, and a setting must not override a gesture. With nothing
    /// selected the General setting answers, which is the case that used to
    /// mean "beside whatever is open" with no way to say otherwise.
    private var noteCreationTarget: URL? {
        if let selectedFolderPath, let vaultRoot = model.vaultRoot {
            let selected = vaultRoot.appendingPathComponent(selectedFolderPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: selected.path) { return selected }
        }
        return model.vaultRoot == nil ? nil : model.newNoteDirectory
    }

    private func createNoteAtCreationTarget() {
        guard let target = noteCreationTarget else { return }
        beginCreatingNote(in: target)
    }

    private func createFolderAtCreationTarget() {
        guard let target = creationTarget else { return }
        beginCreatingFolder(in: target)
    }

    private func beginCreatingNote(in folder: URL) {
        mode = .files
        filter = ""
        guard let created = model.createUntitledNote(in: folder) else { return }
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name)
    }

    private func beginCreatingFolder(in folder: URL) {
        mode = .files
        filter = ""
        guard let created = model.createUntitledFolder(in: folder) else { return }
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name)
    }

    /// Switches which list the sidebar shows.
    ///
    /// Hand-rolled rather than a `Picker`. `.segmented` fills the sidebar's
    /// whole width with three words and reads as heavy chrome; `.palette`
    /// shrinks the icons past legibility. This keeps the icon at a readable
    /// size *and* keeps the labels, which matter because "Recent" and "Tags"
    /// are not guessable from a clock and a hash.
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(SidebarMode.allCases) { option in
                let isSelected = mode == option
                Button {
                    mode = option
                    filter = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: option.symbol).font(.system(size: 12))
                        Text(option.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .help(option.title)
            }
        }
        .padding(2)
        .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 7))
    }

    /// Tags, most used first, each expanding to the notes carrying it.
    private var tagList: some View {
        let rows = tagRows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    empty(filter.isEmpty ? "No tags in this vault" : "No matching tags")
                }
                ForEach(rows) { row in
                    switch row {
                    case .tag(let name, let count, let isExpanded):
                        NoteRow(
                            name: name,
                            detail: "\(count)",
                            isSelected: false,
                            depth: 0,
                            symbol: "number",
                            disclosure: isExpanded
                        ) {
                            if isExpanded { expandedTags.remove(name) }
                            else { expandedTags.insert(name) }
                        }
                    case .note(let note, _):
                        let item = VaultItem(
                            url: note.url, relativePath: note.relativePath,
                            kind: note.kind, name: note.name
                        )
                        NoteRow(
                            name: note.name,
                            detail: note.folder,
                            isSelected: model.current?.relativePath == note.relativePath,
                            depth: 1,
                            symbol: "doc.text",
                            renameText: renameBinding(for: item),
                            onRenameCommit: { commitRename(item) },
                            onRenameCancel: cancelRename
                        ) {
                            selectedFolderPath = nil
                            model.open(note)
                        }
                        .contextMenu {
                            FileMenu(
                                item: item,
                                onCreateNote: { beginCreatingNote(in: note.url.deletingLastPathComponent()) },
                                onRename: { beginRename(item) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private var tagRows: [TagListRow] {
        var rows: [TagListRow] = []
        for tag in model.scopedTags(matching: filter) {
            let notes = model.scopedNotes(taggedWith: tag)
            let isExpanded = expandedTags.contains(tag)
            rows.append(.tag(name: tag, count: notes.count, isExpanded: isExpanded))
            guard isExpanded else { continue }
            rows.append(contentsOf: notes.map { .note($0, underTag: tag) })
        }
        return rows
    }

    /// Notes in the order they were last opened, newest first.
    private var recentList: some View {
        let notes = model.recentNotes.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if notes.isEmpty {
                    empty(filter.isEmpty ? "Nothing opened yet" : "No matching notes")
                }
                ForEach(notes) { note in
                    let item = VaultItem(
                        url: note.url, relativePath: note.relativePath,
                        kind: note.kind, name: note.name
                    )
                    NoteRow(
                        name: note.name,
                        detail: note.folder,
                        isSelected: model.current?.relativePath == note.relativePath,
                        depth: 0,
                        symbol: "doc.text",
                        renameText: renameBinding(for: item),
                        onRenameCommit: { commitRename(item) },
                        onRenameCancel: cancelRename
                    ) {
                        selectedFolderPath = nil
                        model.open(note)
                    }
                    .contextMenu {
                        FileMenu(
                            item: item,
                            onCreateNote: { beginCreatingNote(in: note.url.deletingLastPathComponent()) },
                            onRename: { beginRename(item) }
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
    }

    private var filteredList: some View {
        let matches = model.searchNotes(filter, limit: 200)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(matches) { note in
                    let item = VaultItem(
                        url: note.url, relativePath: note.relativePath,
                        kind: note.kind, name: note.name
                    )
                    NoteRow(
                        name: note.name,
                        detail: note.folder,
                        isSelected: model.current?.relativePath == note.relativePath,
                        depth: 0,
                        symbol: "doc.text",
                        renameText: renameBinding(for: item),
                        onRenameCommit: { commitRename(item) },
                        onRenameCancel: cancelRename
                    ) {
                        selectedFolderPath = nil
                        model.open(note)
                    }
                    // Search results get the same menu; the tree's `VaultItem`
                    // is not to hand here, so it is rebuilt from the hit.
                    .contextMenu {
                        FileMenu(
                            item: item,
                            onCreateNote: { beginCreatingNote(in: note.url.deletingLastPathComponent()) },
                            onRename: { beginRename(item) }
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .contentShape(.rect)
        .contextMenu { rootContextActions }
    }

    private func renameBinding(for item: VaultItem) -> Binding<String>? {
        guard inlineEdit?.path == item.relativePath else { return nil }
        return Binding(
            get: { inlineEdit?.name ?? item.name },
            set: { inlineEdit?.name = $0 }
        )
    }

    private func beginRename(_ item: VaultItem) {
        inlineEdit = SidebarInlineEdit(path: item.relativePath, name: item.name)
    }

    private func cancelRename() {
        inlineEdit = nil
    }

    private func commitRename(_ item: VaultItem) {
        guard let edit = inlineEdit, edit.path == item.relativePath else { return }
        if edit.name == item.name || !model.rename(item, to: edit.name) {
            inlineEdit = nil
        }
    }
}

private struct TreeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    let depth: Int
    @Binding var dropTarget: String?
    @Binding var inlineEdit: SidebarInlineEdit?
    @Binding var selectedFolderPath: String?

    @State private var springLoad: Task<Void, Never>?

    private var isExpanded: Bool { model.expandedFolders.contains(item.relativePath) }

    /// The folder a drop on this row lands in: a folder takes the drop itself,
    /// a file passes it to whatever folder it sits in.
    private var destination: URL {
        item.isFolder ? item.url : item.url.deletingLastPathComponent()
    }

    private var destinationPath: String {
        if item.isFolder { return item.relativePath }
        let parts = item.relativePath.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var body: some View {
        if item.isFolder {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: selectedFolderPath == item.relativePath,
                depth: depth,
                symbol: isExpanded ? "folder.fill" : "folder",
                disclosure: isExpanded,
                isDropTargeted: dropTarget == item.relativePath,
                renameText: renameBinding,
                onRenameCommit: commitRename,
                onRenameCancel: cancelRename
            ) {
                selectedFolderPath = item.relativePath
                if isExpanded { model.expandedFolders.remove(item.relativePath) }
                else { model.expandedFolders.insert(item.relativePath) }
            }
            .contextMenu {
                FolderMenu(
                    item: item,
                    onCreateNote: { beginCreatingNote(in: item.url) },
                    onCreateFolder: { beginCreatingFolder(in: item.url) },
                    onRename: beginRename
                )
            }
            // Simultaneous, so the row's button still gets its click: this
            // only fires once the pointer has actually travelled.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in beginFileDrag(for: item.url) }
            )
            .dropDestination(for: URL.self) { urls, _ in
                dropTarget = nil
                model.move(urls, into: item.url)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? item.relativePath : nil
                springLoad?.cancel()
                guard targeted, !isExpanded else { return }
                // Spring loading: hovering a closed folder opens it, so a file
                // can be dropped somewhere nested without letting go first.
                springLoad = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    _ = model.expandedFolders.insert(item.relativePath)
                }
            }

            if isExpanded {
                ForEach(item.children) { child in
                    TreeRow(
                        item: child, depth: depth + 1,
                        dropTarget: $dropTarget,
                        inlineEdit: $inlineEdit,
                        selectedFolderPath: $selectedFolderPath
                    )
                }
            }
        } else {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: selectedFolderPath == nil
                    && model.current?.relativePath == item.relativePath,
                depth: depth,
                symbol: symbol(for: item.kind),
                isDimmed: item.needsDownload,
                renameText: renameBinding,
                onRenameCommit: commitRename,
                onRenameCancel: cancelRename
            ) {
                selectedFolderPath = nil
                model.open(item: item)
            }
            .contextMenu {
                FileMenu(
                    item: item,
                    onCreateNote: { beginCreatingNote(in: destination) },
                    onRename: beginRename
                )
            }
            // Simultaneous, so the row's button still gets its click: this
            // only fires once the pointer has actually travelled.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in beginFileDrag(for: item.url) }
            )
            // Dropping onto a file means "put it here, beside this" — the row
            // itself is not the destination, its folder is. So the drop is
            // accepted, but the highlight goes to the enclosing folder.
            .dropDestination(for: URL.self) { urls, _ in
                dropTarget = nil
                model.move(urls, into: destination)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? destinationPath : nil
            }
        }
    }

    private var renameBinding: Binding<String>? {
        guard inlineEdit?.path == item.relativePath else { return nil }
        return Binding(
            get: { inlineEdit?.name ?? item.name },
            set: { inlineEdit?.name = $0 }
        )
    }

    private func beginRename() {
        inlineEdit = SidebarInlineEdit(path: item.relativePath, name: item.name)
    }

    private func cancelRename() {
        guard inlineEdit?.path == item.relativePath else { return }
        inlineEdit = nil
    }

    private func commitRename() {
        guard let edit = inlineEdit, edit.path == item.relativePath else { return }
        if edit.name == item.name || !model.rename(item, to: edit.name) {
            inlineEdit = nil
        }
    }

    private func beginCreatingNote(in folder: URL) {
        guard let created = model.createUntitledNote(in: folder) else { return }
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name)
    }

    private func beginCreatingFolder(in folder: URL) {
        guard let created = model.createUntitledFolder(in: folder) else { return }
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name)
    }

    private func symbol(for kind: VaultItem.Kind) -> String {
        switch kind {
        case .markdown: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .canvas: "square.on.square.dashed"
        default: "doc"
        }
    }
}

// MARK: - Dragging out of Heft

/// What a dragged note or folder is written to the pasteboard as.
///
/// `NSURL` publishes `public.file-url` as concrete data, which is what a
/// terminal, Finder, another editor, and Heft's own
/// `dropDestination(for: URL.self)` move targets all read as the real file.
func fileDragPasteboardWriter(for url: URL) -> NSPasteboardWriting { url as NSURL }

/// Starts a real AppKit drag for a vault item.
///
/// SwiftUI cannot export this drag, and the reason is worth recording because
/// two plausible fixes both fail. `.draggable(url)` and
/// `.onDrag { NSItemProvider(object: url as NSURL) }` each hand the receiver a
/// file *promise* rather than the file: SwiftUI redeems it by copying the item
/// into `~/Library/Caches/com.apple.SwiftUI.Drag-<uuid>/`, so dropping a note
/// into a terminal yielded a path to a throwaway copy — worse than a broken
/// path, because it looks like a real one. The item provider is not at fault;
/// on its own it registers `public.file-url` and loads the correct path. It is
/// SwiftUI's drag bridge that re-exports it, it does so whether or not the app
/// is sandboxed, and there is no SwiftUI-level way to turn it off.
///
/// So only the *gesture* stays in SwiftUI, and the drag itself is begun
/// through AppKit, which writes the URL straight to the drag pasteboard with
/// nothing to stage. Starting from the window's content view rather than a
/// view of our own is what keeps the row untouched: it still has its button,
/// hover, context menu and rename field, none of which a drag-catching overlay
/// could have left intact.
///
/// `allowsInternalMove` is false for a drag that may leave Heft but must not
/// rearrange the vault: a daily note is found again by its filename, so
/// dropping one into another folder would detach it from its day. `DayMenu`
/// withholds Rename and Move to… for that reason, and a drag is not a way
/// around it.
@MainActor
func beginFileDrag(for url: URL, allowsInternalMove: Bool = true) {
    // `onChanged` repeats for the whole gesture; a session is already running.
    guard !FileDragSource.shared.isDragging,
          let event = NSApp.currentEvent,
          let view = event.window?.contentView
    else { return }

    let item = NSDraggingItem(pasteboardWriter: fileDragPasteboardWriter(for: url))
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    icon.size = NSSize(width: 32, height: 32)
    let origin = view.convert(event.locationInWindow, from: nil)
    item.setDraggingFrame(
        NSRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32),
        contents: icon
    )

    FileDragSource.shared.isDragging = true
    FileDragSource.shared.allowsInternalMove = allowsInternalMove
    view.beginDraggingSession(with: [item], event: event, source: FileDragSource.shared)
}

/// Owns the drag operation. A dragging source has to outlive the session, and
/// sidebar rows are replaced whenever the tree rescans, so this cannot be the
/// row.
final class FileDragSource: NSObject, NSDraggingSource {
    @MainActor static let shared = FileDragSource()

    /// Set for the length of one session, so the gesture cannot start a second.
    @MainActor var isDragging = false

    /// Whether this session may also be dropped on Heft's own move targets.
    @MainActor var allowsInternalMove = true

    /// What a session started by `beginFileDrag` is allowed to do.
    ///
    /// Leaving Heft hands over a reference, so nothing is removed here. Inside
    /// it, a drop on a folder means move, but the destination is left to
    /// choose: it is `AppModel.move` that relocates the file, not AppKit. A
    /// drag that may not rearrange the vault offers nothing at all internally,
    /// so its rows refuse it rather than appearing to accept and doing nothing.
    static func operation(
        for context: NSDraggingContext, allowsInternalMove: Bool
    ) -> NSDragOperation {
        guard context != .outsideApplication else { return .copy }
        return allowsInternalMove ? [.copy, .move] : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        MainActor.assumeIsolated {
            Self.operation(for: context, allowsInternalMove: allowsInternalMove)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        MainActor.assumeIsolated { isDragging = false }
    }
}

// MARK: - Context menus

/// Actions on a note or attachment.
private struct FileMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    var onCreateNote: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    var body: some View {
        Button("Open") { model.open(item: item) }
        if !item.isMarkdown {
            Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
        }
        Divider()
        Button("New Note Here") {
            if let onCreateNote { onCreateNote() }
            else { model.createNote(in: item.url.deletingLastPathComponent()) }
        }
        Button("Rename") {
            if let onRename { onRename() }
            else { model.rename(item) }
        }
        Button("Move to…") { model.promptToMove(item) }
        Button("Duplicate") { model.duplicate(item) }
        Divider()
        // The vault-relative path is what a link needs; the absolute one is
        // what a terminal or another app needs. Both are worth having.
        Button("Copy Path") { model.copyToPasteboard(item.relativePath, describedAs: "path") }
        Button("Copy Absolute Path") {
            model.copyToPasteboard(item.url.path, describedAs: "absolute path")
        }
        if item.isMarkdown {
            Button("Copy Wikilink") {
                model.copyToPasteboard("[[\(item.name)]]", describedAs: "wikilink")
            }
        }
        Button("Reveal in Finder") { model.revealInFinder(item.url) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(item) }
    }
}

/// Actions on a folder. `New Note` here is how a note gets created inside a
/// specific folder rather than beside whatever happens to be open.
private struct FolderMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let item: VaultItem
    let onCreateNote: () -> Void
    let onCreateFolder: () -> Void
    let onRename: () -> Void

    var body: some View {
        Button("Focus This Window on \"\(item.name)\"") { model.setScope(to: item) }
        Button("Open \"\(item.name)\" in New Window") {
            openWindow(value: model.descriptor(scopePath: item.relativePath))
        }
        Divider()
        Button("New Note") { onCreateNote() }
        Button("New Folder") { onCreateFolder() }
        Divider()
        Button("Rename") { onRename() }
        Button("Move to…") { model.promptToMove(item) }
        Button("Copy Path") { model.copyToPasteboard(item.relativePath, describedAs: "path") }
        Button("Copy Absolute Path") {
            model.copyToPasteboard(item.url.path, describedAs: "absolute path")
        }
        Button("Reveal in Finder") { model.revealInFinder(item.url) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(item) }
    }
}

private struct NoteRow: View {
    @Environment(\.appAccent) private var accent

    let name: String
    let detail: String?
    let isSelected: Bool
    let depth: Int
    let symbol: String
    var disclosure: Bool? = nil
    var isDimmed: Bool = false
    var isDropTargeted: Bool = false
    var renameText: Binding<String>? = nil
    var onRenameCommit: (() -> Void)? = nil
    var onRenameCancel: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false
    @State private var didFinishRename = false
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        Group {
            if let renameText {
                rowContents(renameText: renameText)
                    .task {
                        didFinishRename = false
                        // A context menu temporarily owns the window's first
                        // responder. Wait until its closing animation has
                        // completed before claiming focus for the field.
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        isRenameFocused = true
                        await Task.yield()
                        NSApp.sendAction(
                            #selector(NSText.selectAll(_:)), to: nil, from: nil
                        )
                    }
                    .onChange(of: isRenameFocused) { oldValue, newValue in
                        if oldValue && !newValue { finishRename(commit: true) }
                    }
            } else {
                Button(action: action) { rowContents(renameText: nil) }
                    .buttonStyle(.plain)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func rowContents(renameText: Binding<String>?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            if let renameText {
                TextField("Name", text: renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isRenameFocused)
                    .onSubmit { finishRename(commit: true) }
                    .onExitCommand { finishRename(commit: false) }
            } else {
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if renameText == nil, let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // iCloud has evicted this file's contents; opening it downloads first.
            if isDimmed {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            // Trailing rather than in front of the folder icon.
            //
            // Leading, it was indentation that only folders had: a file and a
            // folder at the same depth started their icons 15pt apart, so the
            // tree had no single left edge to read down. Against the right
            // edge every chevron lines up in its own column instead, and the
            // icons of everything at one depth finally agree.
            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
                    .frame(width: 10)
                    // Turned by the row's own action, so it must not eat the
                    // click that gets there.
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isDropTargeted {
                // Outlined rather than filled, so it reads as "into here"
                // rather than as a selection.
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(accent, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.12))
                    )
            } else if isSelected {
                RoundedRectangle(cornerRadius: 5).fill(accent)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    private func finishRename(commit: Bool) {
        guard !didFinishRename else { return }
        didFinishRename = true
        if commit {
            onRenameCommit?()
        } else {
            onRenameCancel?()
        }
    }
}
