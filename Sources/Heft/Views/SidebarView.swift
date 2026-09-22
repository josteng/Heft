import AppIntents
import AppKit
import Combine
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
    // Observed here, once, for the Recent list's order and layout; the rows
    // read nothing from it. It publishes when a colour is picked, which is
    // rare enough to redraw the sidebar for.
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var filter = ""
    @State private var mode: SidebarMode = .files
    /// Bumped when the session has read a note again, so the Recent list
    /// picks up a new date or first line that no published property carries.
    @State private var contentGeneration = 0
    /// The opening history as the list is showing it, which trails the real
    /// one by `recentSettle`. See `recentList`.
    @State private var settledOpenings: [String] = []
    /// Whether the Recent list has scrolled at all, which is what decides
    /// if the pinned title needs a band behind it. Set only when it changes,
    /// so a scroll does not redraw the sidebar on every frame.
    /// Where each Recent title sits in the scroll view, kept in a reference
    /// so a scroll frame does not redraw the sidebar; only a change of which
    /// title is at the top does.
    @State private var recentTops = RecentHeaderTops()
    @State private var pinnedSection: RecentSection?
    /// A title's height, measured rather than assumed: it is where the list
    /// is cut and where the scroll bar starts.
    @State private var recentHeaderHeight: CGFloat = 33
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
        .onReceive(model.session?.contentChanges.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) {
            if mode == .recent { contentGeneration &+= 1 }
        }
        // Mirrored onto the model for the commands, which are run from a
        // palette that has no row to ask. Through `onChange` rather than a
        // `didSet`, since the tree writes this through its binding and a
        // property observer never sees that.
        .onChange(of: selectedFolderPath) { model.highlightedFolder = selectedFolderPath }
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
        .onChange(of: model.current?.relativePath) { _, path in
            // The light follows the note that is open. Opening one deliberately
            // does not rearrange the tree, but a row left lit from an earlier
            // click points at a note that is no longer open, and while it is
            // lit the open one cannot light at all. The mirror is left to the
            // handler above, which this assignment wakes.
            selection = selection.following(openNote: path)
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

    private var header: some View {
        VStack(spacing: 8) {
            // The picker comes first: it decides what the field below filters,
            // so reading top to bottom matches what the controls do.
            modePicker

            SidebarFilterRow(
                mode: mode,
                filter: $filter,
                creationTargetName: creationTargetName,
                onNewNote: createNoteAtCreationTarget,
                onNewFolder: createFolderAtCreationTarget
            )
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
            // Whatever was chosen before is not what is being shown now.
            // What replaces it is decided once the row exists, below: a
            // folder revealed becomes the chosen one, a note clears it.
            selectedFolderPath = nil
            var revealed: VaultItem?
            for _ in 0..<60 {
                revealed = model.tree?.flattened().first { $0.relativePath == target }
                if revealed != nil { break }
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            }
            // A folder that was searched for is chosen as well as shown: it
            // is where a new note goes, and what the palette's folder verbs
            // act on. Setting this at the click did not survive, because
            // this task clears the choice as the reveal begins.
            if let revealed, revealed.isFolder {
                selectedFolderPath = revealed.relativePath
                model.sidebarKeyboardTarget = revealed.url
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
            // The way back out of a focused folder, beside the verbs about
            // that folder. It is in the title bar's own menu as well, which
            // is where it was easy to walk past: the focus is felt in the
            // tree, so the tree is where the reader looks to undo it.
            if model.scopePath != nil {
                Divider()
                MenuButton("Show the Entire Vault", symbol: "books.vertical") {
                    model.showEntireVault()
                }
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
    /// The real `NSSegmentedControl`, not a SwiftUI `Picker`. It is the
    /// picker *styles* that cannot draw an icon beside a label, which is
    /// what a hand-rolled pill was built for; the control underneath has
    /// taken both for years. Going back to it restores what only AppKit
    /// draws: the resting fill rather than a permanent glass pill, the
    /// hover capsule, the morph between segments, and dragging the
    /// selection across them.
    ///
    /// `.small`, because the three labels with their icons want 209pt and a
    /// sidebar at its 240pt minimum has about 216pt to give. `.regular`
    /// wants 221pt and would be clipped there.
    private var modePicker: some View {
        SegmentedModePicker(mode: $mode, filter: $filter)
            .frame(height: 20)
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
                            siriEntity: model.siriEntity(note: note.relativePath),
                            depth: 1,
                            symbol: "doc.text",
                            renameText: renameBinding(for: item),
                            onRenameCommit: { commitRename(item) },
                            onRenameCancel: cancelRename
                        ) {
                            selectedFolderPath = nil
                            model.open(note)
                        }
                        .simultaneousGesture(fileDrag(note.url))
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

    /// Notes newest first: by when their file was last written, or by when
    /// they were last opened here, as the reader has chosen.
    ///
    /// Dates and first lines come from the session's newest build rather
    /// than the published index, because a prose save publishes nothing;
    /// `contentGeneration` is what redraws this when that build changes.
    private var recentList: some View {
        let _ = contentGeneration
        let order = appearance.recentOrder
        let layout = appearance.recentLayout
        let latest = model.session?.latestIndex ?? .empty
        let source: [NoteRef] = switch order {
        case .opened: settledOpenings
            .compactMap { model.index.note(atRelativePath: $0) }
            .filter(model.isInScope)
        case .edited: (model.session?.recentlyEdited ?? []).filter(model.isInScope)
        }
        let notes = source.filter { note in
            filter.isEmpty
                || note.name.localizedCaseInsensitiveContains(filter)
                || (latest.excerpt(of: note.relativePath) ?? "").localizedCaseInsensitiveContains(filter)
        }
        let dating = RecentDating()
        // Each order is grouped and dated by its own clock: when the file
        // was written, or when it was opened here. A note opened before the
        // opening was recorded has no date and falls under no heading.
        let when: (NoteRef) -> Date? = switch order {
        case .edited: { latest.modificationDate(of: $0.relativePath) }
        case .opened: { model.session?.lastOpened($0.relativePath) }
        }
        let groups = dating.grouped(notes, date: when)
        // The title of the section at the top is a row of its own above the
        // list, and the list begins under it, so a row scrolling away simply
        // leaves the scroll view and the title needs no backing to hide it.
        //
        // Drawn over the list instead, it had to be masked out of, and a
        // mask composites the whole list off screen: its text lost subpixel
        // antialiasing and its hairline dividers disappeared, so the list
        // read as greyed out. Giving the title a surface of its own was the
        // other way, and no material could: each let a selected row's accent
        // through as an even wash of colour over the whole title.
        // The first section's until a later one reaches the top, which is
        // also the answer before any title has been laid out to report its
        // position, as in a list with one section and nothing to scroll.
        let shown = pinnedSection ?? groups.first?.section
        return VStack(spacing: 0) {
            if let shown {
                recentHeader(dating.title(of: shown))
                    .padding(.horizontal, 6)
                    .id(shown)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.12), value: shown)
            }
            list(
                groups, dating: dating, dated: when, layout: layout,
                order: order, empty: notes.isEmpty, latest: latest
            )
        }
    }

    private func list(
        _ groups: [(section: RecentSection?, items: [NoteRef])],
        dating: RecentDating,
        dated when: @escaping (NoteRef) -> Date?,
        layout: RecentLayout,
        order: RecentOrder,
        empty notesAreEmpty: Bool,
        latest: VaultIndex
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: layout == .preview ? 0 : 1) {
                if notesAreEmpty {
                    let nothing = order == .opened ? "Nothing opened yet" : "No notes yet"
                    empty(filter.isEmpty ? nothing : "No matching notes")
                }
                // Keyed by section, not position, so a save that moves a note
                // to the top slides it there and the sections around it stay
                // themselves; keyed by position every row after a new
                // section would be redrawn as a different one.
                ForEach(Array(groups.enumerated()), id: \.element.section) { position, group in
                    // Every title but the first one's, which the row above
                    // the list always carries: rendered here as well, its
                    // hidden twin held a title's worth of space at the top
                    // of the list and left a gap under the real one.
                    if let section = group.section, position > 0 {
                        recentHeader(dating.title(of: section))
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.recentScroll))
                            } action: { frame in
                                recentTops.set(section, top: frame.minY)
                                if abs(recentHeaderHeight - frame.height) > 0.5 {
                                    recentHeaderHeight = frame.height
                                }
                                updatePinnedSection(in: groups)
                            }
                    }
                    ForEach(group.items) { note in
                        recentRow(
                            note,
                            preview: layout == .preview ? NotePreview(
                                date: when(note).map(dating.label(for:)) ?? "",
                                excerpt: latest.excerpt(of: note.relativePath) ?? "",
                                location: .of(note, inVaultNamed: model.vaultName)
                            ) : nil
                        )
                        if layout == .preview, note != group.items.last {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                    // The gap before the next title belongs to the list, not
                    // to the title: inside it, it came along when the title
                    // reached the top, and one up there stood taller than
                    // one at rest.
                    //
                    // Only before a title, though. Notes with no date fall
                    // into a group with none — every note opened before
                    // openings were recorded is one — and a gap in front of
                    // that read as a blank row in the middle of the list.
                    if position < groups.count - 1, groups[position + 1].section != nil {
                        Color.clear.frame(height: 14)
                    }
                }
            }
            .padding(.horizontal, 6)
            // Flush, so the title in the list sits where the one above it
            // does. An order with no titles keeps the gap instead.
            .padding(.top, groups.first?.section == nil ? Self.recentListTop : 0)
            .padding(.bottom, 8)
            // A note that rises after a save slides up rather than jumping;
            // the value is the order alone, so typing a first line does
            // not animate the text.
            .animation(
                .snappy(duration: 0.3),
                value: groups.flatMap { $0.items.map(\.relativePath) }
            )
        }
        .coordinateSpace(name: Self.recentScroll)
        .onChange(of: order) { pinnedSection = nil; recentTops.clear() }
        .onChange(of: filter) { pinnedSection = nil; recentTops.clear() }
        // The opening order settles rather than following the click that
        // caused it: a note opened from this list would otherwise leap to
        // the top from under the pointer, before the reader has seen the
        // note they asked for. The first filling is immediate, since there
        // is nothing on screen to move yet, and a further opening within
        // the wait restarts it.
        .task(id: model.session?.recentPaths ?? []) {
            let opened = model.session?.recentPaths ?? []
            // Only a reordering waits. A list that gained or lost a note has
            // nothing to move, and a rename changes the path of one: shown
            // late, the renamed note would vanish from the list until the
            // wait was over.
            guard !settledOpenings.isEmpty, Set(opened) == Set(settledOpenings) else {
                settledOpenings = opened
                return
            }
            try? await Task.sleep(for: .seconds(Self.recentSettle))
            guard !Task.isCancelled else { return }
            settledOpenings = opened
        }
    }

    /// How long the opening order waits before it rearranges itself.
    private static let recentSettle: TimeInterval = 0.8

    /// The title that has reached the top of the list, or gone past it: the
    /// last such is the one whose rows are showing, and the first section's
    /// when none has. Set only when the answer changes, since a scroll
    /// reports every frame.
    ///
    /// A title that has scrolled away keeps its last position rather than
    /// being forgotten, because the list stops laying out what is far off
    /// screen; forgetting it left a section with no title while its own rows
    /// were still showing.
    private func updatePinnedSection(in groups: [(section: RecentSection?, items: [NoteRef])]) {
        // A title takes over above the list only once its own copy has
        // left the top of the list entirely. Taking over as it arrives
        // showed the same words twice, a line apart, and hiding the copy
        // while it was still there left its empty place behind.
        //
        // Back at the top, none has passed and the first section is the one
        // showing; its own title is not in the list to be measured.
        let pinned = groups.compactMap(\.section).last { section in
            (recentTops.top(of: section) ?? .infinity) <= -recentHeaderHeight + 0.5
        } ?? groups.first?.section
        if pinned != pinnedSection { pinnedSection = pinned }
    }

    static let recentScroll = "heft.recent.scroll"
    /// Above the first row of an order that has no titles to sit there.
    private static let recentListTop: CGFloat = 4
    /// A title's own inset, which puts it over the rows' text rather than
    /// over their left edge.
    private static let recentTitleInset: CGFloat = 8
    /// Between a title and the first row under it.
    private static let recentBandGap: CGFloat = 4

    /// One section title, in the list or drawn over it. Both are inset the
    /// same, so the one takes over from the other without moving.
    private func recentHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            // Brighter than the rest of the sidebar's labels, the way a date
            // reads in Notes.
            .foregroundStyle(.primary)
            .padding(.horizontal, Self.recentTitleInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Self.recentBandGap)
    }

    private func recentRow(_ note: NoteRef, preview: NotePreview?) -> some View {
        let item = VaultItem(
            url: note.url, relativePath: note.relativePath,
            kind: note.kind, name: note.name
        )
        return NoteRow(
            name: note.name,
            detail: preview == nil ? note.folder : nil,
            isSelected: model.current?.relativePath == note.relativePath,
            siriEntity: model.siriEntity(note: note.relativePath),
            depth: 0,
            symbol: "doc.text",
            preview: preview,
            renameText: renameBinding(for: item),
            onRenameCommit: { commitRename(item) },
            onRenameCancel: cancelRename
        ) {
            selectedFolderPath = nil
            model.open(note)
        }
        .simultaneousGesture(fileDrag(note.url))
        .contextMenu {
            FileMenu(
                item: item,
                onCreateNote: { beginCreatingNote(in: note.url.deletingLastPathComponent()) },
                onRename: { beginRename(item) }
            )
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
    }

    /// Folders whose name matches the filter, nearest match first.
    ///
    /// The tree's own furniture, which the filter used to hide: it searched
    /// the index, which knows about notes, so a folder could be typed in
    /// full and nothing came back.
    private func filteredFolders() -> [VaultItem] {
        guard let tree = model.scopedTree else { return [] }
        return FolderSearch.folders(matching: filter, in: tree)
    }

    private var filteredList: some View {
        let folders = filteredFolders()
        let matches = model.searchNotes(filter, limit: 200)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                // Folders first: there are far fewer of them, and someone
                // typing a folder's name is looking for the folder rather
                // than for the notes whose names resemble it.
                ForEach(folders) { folder in
                    let parent = folder.relativePath
                        .split(separator: "/").dropLast().joined(separator: "/")
                    NoteRow(
                        name: folder.name,
                        detail: parent,
                        isSelected: false,
                        siriEntity: model.siriEntity(folder: folder.relativePath),
                        depth: 0,
                        symbol: "folder",
                        renameText: renameBinding(for: folder),
                        onRenameCommit: { commitRename(folder) },
                        onRenameCancel: cancelRename
                    ) {
                        // Found, then shown where it lives: the filter goes,
                        // the tree opens down to it, opens it, and lights it.
                        // A folder cannot be opened as a note, and focusing
                        // the window on one by a single click would be a
                        // large thing to do by accident; its menu offers
                        // that.
                        filter = ""
                        selectedFolderPath = folder.relativePath
                        // The reveal chooses it once its row exists, and
                        // does not blink it: a folder searched for and then
                        // marked as chosen needs no second, louder answer to
                        // the same question.
                        model.revealFolder(folder.relativePath)
                    }
                    .simultaneousGesture(fileDrag(folder.url))
                    .contextMenu {
                        FolderMenu(
                            item: folder,
                            onCreateNote: { beginCreatingNote(in: folder.url) },
                            onCreateFolder: { beginCreatingFolder(in: folder.url) },
                            onRename: { beginRename(folder) }
                        )
                    }
                }
                ForEach(matches) { note in
                    let item = VaultItem(
                        url: note.url, relativePath: note.relativePath,
                        kind: note.kind, name: note.name
                    )
                    NoteRow(
                        name: note.name,
                        detail: note.folder,
                        isSelected: model.current?.relativePath == note.relativePath,
                        siriEntity: model.siriEntity(note: note.relativePath),
                        depth: 0,
                        symbol: "doc.text",
                        renameText: renameBinding(for: item),
                        onRenameCommit: { commitRename(item) },
                        onRenameCancel: cancelRename
                    ) {
                        selectedFolderPath = nil
                        model.open(note)
                    }
                    .simultaneousGesture(fileDrag(note.url))
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

    /// Dragging a note out of a list that is not the tree.
    ///
    /// Simultaneous, so the row's button still gets its click: it only fires
    /// once the pointer has actually travelled. The tree's rows carry their
    /// own, which drags a whole selection; these lists have no selection to
    /// drag, so a row drags itself.
    private func fileDrag(_ url: URL) -> some Gesture {
        DragGesture(minimumDistance: 6).onChanged { _ in beginFileDrag(for: url) }
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

/// The filter field and the menu beside it: the one row of the sidebar's
/// header that differs between the three modes.
///
/// A view of its own so it can be laid out in each mode and measured, which
/// is what keeps the field from growing and shrinking as the modes change.
struct SidebarFilterRow: View {
    /// The height of the field, and the size of the square the menu beside it
    /// sits in. One number, so the two line up.
    static let controlSize: CGFloat = 28

    /// The gap between the field and that square.
    static let spacing: CGFloat = 6

    let mode: SidebarMode
    @Binding var filter: String
    let creationTargetName: String
    let onNewNote: () -> Void
    let onNewFolder: () -> Void

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        HStack(spacing: Self.spacing) {
            // Hand-rolled rather than `NSSearchField`: its capsule bezel
            // is the brightest thing in the sidebar and overhangs its
            // frame, and without the bezel it lays its icon over the text.
            // This one is the tab track's fill, height and shape.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $filter)
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
            .padding(.horizontal, 10)
            .frame(height: Self.controlSize)
            .background(Color(nsColor: .quaternarySystemFill), in: .capsule)

            // The field takes whatever the menu leaves, so a menu that sizes
            // itself moves the field: the plus measured two points narrower
            // than the Recent arrows, and the field grew and shrank between
            // the two modes. Both now sit in a square of the field's own
            // height. Tags keeps the whole row, having nothing to put there.
            if mode == .files, model.scopeRoot != nil {
                // A plus, not the pencil: the menu makes folders as well as
                // notes.
                menu("plus", help: "Create in \(creationTargetName)") {
                    Button("New Note", action: onNewNote)
                    Button("New Folder", action: onNewFolder)
                }
            } else if mode == .recent {
                menu("arrow.up.arrow.down", help: "Order and layout of the Recent list") {
                    Picker("Order", selection: $appearance.recentOrder) {
                        ForEach(RecentOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Show", selection: $appearance.recentLayout) {
                        ForEach(RecentLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }

    private var prompt: String {
        model.scopePath == nil ? mode.filterPrompt : "\(mode.filterPrompt) in \(model.scopeName)"
    }

    private func menu<Content: View>(
        _ symbol: String, help: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Menu { content() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                // The glyphs are not the same width, and a circular glass
                // button measures its label.
                .frame(width: 14, height: 14)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(width: Self.controlSize, height: Self.controlSize)
        .help(help)
    }
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
        let children = model.scopedTree?.children ?? []
        selection.click(
            item.relativePath, click,
            visible: SidebarSelection.visibleOrder(
                of: children, expanded: model.expandedFolders
            ),
            folders: SidebarSelection.visibleFolders(
                of: children, expanded: model.expandedFolders
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

    /// Whether this row is lit, by whichever rule governs its kind.
    private var isLit: Bool {
        item.isFolder
            ? SidebarHighlight.litsFolder(
                item.relativePath, highlighted: model.highlightedPath, selected: selection
            )
            : SidebarHighlight.litsFile(
                item.relativePath, highlighted: model.highlightedPath,
                current: model.current?.relativePath, selected: selection
            )
    }

    /// ...and whether it gets the weaker mark instead, as the row the keys
    /// would act on.
    private var isKeyTarget: Bool {
        SidebarHighlight.marksKeyTarget(
            isTarget: model.keyTargetPath == item.relativePath, lit: isLit, selected: selection
        )
    }

    var body: some View {
        if item.isFolder {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: isLit,
                siriEntity: model.siriEntity(folder: item.relativePath),
                isKeyTarget: isKeyTarget,
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
                isSelected: isLit,
                siriEntity: model.siriEntity(note: item.relativePath),
                isKeyTarget: isKeyTarget,
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
/// `event` is for a caller tracking the mouse itself, whose drag event is not
/// the application's current one.
@MainActor
func beginFileDrag(
    for urls: [URL], allowsInternalMove: Bool = true, event: NSEvent? = nil
) {
    // `onChanged` repeats for the whole gesture; a session is already running.
    guard !FileDragSource.shared.isDragging,
          !urls.isEmpty,
          let event = event ?? NSApp.currentEvent,
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
    /// A row picked out by hand is lit whatever else is true. Once the reader
    /// has chosen files, that is what the light is about: showing the open
    /// note instead would hide one of the files they are about to act on.
    ///
    /// Choosing *folders* is not that, and the difference is the whole reason
    /// the selection is passed rather than its paths. Opening a folder is
    /// navigation, so it lights nothing: not the folder, whose disclosure
    /// arrow and filled icon already say it is open, and not at the cost of
    /// the open note, which is the only row saying what is being edited.
    ///
    /// Which folder is focused is therefore not an input here at all. It
    /// decides where a new note goes; it used to light its row as well, and
    /// that is what took the light off the open note every time one was
    /// browsed.
    static func litsFile(
        _ path: String, highlighted: String?, current: String?,
        selected: SidebarSelection = SidebarSelection()
    ) -> Bool {
        if selected.contains(path) { return true }
        if selected.holdsFile { return false }
        if highlighted == path { return true }
        return current == path
    }

    static func litsFolder(
        _ path: String, highlighted: String?,
        selected: SidebarSelection = SidebarSelection()
    ) -> Bool {
        if selected.contains(path) { return true }
        if selected.holdsFile { return false }
        return highlighted == path
    }

    /// Whether a row gets the weaker mark: the one a keystroke would act on.
    ///
    /// ⌘⌫ and ⌘C take the selection, or the row last clicked when there is
    /// none. A folder browsed into is exactly that second case, and since
    /// opening one stopped lighting it there was nothing on screen saying the
    /// keys were pointing at it. Drawn lighter than a selection because it is
    /// a weaker claim: the keys point here, but nothing has been chosen.
    ///
    /// It needs no rule for going out again. `releaseSidebarKeys` clears the
    /// target the moment the reader types in the note, which is the same
    /// moment the keys stop meaning this.
    static func marksKeyTarget(
        isTarget: Bool, lit: Bool, selected: SidebarSelection = SidebarSelection()
    ) -> Bool {
        // Nothing is marked twice, and a selection speaks for itself: when
        // there is one, that is what the keys act on.
        isTarget && !lit && selected.isEmpty
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

/// Where each pinned Recent title sits; see `SidebarView.recentTops`.
final class RecentHeaderTops {
    private var tops: [RecentSection: CGFloat] = [:]
    func set(_ section: RecentSection, top: CGFloat?) { tops[section] = top }
    func top(of section: RecentSection) -> CGFloat? { tops[section] }
    func clear() { tops = [:] }
}

/// What a Recent row shows under the name in the preview layout.
struct NotePreview: Equatable {
    struct Location: Equatable {
        var name: String
        var symbol: String

        /// Every row names where it lives, so the rows stay one height and
        /// the eye can run down them. A note in the vault's root names the
        /// vault, under the vault's own symbol rather than a folder's, or
        /// its row would claim there is a folder of that name.
        static func of(_ note: NoteRef, inVaultNamed vault: String) -> Location {
            note.folder.isEmpty
                ? Location(name: vault, symbol: "books.vertical")
                : Location(name: note.folder, symbol: "folder")
        }
    }

    var date: String
    var excerpt: String
    var location: Location
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
    /// The note or folder this row is showing, which is what the system's
    /// Ask Siri reads off the view it was opened on. See `SiriContext`.
    var siriEntity: EntityIdentifier? = nil
    /// The weaker mark: what a keystroke would act on, with nothing chosen.
    var isKeyTarget: Bool = false
    let depth: Int
    let symbol: String
    var disclosure: Bool? = nil
    /// The date, first line and folder under the name, or nil for one line.
    var preview: NotePreview? = nil
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
        .namesForSiri(siriEntity)
    }

    @ViewBuilder
    private func rowContents(renameText: Binding<String>?) -> some View {
        if let preview {
            previewContents(preview, renameText: renameText)
        } else {
            lineContents(renameText: renameText)
        }
    }

    /// The name over its date and first line, then the folder: what Notes
    /// shows, so a list of names becomes a list of what is in them. No icon,
    /// since every row here is a note and the name is the biggest thing.
    private func previewContents(_ preview: NotePreview, renameText: Binding<String>?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let renameText {
                TextField("Name", text: renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($isRenameFocused)
                    .onSubmit { finishRename(commit: true) }
                    .onExitCommand { finishRename(commit: false) }
            } else {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // On the accent fill the hierarchical greys sink into it, so a
            // selected row's lines are white at two strengths instead.
            let dateStyle = isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
            let quietStyle = isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary)
            HStack(spacing: 6) {
                if !preview.date.isEmpty {
                    Text(preview.date)
                        .foregroundStyle(dateStyle)
                        .fixedSize()
                }
                Text(preview.excerpt.isEmpty ? "No additional text" : preview.excerpt)
                    .foregroundStyle(quietStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12))
            HStack(spacing: 4) {
                Image(systemName: preview.location.symbol)
                Text(preview.location.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(quietStyle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { rowBackground(cornerRadius: 8) }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    private func lineContents(renameText: Binding<String>?) -> some View {
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
        .background { rowBackground(cornerRadius: 6) }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    @ViewBuilder
    private func rowBackground(cornerRadius: CGFloat) -> some View {
        if isDropTargeted {
            // Outlined rather than filled, so it reads as "into here"
            // rather than as a selection.
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(accent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius).fill(accent.opacity(0.12))
                )
        } else if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius).fill(accent)
        } else if isKeyTarget {
            // A tint rather than the accent itself, and the text keeps its
            // own colour: this row is where the keys point, not something
            // the reader has chosen.
            RoundedRectangle(cornerRadius: cornerRadius).fill(accent.opacity(0.18))
        } else if isHovering {
            RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.06))
        }
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
