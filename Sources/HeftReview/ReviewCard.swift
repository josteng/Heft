import HeftCore
import SwiftUI

/// Everything an agent is waiting on, as a panel docked at the foot of the
/// sidebar, on the Mac and on an iPad alike.
///
/// The per-note banner was the only way to review agent work, and two things
/// ran it out. A proposal for a note that does not exist has no note to draw a
/// banner above, so it could not be reached from the app at all. And a change
/// spanning several notes was several unrelated proposals: accepting seven of
/// twelve left the vault half-changed with nothing recording that they belonged
/// together.
///
/// At the foot, above the calendar, in a place of its own. At the top it had
/// only two places, and both were wrong: under the Files, Recent and Tags
/// picker it read as part of whichever list was chosen, though it changes
/// with none of them, and above the picker it pushed the picker and the
/// filter down whenever a proposal came and back up when the last was
/// answered.
///
/// **The banner stays.** Seeing a diff where you are reading it is the part
/// that already works. The rule that keeps the two from fighting is *one
/// banner per note, ever*: a note whose change belongs to a group gets a line
/// saying so and a way in here, never a second banner stacked on the first.
struct ReviewCard: View {
    let pending: ProposalStore.Pending
    let review: (Proposal) -> Void
    let discard: (Proposal) -> Void
    let acceptGroup: (ProposalGroup) -> Void
    let discardGroup: (ProposalGroup) -> Void
    @State private var isExpanded = true
    @State private var openGroups: Set<String> = []
    @State private var rowsHeight: CGFloat = 0
    /// Whether the rows are scrolled to their top, where a swipe down folds
    /// the panel rather than scrolling.
    @State private var rowsAtTop = true

    /// The most the rows take before they scroll, so a long list of
    /// proposals cannot push the notes out of the sidebar.
    private static let tallest: CGFloat = 240

    var body: some View {
        if !pending.isEmpty {
            VStack(spacing: 0) {
                header
                if isExpanded {
                    ScrollView {
                        rows
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                rowsHeight = $0
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y <= 1 - geometry.contentInsets.top
                    } action: { _, top in
                        rowsAtTop = top
                    }
                    .frame(height: min(rowsHeight, Self.tallest))
                }
            }
            #if os(iOS)
            // A sheet's gesture, anywhere on the panel: down folds the rows
            // into the header, up opens them again. Down folds only with
            // the rows scrolled to their top, so a long list still scrolls
            // back up first, as a sheet's content does; taps on a row stay
            // taps, since a swipe has to move first.
            .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                let y = drag.translation.height
                guard abs(y) > abs(drag.translation.width) * 1.5, abs(y) > 30 else { return }
                if y > 0, isExpanded, rowsAtTop {
                    withAnimation(.snappy) { isExpanded = false }
                } else if y < 0, !isExpanded {
                    withAnimation(.snappy) { isExpanded = true }
                }
            })
            #endif
            // Docked, as a sheet's edge is: the sidebar's full width, its
            // top rounded, ending on the calendar or the sidebar's foot,
            // and laid over the list's foot as a bottom inset, so the list
            // scrolls on behind it. Inset as a card, or stacked under the
            // list, a strip of sidebar showed above it like a border.
            .background {
                ZStack {
                    Self.shape.fill(ReviewStyle.panelBase)
                    Self.shape.fill(.tint.opacity(ReviewStyle.panelTint))
                }
                .shadow(color: .black.opacity(0.10), radius: 6, y: -1)
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private static let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(pending.groups) { group in
                groupRow(group)
                if openGroups.contains(group.id) {
                    ForEach(group.proposals) { proposal in
                        row(proposal, depth: 1)
                    }
                    groupActions(group)
                }
            }
            ForEach(pending.edits) { row($0, depth: 0) }
            ForEach(pending.structural) { row($0, depth: 0) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(ReviewStyle.cardSymbol)
                    .foregroundStyle(.tint)
                Text("Waiting for Review")
                    .font(ReviewStyle.cardTitle)
                    .foregroundStyle(Color.primary)
                Text("\(pending.count)")
                    .font(ReviewStyle.cardCount)
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(ReviewStyle.cardChevron)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            // More above than below: the last row ends its own padding and
            // the list's above the panel's foot, and the header, as tight
            // to the rounded top as it is to the rows, read as crowded.
            .padding(.top, ReviewStyle.cardHeaderPadding + 4)
            .padding(.bottom, ReviewStyle.cardHeaderPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // No grabber, though the panel swipes like a sheet: the chevron
        // already says it folds, and a grabber cost the panel a row's
        // height.
    }

    private func groupRow(_ group: ProposalGroup) -> some View {
        Button {
            if openGroups.contains(group.id) { openGroups.remove(group.id) }
            else { openGroups.insert(group.id) }
        } label: {
            ProposalGroupLabel(group: group, isOpen: openGroups.contains(group.id))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, ReviewStyle.cardRowPadding)
        .contextMenu {
            MenuButton("Accept All \(group.proposals.count) Changes", symbol: "checkmark") {
                acceptGroup(group)
            }
            MenuButton("Discard", symbol: "xmark", role: .destructive) {
                discardGroup(group)
            }
        }
    }

    /// Accepting or discarding a whole group, under the group when it is open.
    ///
    /// Not on the row itself: the row *is* the disclosure control, and a
    /// destructive button on a control whose job is to toggle invites the
    /// misclick it would be there to save. Named with its count, because
    /// "Accept All" already means every *hunk* of one proposal one sheet
    /// away. And it matters: applying a group is deliberately not atomic, so
    /// accepting members one at a time can leave the vault half-changed.
    private func groupActions(_ group: ProposalGroup) -> some View {
        HStack(spacing: 6) {
            Button("Accept All \(group.proposals.count) Changes") { acceptGroup(group) }
                .buttonStyle(.borderedProminent)
                .lineLimit(1)
            Button("Discard", role: .destructive) { discardGroup(group) }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .controlSize(ReviewStyle.controls)
        .font(ReviewStyle.cardGroupActions)
        // Lined up with the member rows above it, which sit at depth 1.
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .padding(.top, 3)
        .padding(.bottom, 5)
    }

    private func row(_ proposal: Proposal, depth: Int) -> some View {
        Button {
            review(proposal)
        } label: {
            ProposalRowLabel(proposal: proposal)
                .padding(.leading, CGFloat(depth) * 14 + 6)
                .padding(.trailing, 6)
                .padding(.vertical, ReviewStyle.cardRowPadding)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            MenuButton("Review", symbol: "eye") { review(proposal) }
            MenuButton("Discard", symbol: "xmark", role: .destructive) { discard(proposal) }
        }
    }
}
