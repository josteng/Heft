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
    /// True for a note the sidebar has just written so it could be named.
    /// Backing out of *that* takes the file with it; backing out of a rename
    /// leaves the note exactly as it was.
    var isNew = false
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
    /// Rows picked out by hand, for acting on several at once. Held here
    /// rather than on `AppModel` for the same reason `selectedFolderPath` is:
    /// it belongs to this list, and the model publishes on every keystroke.
    /// It is mirrored onto `sidebarKeys` below, which is what the File menu
    /// watches to know whether ⌘⌫ has anything to act on.
    @State private var selection = SidebarSelection()
    /// Vault-relative path of the folder a drop would land in, or nil when
    /// nothing is being dragged over the tree.
    ///
    /// Held here rather than per row because the row under the pointer is
    /// often *not* the row that should light up: hovering a file means "drop
    /// beside it", so its enclosing folder is what highlights, exactly as
    /// Finder does it.
    @State private var dropTarget: String?
    /// Measured only while a reveal is in flight: where that row sits in the
    /// viewport, and how tall the viewport is.
    @State private var revealedRow: CGRect?
    @State private var viewportHeight: CGFloat = 0
    static let treeViewport = "heft.tree.viewport"

    var body: some View {
        VStack(spacing: 0) {
            header

            // Above the lists rather than in them: it is not a fourth way of
            // browsing the vault, it is something waiting for an answer, and
            // it has to be visible whichever list is showing.
            ReviewCenter()

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
            selection = SidebarSelection()
        }
        // Reveal has to happen here as well as in the tree, because the tree
        // may not be what is showing: the sidebar could be on Tags, or filtered
        // down to a search. Putting the list back is the part a view outside
        // the tree has to do, and it is what makes the tree exist for the
        // scroll below to reach.
        .onChange(of: model.revealTarget) { _, target in
            guard target != nil else { return }
            mode = .files
            filter = ""
        }
        .onChange(of: selection) { _, selection in
            // The File menu settles ⌘⌫ when it is built, so what it acts on
            // has to be somewhere it can watch. `sidebarKeys` is that place.
            model.sidebarKeys.selection = selection
        }
        .onChange(of: model.tree) { _, tree in
            // A trashed or moved row must leave the selection, or the next
            // ⌘⌫ asks about files that are already gone and counts them.
            if let tree {
                selection.prune(to: tree.flattened().map(\.relativePath))
                model.sidebarKeys.selection = selection
            }
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
        // ⌘N, which has no field of its own to draw. Answered here rather
        // than in the tree because the tree may not be on screen: switching
        // back from Tags has to happen first, and `beginCreatingNote` does it.
        .onChange(of: model.inlineNoteRequest) { _, request in
            guard let request else { return }
            model.inlineNoteRequest = nil
            guard let target = request.folder ?? noteCreationTarget else { return }
            beginCreatingNote(in: target)
        }
    }

    /// One height for the filter field and the button beside it, so the two
    /// fills read as a pair.
    private static let filterHeight: CGFloat = 28

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
                .frame(height: Self.filterHeight)
                .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 6))

                if mode == .files, model.scopeRoot != nil {
                    Menu {
                        Button("New Note") { createNoteAtCreationTarget() }
                        Button("New Folder") { createFolderAtCreationTarget() }
                    } label: {
                        // A plus, not the pencil: the pencil's box centres
                        // but its square does not, which shows in a 28-point
                        // fill where Notes' larger circle hides it, and the
                        // menu makes folders as well as notes.
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    // The same fill as the filter field beside it and the
                    // mode tabs above, at the field's height and square: a
                    // bare glyph between three filled shapes read as
                    // something that had fallen off. The frame is pinned
                    // here, on the menu, because the menu style discards a
                    // background put on its label and pads a frame put
                    // inside it, so both left the fill smaller than the field.
                    .frame(width: Self.filterHeight, height: Self.filterHeight)
                    .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 6))
                    .help("Create in \(creationTargetName)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var treeList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let tree = model.scopedTree {
                    ForEach(tree.children) { child in
                        TreeRow(
                            item: child, depth: 0,
                            dropTarget: $dropTarget,
                            inlineEdit: $inlineEdit,
                            selectedFolderPath: $selectedFolderPath,
                            selection: $selection
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
        .coordinateSpace(.named(Self.treeViewport))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TreeViewportHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(TreeViewportHeightKey.self) { viewportHeight = $0 }
        .onPreferenceChange(RevealRowFrameKey.self) { revealedRow = $0 }
        .contentShape(.rect)
        .contextMenu { rootContextActions }
        // Blank space below the rows: the vault root, or the focused folder,
        // is what ⌘V pastes into and what the + button creates in.
        .onTapGesture {
            selectedFolderPath = nil
            selection = SidebarSelection()
            model.highlightedPath = nil
            model.sidebarKeyboardTarget = model.scopeRoot
        }
        // `task(id:)` rather than `onChange`, because the tree may not have
        // existed when the request was made: switching back from Tags builds
        // it afterwards, and an `onChange` on a view that appears later never
        // sees the value it appeared *because of*. A task runs on appear too.
        //
        // Asking to scroll to a row that does not exist yet scrolls nowhere at
        // all, and there are two separate reasons it might not exist.
        //
        // A note that was *just created* is on disk before it is in the tree:
        // `reload` starts a rescan and returns, so the row arrives whenever
        // the scan finishes. A fixed delay is a guess about that, and the
        // guess was wrong — a new note never scrolled into view. So wait for
        // the row itself, bounded, and give up quietly rather than hanging on
        // a path that will never appear.
        //
        // Then the shorter wait, which is the original one: the lazy stack
        // still has to build the rows inside the folders just expanded.
        .task(id: model.revealTarget) {
            guard let target = model.revealTarget else { return }
            selectedFolderPath = nil
            for _ in 0..<60 {
                if model.tree?.flattened().contains(where: { $0.relativePath == target }) == true {
                    break
                }
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            // A row already on screen is not scrolled to. Moving the list
            // under a reader who can see the thing already is the part that
            // reads as the app losing their place.
            if RevealScroll.needsScrolling(row: revealedRow, inViewportOfHeight: viewportHeight) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(SidebarAnchor(path: target), anchor: .center)
                }
            }
            model.finishReveal()
        }
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
    }

    @ViewBuilder
    private var rootContextActions: some View {
        if let root = model.scopeRoot {
            MenuButton("New Note", symbol: "square.and.pencil") { beginCreatingNote(in: root) }
            MenuButton("New Folder", symbol: "folder.badge.plus") { beginCreatingFolder(in: root) }
            MenuButton("Paste", symbol: "doc.on.clipboard") { model.paste(into: root) }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!model.canPaste)
            Divider()
            MenuButton("Copy Absolute Path", symbol: "terminal") {
                model.copyToPasteboard(root.path, describedAs: "absolute path")
            }
            MenuButton(
                model.scopePath == nil ? "Reveal Vault in Finder" : "Reveal Focused Folder in Finder",
                symbol: "magnifyingglass"
            ) {
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
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name, isNew: true)
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
            .padding(.top, 8)
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
            .padding(.top, 8)
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
        if let edit = inlineEdit, edit.isNew { model.discardUnnamedNote(at: edit.path) }
        inlineEdit = nil
    }

    private func commitRename(_ item: VaultItem) {
        guard let edit = inlineEdit, edit.path == item.relativePath else { return }
        guard edit.name != item.name else {
            inlineEdit = nil
            // A new note that kept the name it was offered still has a name,
            // and nothing has opened it yet.
            if edit.isNew {
                model.open(item: item)
                model.focusEditor()
            }
            return
        }
        if !model.rename(item, to: edit.name, thenOpen: edit.isNew) {
            inlineEdit = nil
        }
    }
}

/// A row's scroll anchor.
///
/// Its own type rather than the row's path as a `String`: the tree's rows come
/// from `ForEach` over `VaultItem`, whose `id` *is* that path, so an explicit
/// `.id(path)` would put two elements under one identifier in the same scroll
/// namespace and leave which one is scrolled to up to SwiftUI.
struct SidebarAnchor: Hashable {
    let path: String
}

private struct TreeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    let depth: Int
    @Binding var dropTarget: String?
    @Binding var inlineEdit: SidebarInlineEdit?
    @Binding var selectedFolderPath: String?
    @Binding var selection: SidebarSelection

    @State private var springLoad: Task<Void, Never>?

    /// Points the keys at this row, without disturbing the selection.
    ///
    /// A right-click is a click: copying from the menu and then pressing ⌘V
    /// has to paste somewhere, and before this the keys were still aimed at
    /// whatever was left-clicked last, which could be nothing at all. The
    /// selection is deliberately untouched, since right-clicking inside one
    /// acts on all of it and right-clicking outside acts on the row alone,
    /// and both of those are decided by `target(clicking:)` rather than here.
    private func aimKeyboard() {
        if model.sidebarKeyboardTarget != item.url { model.sidebarKeyboardTarget = item.url }
    }

    /// What a drag starting on this row carries: the whole selection when
    /// this row is part of it, and this row alone otherwise. Dragging a row
    /// the reader has not selected must not quietly move the files they
    /// selected a minute ago and forgot about.
    private var draggedURLs: [URL] {
        let paths = selection.target(clicking: item.relativePath)
        guard paths.count > 1 else { return [item.url] }
        return model.items(for: paths).map(\.url)
    }

    /// Applies the click that just happened to the selection, and says
    /// whether it was a plain one. Only a plain click opens the note or
    /// folds the folder: command and shift are the reader gathering rows,
    /// and opening a note on the way past would swap the editor out from
    /// under a selection they are still building.
    @discardableResult
    private func selectOnClick() -> Bool {
        let flags = NSEvent.modifierFlags
        let click = SidebarSelection.click(
            command: flags.contains(.command), shift: flags.contains(.shift)
        )
        selection.click(
            item.relativePath, click,
            visible: SidebarSelection.visibleOrder(
                of: model.scopedTree?.children ?? [], expanded: model.expandedFolders
            )
        )
        return click == .plain
    }

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
                isSelected: SidebarHighlight.litsFolder(
                    item.relativePath,
                    highlighted: model.highlightedPath,
                    selectedFolder: selectedFolderPath,
                    selected: selection.paths
                ),
                depth: depth,
                symbol: isExpanded ? "folder.fill" : "folder",
                disclosure: isExpanded,
                isDropTargeted: dropTarget == item.relativePath,
                renameText: renameBinding,
                onRenameCommit: commitRename,
                onRenameCancel: cancelRename
            ) {
                let plain = selectOnClick()
                model.highlightedPath = nil
                model.sidebarKeyboardTarget = item.url
                guard plain else { return }
                selectedFolderPath = item.relativePath
                if isExpanded { model.expandedFolders.remove(item.relativePath) }
                else { model.expandedFolders.insert(item.relativePath) }
            }
            .id(SidebarAnchor(path: item.relativePath))
            .background { revealProbe }
            .contextMenu {
                FolderMenu(
                    item: item,
                    onCreateNote: { beginCreatingNote(in: item.url) },
                    onCreateFolder: { beginCreatingFolder(in: item.url) },
                    onRename: beginRename
                )
                .onAppear { aimKeyboard() }
            }
            // Simultaneous, so the row's button still gets its click: this
            // only fires once the pointer has actually travelled.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        aimKeyboard()
                        beginFileDrag(for: draggedURLs)
                    }
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
                        selectedFolderPath: $selectedFolderPath,
                        selection: $selection
                    )
                }
            }
        } else {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: SidebarHighlight.litsFile(
                    item.relativePath,
                    highlighted: model.highlightedPath,
                    current: model.current?.relativePath,
                    selectedFolder: selectedFolderPath,
                    selected: selection.paths
                ),
                depth: depth,
                symbol: symbol(for: item.kind),
                isDimmed: item.needsDownload,
                renameText: renameBinding,
                onRenameCommit: commitRename,
                onRenameCancel: cancelRename
            ) {
                let plain = selectOnClick()
                selectedFolderPath = nil
                model.highlightedPath = nil
                // The row stays the keyboard's subject until the text is
                // clicked or typed into: ⌘C then ⌘V here duplicates the file.
                model.sidebarKeyboardTarget = item.url
                guard plain else { return }
                model.open(item: item)
            }
            .id(SidebarAnchor(path: item.relativePath))
            .background { revealProbe }
            .contextMenu {
                FileMenu(
                    item: item,
                    selected: selection.target(clicking: item.relativePath),
                    onCreateNote: { beginCreatingNote(in: destination) },
                    onRename: beginRename
                )
                .onAppear { aimKeyboard() }
            }
            // Simultaneous, so the row's button still gets its click: this
            // only fires once the pointer has actually travelled.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        aimKeyboard()
                        beginFileDrag(for: draggedURLs)
                    }
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

    /// Reports this row's place in the viewport, but only while it is the
    /// row being revealed: one probe during a reveal, not one per row.
    @ViewBuilder
    private var revealProbe: some View {
        if model.revealTarget == item.relativePath {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: RevealRowFrameKey.self,
                    value: geometry.frame(in: .named(SidebarView.treeViewport))
                )
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
        guard let edit = inlineEdit, edit.path == item.relativePath else { return }
        if edit.isNew { model.discardUnnamedNote(at: edit.path) }
        inlineEdit = nil
    }

    private func commitRename() {
        guard let edit = inlineEdit, edit.path == item.relativePath else { return }
        guard edit.name != item.name else {
            inlineEdit = nil
            if edit.isNew {
                model.open(item: item)
                model.focusEditor()
            }
            return
        }
        if !model.rename(item, to: edit.name, thenOpen: edit.isNew) {
            inlineEdit = nil
        }
    }

    private func beginCreatingNote(in folder: URL) {
        guard let created = model.createUntitledNote(in: folder) else { return }
        inlineEdit = SidebarInlineEdit(path: created.path, name: created.name, isNew: true)
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
    beginFileDrag(for: [url], allowsInternalMove: allowsInternalMove)
}

/// Starts a drag carrying every URL given.
///
/// Several rows travel as several dragging items, which is what lets one
/// drop move all of them: the destination reads a list either way, and
/// always could, since a drag out of the Finder can carry any number.
@MainActor
func beginFileDrag(for urls: [URL], allowsInternalMove: Bool = true) {
    // `onChanged` repeats for the whole gesture; a session is already running.
    guard !FileDragSource.shared.isDragging,
          !urls.isEmpty,
          let event = NSApp.currentEvent,
          let view = event.window?.contentView
    else { return }

    let origin = view.convert(event.locationInWindow, from: nil)
    let items = urls.map { url -> NSDraggingItem in
        let item = NSDraggingItem(pasteboardWriter: fileDragPasteboardWriter(for: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        item.setDraggingFrame(
            NSRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32),
            contents: icon
        )
        return item
    }

    FileDragSource.shared.isDragging = true
    FileDragSource.shared.allowsInternalMove = allowsInternalMove
    view.beginDraggingSession(with: items, event: event, source: FileDragSource.shared)
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

/// Which rows the tree draws as lit.
///
/// Two rows can be lit at once, on purpose. The note being read keeps its
/// row for as long as it is open; the light a reveal puts on a row is a
/// marker for what just arrived, it lasts a couple of seconds, and taking
/// the selection off the open note for those seconds would be a worse lie
/// than showing both.
enum SidebarHighlight {
    /// A selected row is lit whatever else is true. Once the reader has
    /// picked rows out by hand, that is what the light is about: showing the
    /// open note instead would hide one of the files they are about to act
    /// on. With nothing picked, the older rules stand unchanged.
    static func litsFile(
        _ path: String, highlighted: String?, current: String?, selectedFolder: String?,
        selected: Set<String> = []
    ) -> Bool {
        if selected.contains(path) { return true }
        if !selected.isEmpty { return false }
        if highlighted == path { return true }
        return selectedFolder == nil && current == path
    }

    static func litsFolder(
        _ path: String, highlighted: String?, selectedFolder: String?,
        selected: Set<String> = []
    ) -> Bool {
        if selected.contains(path) { return true }
        if !selected.isEmpty { return false }
        return highlighted == path || selectedFolder == path
    }
}

/// Whether a reveal has to move the list.
///
/// A row already on screen is left where it is: scrolling the tree under a
/// reader who can already see the thing is what reads as the app losing
/// their place. A row that was never measured is scrolled to, since not
/// knowing where it is means it is probably not in front of them.
enum RevealScroll {
    /// Slack at both edges, so a row flush with the viewport counts as seen
    /// rather than nudging the whole list by a few points.
    static let margin: CGFloat = 4

    static func needsScrolling(row: CGRect?, inViewportOfHeight height: CGFloat) -> Bool {
        guard let row, height > 0 else { return true }
        return row.minY < -margin || row.maxY > height + margin
    }
}

/// Where the row being revealed sits inside the tree's viewport, and how
/// tall that viewport is. Only the revealed row reports itself, so this
/// costs one probe during a reveal rather than one per row per layout.
private struct RevealRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct TreeViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Actions on a note or attachment.
private struct FileMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    /// The rows this menu acts on: the whole selection when the clicked row
    /// is inside it, that row alone otherwise. Everything that reads as
    /// acting on "these files" uses it; renaming does not, because renaming
    /// several files at once means nothing here.
    var selected: [String] = []
    var onCreateNote: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    private var items: [VaultItem] { model.items(for: selected) }
    private var many: Bool { items.count > 1 }

    var body: some View {
        // Every item carries a symbol: macOS 26 draws them in menus, and a
        // menu this long is read by shape before it is read by word.
        MenuButton("Open", symbol: "doc.text") { model.open(item: item) }
        if !item.isMarkdown {
            MenuButton("Open in Default App", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.open(item.url)
            }
        }
        Divider()
        MenuButton("New Note Here", symbol: "square.and.pencil") {
            if let onCreateNote { onCreateNote() }
            else { model.createNote(in: item.url.deletingLastPathComponent()) }
        }
        MenuButton("Rename", symbol: "pencil") {
            if let onRename { onRename() }
            else { model.rename(item) }
        }
        MenuButton(many ? "Move \(items.count) Items to…" : "Move to…", symbol: "folder") {
            many ? model.promptToMove(items) : model.promptToMove(item)
        }
        MenuButton("Duplicate", symbol: "plus.square.on.square") { model.duplicate(item) }
        Divider()
        // The file itself, for pasting into a folder here or in the Finder.
        // The vault-relative path is what a link needs; the absolute one is
        // what a terminal or another app needs. All three are worth having.
        //
        // The shortcut is shown rather than bound: the content of a context
        // menu is built when it opens, so this draws the ⌘C a reader is
        // looking for without registering a second handler for it. What the
        // key actually does is decided in the text view, which holds the
        // keyboard, against the row clicked last.
        MenuButton(many ? "Copy \(items.count) Items" : "Copy", symbol: "doc.on.doc") {
            many ? model.copy(items) : model.copy(item)
        }
            .keyboardShortcut("c", modifiers: .command)
        MenuButton("Paste", symbol: "doc.on.clipboard") {
            model.paste(into: item.url.deletingLastPathComponent())
        }
        .keyboardShortcut("v", modifiers: .command)
        .disabled(!model.canPaste)
        MenuButton("Copy Path", symbol: "arrow.right.doc.on.clipboard") {
            model.copyToPasteboard(item.relativePath, describedAs: "path")
        }
        MenuButton("Copy Absolute Path", symbol: "terminal") {
            model.copyToPasteboard(item.url.path, describedAs: "absolute path")
        }
        if item.isMarkdown {
            MenuButton("Copy Wikilink", symbol: "link") {
                model.copyToPasteboard("[[\(item.name)]]", describedAs: "wikilink")
            }
        }
        MenuButton("Reveal in Finder", symbol: "magnifyingglass") {
            model.revealInFinder(item.url)
        }
        Divider()
        MenuButton(
            many ? "Move \(items.count) Items to Trash" : "Move to Trash",
            symbol: "trash", role: .destructive
        ) {
            many ? model.delete(items) : model.delete(item)
        }
            .keyboardShortcut(.delete, modifiers: .command)
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
        MenuButton("Focus This Window on \"\(item.name)\"", symbol: "scope") {
            model.setScope(to: item)
        }
        MenuButton("Open \"\(item.name)\" in New Window", symbol: "plus.rectangle.on.rectangle") {
            openWindow(value: model.descriptor(scopePath: item.relativePath))
        }
        Divider()
        MenuButton("New Note", symbol: "square.and.pencil") { onCreateNote() }
        MenuButton("New Folder", symbol: "folder.badge.plus") { onCreateFolder() }
        Divider()
        MenuButton("Rename", symbol: "pencil") { onRename() }
        MenuButton("Move to…", symbol: "folder") { model.promptToMove(item) }
        MenuButton("Duplicate", symbol: "plus.square.on.square") { model.duplicate(item) }
        Divider()
        MenuButton("Copy", symbol: "doc.on.doc") { model.copy(item) }
            .keyboardShortcut("c", modifiers: .command)
        MenuButton("Paste", symbol: "doc.on.clipboard") { model.paste(into: item.url) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!model.canPaste)
        MenuButton("Copy Path", symbol: "arrow.right.doc.on.clipboard") {
            model.copyToPasteboard(item.relativePath, describedAs: "path")
        }
        MenuButton("Copy Absolute Path", symbol: "terminal") {
            model.copyToPasteboard(item.url.path, describedAs: "absolute path")
        }
        MenuButton("Reveal in Finder", symbol: "magnifyingglass") {
            model.revealInFinder(item.url)
        }
        Divider()
        MenuButton("Move to Trash", symbol: "trash", role: .destructive) { model.delete(item) }
            .keyboardShortcut(.delete, modifiers: .command)
    }
}

/// Internal rather than private so a snapshot test can draw one. The rows
/// are the one part of multi-select with no value to check: whether a
/// selected row actually looks selected is a question about pixels.
struct NoteRow: View {
    @Environment(\.appAccent) private var accent
    // From the environment, not from an `@ObservedObject` here: this view is
    // one row of hundreds and `AppModel` publishes on every keystroke, so
    // observing per row opened a subscription per row per keystroke to answer
    // a question the whole tree shares. `appAccentTint` observes once.
    @Environment(\.showsFolderArrows) private var showsFolderArrows

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
            if let disclosure, showsFolderArrows {
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
