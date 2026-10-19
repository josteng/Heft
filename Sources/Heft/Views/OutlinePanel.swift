import HeftCore
import SwiftUI

/// The open note's headings, each indented under the one it sits in, with
/// the caret's own lit. A click takes the caret there.
struct OutlinePanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tracker: OutlineTracker

    var body: some View {
        let entries = tracker.outline.entries
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("HEADINGS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(entries.count)")
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                    if entries.isEmpty {
                        Text(model.current == nil ? "No note is open." : "This note has no headings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, isCurrent: index == tracker.current)
                                    .id(entry.id)
                            }
                        }
                    }
                }
                .padding(14)
            }
            // The caret's heading kept in sight as the note is moved through.
            .onChange(of: tracker.current) { _, current in
                guard let current, entries.indices.contains(current) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(entries[current].id) }
            }
        }
        .onAppear { tracker.watch() }
        .onDisappear { tracker.unwatch() }
    }

    private func row(_ entry: NoteOutline.Entry, isCurrent: Bool) -> some View {
        Button { model.jump(toLine: entry.line) } label: {
            Text(entry.title.isEmpty ? "Untitled heading" : entry.title)
                .font(.system(size: 12, weight: entry.depth == 0 ? .medium : .regular))
                .foregroundStyle(entry.title.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(min(entry.depth, 5)) * 12)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // A wash, as the sidebar marks its row: text in the accent
                // read as dimmed under a grey accent.
                .background(isCurrent ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
