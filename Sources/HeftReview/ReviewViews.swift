import HeftCore
import SwiftUI

// The review of an agent's proposals, drawn the same on the Mac and on iOS.
//
// Every view here is handed values and closures rather than a model: the
// Mac's `AppModel` is an `ObservableObject` and iOS's vault is `@Observable`,
// and a view holding either would redraw on one and not the other. Each app
// wraps these in a few lines that read its own model.

/// The type and control sizes, the Mac's exact points beside iOS's text
/// styles: the Mac's are tuned to a sidebar and a sheet read at a desk, and
/// on a phone they were too small to read or to tap.
enum ReviewStyle {
    #if os(macOS)
    static let titleSymbol = Font.system(size: 15, weight: .semibold)
    static let title = Font.system(size: 14, weight: .semibold)
    static let detail = Font.system(size: 11)
    static let bannerSymbol = Font.system(size: 12, weight: .semibold)
    static let bannerTitle = Font.system(size: 12, weight: .medium)
    static let bannerDetail = Font.system(size: 10.5)
    static let hunkLabel = Font.system(size: 11, weight: .medium)
    static let diff = Font.system(size: 11.5, design: .monospaced)
    static let created = Font.system(size: 12, design: .monospaced)
    static let warning = Font.system(size: 12)
    static let controls = ControlSize.small
    static let rowSymbol = Font.system(size: 10)
    static let rowSymbolWidth: CGFloat = 12
    static let rowTitle = Font.system(size: 11.5)
    static let groupTitle = Font.system(size: 11.5, weight: .medium)
    static let rowDetail = Font.system(size: 9.5)
    static let rowSpacing: CGFloat = 5
    static let bannerRadius: CGFloat = 8
    static let cardSymbol = Font.system(size: 10, weight: .semibold)
    static let cardTitle = Font.system(size: 11, weight: .semibold)
    static let cardCount = Font.system(size: 10, weight: .medium)
    static let cardChevron = Font.system(size: 8, weight: .semibold)
    static let cardGroupActions = Font.system(size: 10.5)
    static let cardRowPadding: CGFloat = 4
    static let cardHeaderPadding: CGFloat = 7
    /// How much accent the docked panel takes. More than the banner's:
    /// on the Mac's dark sidebar, and under the Muted palette, which
    /// softens the accent itself, less hardly showed.
    static let panelTint = 0.22
    /// Under the tint, so the list passing behind the panel is hidden.
    static let panelBase = AnyShapeStyle(.background)
    /// The grey a card without an accent is lifted by.
    static let cardLift = 0.07
    #else
    static let titleSymbol = Font.headline
    static let title = Font.headline
    static let detail = Font.footnote
    static let bannerSymbol = Font.subheadline.weight(.semibold)
    static let bannerTitle = Font.subheadline.weight(.medium)
    static let bannerDetail = Font.caption
    static let hunkLabel = Font.footnote.weight(.medium)
    static let diff = Font.system(.footnote, design: .monospaced)
    static let created = Font.system(.callout, design: .monospaced)
    static let warning = Font.footnote
    static let controls = ControlSize.regular
    static let rowSymbol = Font.body
    static let rowSymbolWidth: CGFloat = 24
    static let rowTitle = Font.body
    static let groupTitle = Font.body.weight(.medium)
    static let rowDetail = Font.footnote
    static let rowSpacing: CGFloat = 10
    static let bannerRadius: CGFloat = 16
    static let cardSymbol = Font.subheadline.weight(.semibold)
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let cardCount = Font.subheadline
    static let cardChevron = Font.footnote.weight(.semibold)
    static let cardGroupActions = Font.subheadline
    static let cardRowPadding: CGFloat = 8
    static let cardHeaderPadding: CGFloat = 10
    static let panelTint = 0.10
    /// Opaque: in the iPad's glass sidebar `.background` is translucent,
    /// and the rows passing behind the panel showed through it.
    static let panelBase = AnyShapeStyle(Color(uiColor: .systemBackground))
    static let cardLift = 0.03
    #endif

    /// Where the other changes of a group are listed.
    #if os(macOS)
    static let restOfGroup = "The rest are in the sidebar."
    #else
    static let restOfGroup = "The rest are listed on Recent."
    #endif

    /// The colour of a row's symbol. On the Mac, grey as the sidebar's
    /// other symbols, a delete in red; on iOS the accent for every kind, as
    /// every other list there draws its symbols, where three colours in one
    /// section read as noise.
    static func rowSymbolStyle(for kind: Proposal.Kind) -> AnyShapeStyle {
        #if os(macOS)
        kind == .delete ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary)
        #else
        AnyShapeStyle(.tint)
        #endif
    }

    /// How a docked card folds and opens: smooth, with no spring, the same
    /// for the review panel and the calendar below it.
    static let fold = Animation.smooth(duration: 0.3)

    /// The symbol a proposal of each kind is listed with.
    static func symbol(for kind: Proposal.Kind) -> String {
        switch kind {
        case .edit: "pencil"
        case .create: "doc.badge.plus"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        }
    }
}

extension EnvironmentValues {
    /// The vault's accent, for what takes a colour rather than the tint:
    /// a swipe action's background is given one outright.
    @Entry var reviewAccent: Color = .accentColor
}

// MARK: - The banner over a note

/// One proposal for the note on screen, as the banner over it shows one.
struct ProposalBannerItem: Identifiable {
    let proposal: Proposal
    let diff: NoteDiff
    let group: ProposalGroup?
    let isStale: Bool
    var id: String { proposal.id }

    @MainActor
    init(_ proposal: Proposal, in reviewer: some ProposalReviewing) {
        let current = reviewer.currentText(for: proposal)
        self.proposal = proposal
        diff = proposal.diff(against: current)
        group = reviewer.group(of: proposal)
        isStale = proposal.isStale(against: current)
    }
}

/// The bar over a note an agent has proposed something for.
///
/// Above the text rather than in the toolbar: a proposal is about *this*
/// note, and a toolbar badge is a thing you learn to stop seeing.
struct ProposalBannerCard: View {
    let items: [ProposalBannerItem]
    /// Over the text rather than above it, as on iOS, where the note runs
    /// on under the bar: a material behind the tint keeps it readable.
    var floats = false
    let review: (Proposal) -> Void
    let discard: (Proposal) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { row(for: $0) }
            }
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: ReviewStyle.bannerRadius))
            .background(floats ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: ReviewStyle.bannerRadius))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func row(for item: ProposalBannerItem) -> some View {
        let proposal = item.proposal
        return HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .font(ReviewStyle.bannerSymbol)

            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.summary)
                    .font(ReviewStyle.bannerTitle)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    #if os(macOS)
                    Text(proposal.agent)
                    #endif
                    Text("+\(item.diff.addedLines)").foregroundStyle(.green)
                    Text("−\(item.diff.removedLines)").foregroundStyle(.red)
                    Text("in \(item.diff.hunks.count) place\(item.diff.hunks.count == 1 ? "" : "s")")
                    // One banner per note, ever. A change that is part of
                    // something larger says so here rather than putting a
                    // second banner above this one.
                    if let group = item.group {
                        Text("· part of “\(group.summary)”, \(group.proposals.count) changes")
                            .lineLimit(1)
                    }
                    if item.isStale {
                        Label("note changed since", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(ReviewStyle.bannerDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Review") { review(proposal) }
                .buttonStyle(.borderedProminent)
            // Not on a phone's width, where it squeezed the line beside it
            // to a few letters; the review it opens has Discard Proposal.
            #if os(macOS)
            Button("Discard") { discard(proposal) }
            #endif
        }
        .controlSize(ReviewStyle.controls)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - The list of what is waiting

/// A proposal as the list of what is waiting shows it: its kind, what the
/// agent said it does, and which note. The colours are named outright: a
/// row is a button, and in an iOS list a button's tint took over `.primary`
/// and `.secondary`, drawing the whole row in the accent.
struct ProposalRowLabel: View {
    let proposal: Proposal

    var body: some View {
        HStack(spacing: ReviewStyle.rowSpacing) {
            Image(systemName: ReviewStyle.symbol(for: proposal.kind))
                .font(ReviewStyle.rowSymbol)
                .foregroundStyle(ReviewStyle.rowSymbolStyle(for: proposal.kind))
                .frame(width: ReviewStyle.rowSymbolWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.summary)
                    .font(ReviewStyle.rowTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(proposal.headline)
                    .font(ReviewStyle.rowDetail)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A group of proposals, one change across several notes, as the list
/// shows it. `isOpen` draws a chevron where the list has none of its own.
struct ProposalGroupLabel: View {
    let group: ProposalGroup
    var isOpen: Bool?

    var body: some View {
        HStack(spacing: ReviewStyle.rowSpacing) {
            Image(systemName: "square.stack.3d.up")
                .font(ReviewStyle.rowSymbol)
                .foregroundStyle(.tint)
                .frame(width: ReviewStyle.rowSymbolWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.summary)
                    .font(ReviewStyle.groupTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("\(group.proposals.count) changes · \(group.agent)")
                    .font(ReviewStyle.rowDetail)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            if let isOpen {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
    }
}

// MARK: - Reviewing an edit

/// The review of an edit: every hunk the agent wants, each answered on its
/// own.
struct ProposalReviewSheet: View {
    let proposal: Proposal
    /// The note as it stands now, which the hunks are measured against.
    let current: String
    let group: ProposalGroup?
    let decide: (_ hunk: Int, _ accept: Bool) -> Void
    let acceptAll: () -> Void
    let discard: () -> Void
    let later: () -> Void
    #if !os(macOS)
    @State private var swipes = 0
    @Environment(\.reviewAccent) private var accent
    #endif

    private var diff: NoteDiff { proposal.diff(against: current) }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(proposal: proposal, detail: "\(proposal.agent) · \(proposal.notePath)") {
                if let group {
                    Text("Part of “\(group.summary)”, \(group.proposals.count) changes. "
                        + ReviewStyle.restOfGroup)
                }
                if proposal.isStale(against: current) {
                    Label(
                        "The note has changed since \(proposal.agent) read it. "
                            + "The changes below are measured against the note as it is now.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Divider()

            let diff = diff
            if diff.isEmpty {
                ContentUnavailableView(
                    "Nothing left to review",
                    systemImage: "checkmark.circle",
                    description: Text("The note already reads the way \(proposal.agent) wanted.")
                )
                .frame(maxHeight: .infinity)
            } else {
                hunks(diff)
            }

            Divider()
            ReviewFooter(discard: discard, later: later) {
                Button("Accept All", action: acceptAll)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(diff.isEmpty)
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 560)
        #endif
    }
}

extension ProposalReviewSheet {
    #if os(macOS)
    private func hunks(_ diff: NoteDiff) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.keyed(diff.hunks), id: \.key) { item in
                    HunkCard(hunk: item.hunk) { accept in answer(item.hunk, accept) }
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        ))
                }
            }
            .padding(16)
        }
    }
    #else
    /// On iOS a list, for its swipes: right accepts a hunk and left rejects
    /// it, as a row under Waiting for Review is accepted or discarded, with
    /// the card's buttons still there. The list's own swipe rather than a
    /// drag on each card, which fought the scrolling and the selecting of
    /// text in the lines; a full swipe decides, a partial one shows the
    /// button.
    private func hunks(_ diff: NoteDiff) -> some View {
        List(Self.keyed(diff.hunks), id: \.key) { item in
            let hunk = item.hunk
            HunkCard(hunk: hunk) { accept in answer(hunk, accept) }
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button("Accept", systemImage: "checkmark") { swiped(hunk, accept: true) }
                        .tint(accent)
                }
                // Red, as Apple's destructive role is for an operation that
                // cannot be undone, which a rejected hunk is: it leaves the
                // proposal for good.
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Reject", systemImage: "xmark", role: .destructive) {
                        swiped(hunk, accept: false)
                    }
                    .tint(.red)
                }
        }
        .listStyle(.plain)
        .contentMargins(.vertical, 9, for: .scrollContent)
        .sensoryFeedback(.impact(weight: .light), trigger: swipes)
    }

    /// A swipe is felt as it decides, the reader's own gesture; a button's
    /// press already is.
    private func swiped(_ hunk: NoteDiff.Hunk, accept: Bool) {
        swipes += 1
        answer(hunk, accept)
    }
    #endif

    /// A decision, animated: the card answered shrinks out and the rest
    /// close up, rather than the list redrawing at once.
    private func answer(_ hunk: NoteDiff.Hunk, _ accept: Bool) {
        withAnimation(.smooth(duration: 0.3)) { decide(hunk.id, accept) }
    }

    /// The hunks, each named by what it changes. Their ids are positions,
    /// re-derived after every decision, so the answered one's id passed to
    /// the next and the list could only snap; named by their lines, the
    /// answered card leaves and the others keep their place. Twins are told
    /// apart by how many came before.
    static func keyed(_ hunks: [NoteDiff.Hunk]) -> [(key: String, hunk: NoteDiff.Hunk)] {
        var seen: [String: Int] = [:]
        return hunks.map { hunk in
            let content = (hunk.removed + ["\u{1}"] + hunk.added).joined(separator: "\n")
            let count = seen[content, default: 0]
            seen[content] = count + 1
            return ("\(count)\u{2}\(content)", hunk)
        }
    }
}

/// What a proposal is and who made it, over its review.
private struct ReviewHeader<Notes: View>: View {
    let proposal: Proposal
    let detail: String
    @ViewBuilder let notes: Notes

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(ReviewStyle.titleSymbol)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.summary).font(ReviewStyle.title)
                Text(detail).foregroundStyle(.secondary)
                Group { notes }.foregroundStyle(.secondary)
            }
            .font(ReviewStyle.detail)
            Spacer()
        }
        .padding(16)
    }
}

/// Discard, Later, and the act itself. Every button says its style: left to
/// `.automatic`, the destructive role picked a different shape from the two
/// beside it, so one footer held two corner radii.
private struct ReviewFooter<Act: View>: View {
    let discard: () -> Void
    let later: () -> Void
    @ViewBuilder let act: Act

    var body: some View {
        HStack {
            Button("Discard Proposal", role: .destructive, action: discard)
                .buttonStyle(.bordered)
            Spacer()
            Button("Later", action: later)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            act
        }
        .padding(12)
    }
}

/// One change, shown the way a diff is: context in grey, the old lines struck
/// through in red, the new ones in green, with its own two buttons.
struct HunkCard: View {
    let hunk: NoteDiff.Hunk
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.reviewLabel)
                    .font(ReviewStyle.hunkLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reject") { decide(false) }
                    .buttonStyle(.bordered)
                Button("Accept") { decide(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(ReviewStyle.controls)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))

            VStack(alignment: .leading, spacing: 0) {
                // Computed once for the card rather than per line: the two
                // sides are paired, so asking a line on its own what changed
                // would mean running the comparison twice for every pair.
                let inline = InlineDiff.spans(removed: hunk.removed, added: hunk.added)
                ForEach(Array(hunk.leading.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .context)
                }
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { index, text in
                    DiffLine(text: text, kind: .removed, spans: inline.removed[index])
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { index, text in
                    DiffLine(text: text, kind: .added, spans: inline.added[index])
                }
                ForEach(Array(hunk.trailing.enumerated()), id: \.offset) { _, text in
                    DiffLine(text: text, kind: .context)
                }
            }
            .padding(.vertical, 6)
        }
        .background(.background.secondary)
        // One rounded container with square content inside, rather than
        // rounded bands nested in a rounded card. Clipped rather than merely
        // backed by the shape, or a full-width row's corner sits outside it.
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 1)
        )
    }
}

/// One line of a diff. Shared so a save-conflict merge and an agent proposal
/// read as the same thing, because to the user they are: another version of
/// this note, decided a hunk at a time.
struct DiffLine: View {
    enum Kind { case context, removed, added }

    let text: String
    let kind: Kind
    /// Which words moved, when this line was compared with its counterpart.
    /// Nil where there was nothing to compare it against, or where the two
    /// lines had too little in common to mark up honestly.
    var spans: [InlineDiff.Span]?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(kind == .removed ? "−" : kind == .added ? "+" : " ")
                .font(ReviewStyle.diff)
                .foregroundStyle(marker(kind))
            Text(marked)
                .font(ReviewStyle.diff)
                .foregroundStyle(kind == .context ? .secondary : .primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(background(kind))
    }

    /// The line, with the words that moved carrying a stronger tint than the
    /// line's own.
    ///
    /// One `AttributedString` rather than concatenated `Text` runs: a line
    /// broken into views breaks selection and wrapping with it, and a diff
    /// line is something people copy out.
    private var marked: AttributedString {
        guard let spans, kind != .context else {
            return AttributedString(text.isEmpty ? " " : text)
        }
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if span.changed { piece.backgroundColor = emphasis(kind) }
            result.append(piece)
        }
        return result
    }

    private func marker(_ kind: Kind) -> Color {
        switch kind {
        case .context: .secondary
        case .removed: .red
        case .added: .green
        }
    }

    private func background(_ kind: Kind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.10)
        case .added: .green.opacity(0.10)
        }
    }

    /// The word-level tint, over the line's own. Strong enough to find at a
    /// glance and weak enough to read black text through, which rules out the
    /// full-strength colour the markers use.
    private func emphasis(_ kind: Kind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.40)
        case .added: .green.opacity(0.40)
        }
    }
}

// MARK: - Reviewing a create, a delete or a move

/// The review of a change that has no hunks to answer.
///
/// A delete and a move happen or they do not; there is nothing to accept part
/// of. A create has a body but no note to diff it against, so what is worth
/// showing is the note itself rather than a diff whose every line is an
/// addition.
struct StructuralReviewSheet: View {
    let proposal: Proposal
    let daily: DailyNotes?
    let apply: () -> Void
    let discard: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(proposal: proposal, detail: "\(proposal.agent) · \(proposal.headline)") {
                if let group = proposal.group {
                    Text("Part of “\(group.summary)”")
                }
            }
            Divider()

            if proposal.kind == .create {
                ScrollView {
                    Text(proposal.body)
                        .font(ReviewStyle.created)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView(
                    proposal.headline,
                    systemImage: ReviewStyle.symbol(for: proposal.kind),
                    description: Text(description)
                )
                .frame(maxHeight: .infinity)
            }

            // Above the buttons rather than in the description, which is the
            // same grey the standard sentence is: a consequence written in
            // the same ink as the explanation is read as more explanation.
            if let warning = ReviewWarning.dailyDeparture(
                kind: proposal.kind, notePath: proposal.notePath,
                destination: proposal.destination, daily: daily
            ) {
                WarningBand(text: warning)
            }

            Divider()
            ReviewFooter(discard: discard, later: later) {
                // The button says the act, and is the *only* time it is
                // asked: this sheet has already named the file and described
                // what happens to it, so an alert after it would be a second
                // question about a decision just made deliberately. Which is
                // why the label cannot be "Apply": with no alert behind it,
                // this press is the whole commitment, and it has to read
                // clearly against "Discard Proposal" beside it.
                Button(applyLabel, action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        #if os(macOS)
        .frame(width: 660, height: 480)
        #endif
    }

    private var description: String {
        proposal.kind == .delete
            ? "The file is moved to the Trash."
            : "Every link pointing at it is repointed to the new path."
    }

    private var applyLabel: String {
        switch proposal.kind {
        case .create: "Create"
        case .delete: "Move to Trash"
        case .move: "Move"
        case .edit: "Apply"
        }
    }
}

/// Whether a proposal costs something the reader would not expect from its
/// summary, and what to say about it.
///
/// A value rather than a line of view code, so what raises a warning is
/// decided in one place and can be asked about without a window.
enum ReviewWarning {
    /// A move that takes a note out of the folder the calendar looks in.
    /// Deleting one is not this: a delete says what it is.
    static func dailyDeparture(
        kind: Proposal.Kind, notePath: String, destination: String?, daily: DailyNotes?
    ) -> String? {
        guard kind == .move, let daily, let destination,
              daily.leavesDailyFolder(notePath, movingTo: destination)
        else { return nil }
        return daily.departureNote(count: 1)
    }
}

/// A consequence worth stopping at, in the ink a caution takes: enough to
/// catch the eye above the button that carries it out, without the alarm of
/// a destructive red.
private struct WarningBand: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(ReviewStyle.warning)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        // The same inset all round as the footer below it keeps, so the band
        // sits in the panel rather than against its divider.
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
