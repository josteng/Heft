import HeftCore
import SwiftUI

/// Incoming links to the open note, plus its unresolved outgoing links.
struct BacklinksPanel: View {
    @EnvironmentObject private var model: AppModel

    private var backlinks: [Backlink] {
        guard let current = model.current else { return [] }
        return model.index.backlinks(to: current.relativePath)
    }

    private var unresolved: [WikiLink] {
        guard let current = model.current else { return [] }
        return model.index.unresolvedLinks(from: current.relativePath, source: current)
    }

    /// Grouped by source note: one note may reference this one several times.
    private var grouped: [(note: NoteRef, links: [Backlink])] {
        Dictionary(grouping: backlinks, by: \.source)
            .map { (note: $0.key, links: $0.value.sorted { $0.line < $1.line }) }
            .sorted { $0.note.name.localizedStandardCompare($1.note.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                section(
                    title: "Linked mentions",
                    count: backlinks.count,
                    isEmpty: grouped.isEmpty,
                    emptyText: "No other note links here yet."
                ) {
                    ForEach(grouped, id: \.note.id) { group in
                        BacklinkGroup(note: group.note, links: group.links)
                    }
                }

                if !unresolved.isEmpty {
                    section(
                        title: "Unresolved links",
                        count: unresolved.count,
                        isEmpty: false,
                        emptyText: ""
                    ) {
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, link in
                            Button {
                                model.follow(link)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.dashed").font(.system(size: 10))
                                    Text(link.displayText).font(.system(size: 12)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.unresolvedLinkColor)
                            .help("Create this note")
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func section(
        title: String, count: Int, isEmpty: Bool, emptyText: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: .capsule)
                    .foregroundStyle(.secondary)
            }
            if isEmpty {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                content()
            }
        }
    }
}

private struct BacklinkGroup: View {
    @EnvironmentObject private var model: AppModel
    let note: NoteRef
    let links: [Backlink]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.open(note) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 10))
                    Text(note.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ForEach(links) { link in
                Text(highlighted(link.context))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                    .onTapGesture { model.open(note) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
    }

    /// Renders the surrounding line with the link text emphasised, so the
    /// mention is findable at a glance.
    private func highlighted(_ context: String) -> AttributedString {
        var attributed = AttributedString(context)
        for segment in WikiLinkParser.segments(in: context) {
            guard case .link(let link) = segment else { continue }
            let needle = link.displayText
            guard !needle.isEmpty, let range = attributed.range(of: needle) else { continue }
            attributed[range].foregroundColor = .accentColor
            attributed[range].font = .system(size: 11, weight: .medium)
        }
        return attributed
    }
}
