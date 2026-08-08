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

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""
    @State private var mode: SidebarMode = .files
    @State private var expandedTags: Set<String> = []

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
    }

    private var header: some View {
        VStack(spacing: 6) {
            // The picker comes first: it decides what the field below filters,
            // so reading top to bottom matches what the controls do.
            modePicker

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(mode.filterPrompt, text: $filter)
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

            // Creating files belongs to the file tree; in the other lists there
            // is no folder for a new note to go into. ⌘N still works from the
            // File menu wherever you are.
            if mode == .files {
                HStack(spacing: 4) {
                    Button { model.createNote() } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                            .font(.system(size: 11))
                    }
                    .help("New note (⌘N)")
                    Spacer(minLength: 0)
                    if let root = model.vaultRoot {
                        Button { model.createFolder(in: root) } label: {
                            Image(systemName: "folder.badge.plus").font(.system(size: 11))
                        }
                        .help("New folder at the vault root")
                    }
                }
                .buttonStyle(.accessoryBar)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let tree = model.tree {
                    ForEach(tree.children) { child in
                        TreeRow(item: child, depth: 0)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
            // Fills the scroll view so right-clicking the empty area below the
            // tree still offers the root-level actions.
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
            .contentShape(.rect)
            .contextMenu {
                if let root = model.vaultRoot {
                    Button("New Note…") { model.createNote(in: root) }
                    Button("New Folder…") { model.createFolder(in: root) }
                    Divider()
                    Button("Reveal Vault in Finder") { model.revealInFinder(root) }
                }
            }
        }
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
                        NoteRow(
                            name: note.name,
                            detail: note.folder,
                            isSelected: model.current?.relativePath == note.relativePath,
                            depth: 1,
                            symbol: "doc.text"
                        ) { model.open(note) }
                        .contextMenu {
                            FileMenu(item: VaultItem(
                                url: note.url, relativePath: note.relativePath,
                                kind: note.kind, name: note.name
                            ))
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
        for tag in model.index.tags(matching: filter) {
            let notes = model.index.notes(taggedWith: tag)
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
                    NoteRow(
                        name: note.name,
                        detail: note.folder,
                        isSelected: model.current?.relativePath == note.relativePath,
                        depth: 0,
                        symbol: "doc.text"
                    ) { model.open(note) }
                    .contextMenu {
                        FileMenu(item: VaultItem(
                            url: note.url, relativePath: note.relativePath,
                            kind: note.kind, name: note.name
                        ))
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
        let matches = model.index.search(filter, limit: 200)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(matches) { note in
                    NoteRow(
                        name: note.name,
                        detail: note.folder,
                        isSelected: model.current?.relativePath == note.relativePath,
                        depth: 0,
                        symbol: "doc.text"
                    ) { model.open(note) }
                    // Search results get the same menu; the tree's `VaultItem`
                    // is not to hand here, so it is rebuilt from the hit.
                    .contextMenu {
                        FileMenu(item: VaultItem(
                            url: note.url, relativePath: note.relativePath,
                            kind: note.kind, name: note.name
                        ))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }
}

private struct TreeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    let depth: Int

    private var isExpanded: Bool { model.expandedFolders.contains(item.relativePath) }

    var body: some View {
        if item.isFolder {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: false,
                depth: depth,
                symbol: isExpanded ? "folder.fill" : "folder",
                disclosure: isExpanded
            ) {
                if isExpanded { model.expandedFolders.remove(item.relativePath) }
                else { model.expandedFolders.insert(item.relativePath) }
            }
            .contextMenu { FolderMenu(item: item) }

            if isExpanded {
                ForEach(item.children) { child in
                    TreeRow(item: child, depth: depth + 1)
                }
            }
        } else {
            NoteRow(
                name: item.name,
                detail: nil,
                isSelected: model.current?.relativePath == item.relativePath,
                depth: depth,
                symbol: symbol(for: item.kind),
                isDimmed: item.needsDownload
            ) { model.open(item: item) }
            .contextMenu { FileMenu(item: item) }
        }
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

// MARK: - Context menus

/// Actions on a note or attachment.
private struct FileMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem

    var body: some View {
        Button("Open") { model.open(item: item) }
        if !item.isMarkdown {
            Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
        }
        Divider()
        Button("New Note Here…") { model.createNote(in: item.url.deletingLastPathComponent()) }
        Button("Rename…") { model.rename(item) }
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
    let item: VaultItem

    var body: some View {
        Button("New Note…") { model.createNote(in: item.url) }
        Button("New Folder…") { model.createFolder(in: item.url) }
        Divider()
        Button("Rename…") { model.rename(item) }
        Button("Copy Path") { model.copyToPasteboard(item.relativePath, describedAs: "path") }
        Button("Reveal in Finder") { model.revealInFinder(item.url) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(item) }
    }
}

private struct NoteRow: View {
    let name: String
    let detail: String?
    let isSelected: Bool
    let depth: Int
    let symbol: String
    var disclosure: Bool? = nil
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 10)
                }
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
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
            }
            .padding(.leading, CGFloat(depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
