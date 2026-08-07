import HeftCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            if filter.isEmpty {
                treeList
            } else {
                filteredList
            }

            if model.isCalendarVisible {
                Divider()
                CalendarPanel()
            }
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter notes", text: $filter)
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
        }
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
