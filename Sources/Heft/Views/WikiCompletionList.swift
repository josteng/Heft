import HeftCore
import SwiftUI

/// One row of a completion menu.
///
/// Deliberately not "a note": the same panel now offers callout kinds, and
/// carrying a `NoteRef` meant the panel could only ever answer one kind of
/// question. Title, detail and symbol are what a row actually draws.
struct WikiCompletionItem {
    let title: String
    let detail: String
    let symbol: String
    /// What accepting this row writes.
    let destination: String

    init(title: String, detail: String, symbol: String, destination: String) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.destination = destination
    }

    init(ref: NoteRef, destination: String) {
        title = ref.name
        detail = ref.folder
        symbol = switch ref.kind {
        case .markdown: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .canvas: "square.on.square.dashed"
        default: "doc"
        }
        self.destination = destination
    }

    init(callout: CalloutSuggestion) {
        title = callout.kind.rawValue
        // The spelling that was typed, when it was not the canonical name, so
        // it is clear why `tldr` offered `abstract`.
        detail = callout.matchedAlias ?? ""
        symbol = callout.kind.symbol
        destination = callout.insertion
    }
}

enum WikiCompletionMetrics {
    static let width: CGFloat = 390
    static let rowHeight: CGFloat = 34
    static let padding: CGFloat = 4
    static let rowCornerRadius: CGFloat = 6
    /// The row's radius plus the inset, so the selected row's corners run
    /// parallel to the menu's.
    static let cornerRadius: CGFloat = rowCornerRadius + padding

    static func height(rows: Int) -> CGFloat { padding * 2 + CGFloat(rows) * rowHeight }

    /// A view with no window or scroll view can report an unbounded height,
    /// and that must not trap on the way to an `Int`.
    static func rows(fitting height: CGFloat) -> Int {
        let rows = ((height - padding * 2) / rowHeight).rounded(.down)
        guard rows.isFinite else { return rows > 0 ? Int(Int32.max) : 0 }
        return Int(max(0, min(rows, CGFloat(Int32.max))))
    }
}

/// The menu itself, with no AppKit in it: the host decides where it sits.
///
/// Rows are keyed by what accepting them writes, so as the query narrows a
/// surviving row slides to its new place, a dropped one fades as the glass
/// closes over it, and a new one is revealed as the glass opens.
struct WikiCompletionList: View {
    struct Row: Identifiable {
        let id: String
        let item: WikiCompletionItem
    }

    let rows: [Row]
    let selected: Int
    /// How many rows the space beside the caret holds; the rest scroll.
    let visibleRows: Int
    /// Placed above the caret, the menu is pinned at its bottom edge and
    /// grows upwards.
    let growsUp: Bool
    let accent: Color
    let pick: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    static func rows(for items: [WikiCompletionItem]) -> [Row] {
        // Two rows writing the same thing would share an identity, which
        // `ForEach` cannot tell apart.
        var seen: [String: Int] = [:]
        return items.map { item in
            let count = seen[item.destination, default: 0]
            seen[item.destination] = count + 1
            return Row(id: count == 0 ? item.destination : "\(item.destination)#\(count)", item: item)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WikiCompletionMetrics.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            if !rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                WikiCompletionRowView(
                                    item: row.item, selected: index == selected,
                                    hovered: hovered == row.id, accent: accent
                                )
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside {
                                            hovered = row.id
                                        } else if hovered == row.id {
                                            hovered = nil
                                        }
                                    }
                                    .onTapGesture { pick(index) }
                                    .accessibilityAction { pick(index) }
                                    .transition(.opacity)
                            }
                        }
                    }
                    .scrollDisabled(rows.count <= visibleRows)
                    .frame(height: CGFloat(min(rows.count, max(1, visibleRows))) * WikiCompletionMetrics.rowHeight)
                    // Keeps the row the arrow keys reached in view.
                    .onChange(of: selected) { reveal(in: proxy) }
                    .onChange(of: rows.map(\.id)) { reveal(in: proxy) }
                }
                .padding(WikiCompletionMetrics.padding)
                .frame(width: WikiCompletionMetrics.width)
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                // Opening fades in; closing is immediate, because it follows
                // a pick or the caret leaving, and lingering reads as lag.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: growsUp ? .bottom : .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: rows.map(\.id))
    }

    private func reveal(in proxy: ScrollViewProxy) {
        guard rows.count > visibleRows, rows.indices.contains(selected) else { return }
        proxy.scrollTo(rows[selected].id)
    }
}

struct WikiCompletionRowView: View {
    let item: WikiCompletionItem
    let selected: Bool
    /// Under the pointer: a faint fill, so a click's target shows, without
    /// moving the selection the keys own.
    var hovered = false
    let accent: Color
    /// What the two columns came to, for tests: the folder hint going quietly
    /// to a few points is the failure that matters here.
    var onColumns: ((CompletionColumns.Split) -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
            CompletionColumns(onSplit: onColumns) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.72)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: WikiCompletionMetrics.rowHeight)
        .clipped()
        .background {
            if selected {
                RoundedRectangle(cornerRadius: WikiCompletionMetrics.rowCornerRadius, style: .continuous)
                    .fill(accent)
            } else if hovered {
                RoundedRectangle(cornerRadius: WikiCompletionMetrics.rowCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.08))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.detail.isEmpty ? item.title : "\(item.title), \(item.detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row's name and folder side by side, divided by `CompletionRowLayout`
/// from what each would take whole.
struct CompletionColumns: Layout {
    typealias Split = (title: CGFloat, detail: CGFloat)
    static let gap: CGFloat = 8

    var onSplit: ((Split) -> Void)?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(Self.gap) { $0 + $1.width }
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let natural = subviews.map { ceil($0.sizeThatFits(.unspecified).width) }
        let split = CompletionRowLayout.split(
            available: max(0, bounds.width - Self.gap), title: natural[0], detail: natural[1]
        )
        onSplit?(split)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: split.title, height: bounds.height)
        )
        // A dropped folder goes past the row's clipped edge: a text proposed
        // no width still draws its ellipsis.
        let detailX = split.detail > 0 ? bounds.maxX : bounds.maxX + bounds.width
        subviews[1].place(
            at: CGPoint(x: detailX, y: bounds.midY), anchor: .trailing,
            proposal: ProposedViewSize(width: max(split.detail, 1), height: bounds.height)
        )
    }
}
