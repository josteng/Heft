import HeftCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The one search sheet: ⌘T with no scope, ⌘O for note names, ⌘P for
/// commands, ⇧⌘F for text in notes, and tags and single tags as scopes of
/// their own. What it lists is decided in `AppModel.barRows`; this view holds
/// the field, the chip, the selection and the motion.
struct SearchBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed so a change in Settings redraws a bar already open.
    @ObservedObject private var settings = GeneralSettings.shared

    @State private var scope: BarScope?
    @State private var query = ""
    @State private var selection = 0
    /// Scoped by default, like the folder the window is focused on; the
    /// toggle and the row offering the rest of the vault say why a note is
    /// missing.
    @State private var searchesEntireVault = false
    @State private var contents = ContentSearchResult.empty()
    /// Which scope `contents` was searched in, so a result never shows in
    /// another one that happens to share the query.
    @State private var contentsScope: BarScope?
    /// Set once the bar with no scope has searched text for this query, and
    /// cleared with the field or a change of scope.
    @State private var textStuck = false
    /// Moved to ask the field to select all it holds: what was typed comes
    /// along to a scope a shortcut switched to, selected, so the next key
    /// either uses it or replaces it.
    @State private var selectAllRequest = 0
    @State private var isSearching = false
    /// The heading just chosen, drawn brighter for a moment so the choice
    /// visibly registered before the rows change.
    @State private var flashing: String?
    /// Whether the highlighted row was reached by the arrows or a click
    /// rather than by being first. Space enters a scope row the reader
    /// moved to whatever they typed; one that is merely first needs the
    /// query to be the start of its name.
    @State private var isSelectionChosen = false

    init(scope: BarScope?) {
        _scope = State(initialValue: scope)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Which scopes share one list for animation: Notes with the Recent and
    /// Frequent its headings lead into, and every other scope alone.
    private var listFamily: String {
        switch scope {
        case .notes, .recent, .frequent: "notes"
        default: String(describing: scope)
        }
    }

    /// Whether this query reads note text as the reader types. With no
    /// scope that is only when names found little, and once it has started
    /// it stays for this search, so the text does not blink in and out as
    /// the count of names crosses the line.
    private var searchesText: Bool { textStuck || wantsText }

    /// Whether the scope's own text search is the summary's subject, which
    /// it is everywhere text is searched except the bar with no scope.
    private var showsTextSummary: Bool { scope == .contents || scope?.searchesTextToo == true }

    /// The list, built once per change of what it depends on and kept.
    ///
    /// It was a computed property, and the draw, the first selection, the
    /// Space check and the text threshold each asked for it, so every
    /// keystroke ranked the vault four times over on the main thread.
    @State private var rows: [BarRow] = []
    /// Whether names left room for text, from the same pass.
    @State private var wantsText = false

    private func refreshRows() {
        // The last text answer stays up while the next is searched, so the
        // list does not drop to names only and back on every letter.
        let text = contentsScope == scope && !trimmed.isEmpty ? contents : nil
        rows = model.barRows(
            scope: scope, query: query, entireVault: searchesEntireVault,
            orders: settings.scopeOrders, start: settings.startList, text: text
        )
        wantsText = model.barWantsText(
            scope: scope, query: query, entireVault: searchesEntireVault
        )
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            field
            if scope == nil { scopeStrip }
            Divider()
            list(rows)
        }
        // One height whatever the scope: the chip row leaving gives its room
        // to the list rather than shrinking the sheet under the pointer.
        .frame(width: PaletteMetrics.barWidth, height: PaletteMetrics.barHeight, alignment: .top)
        .background(PaletteSheetBackground())
        .presentationBackground(.clear)
        .onAppear { refreshRows(); selectFirst() }
        // A bar opened before the vault finished loading fills in when it
        // has, rather than staying empty until something is typed.
        .onChange(of: model.index.notes.count) { refreshRows(); selectFirst() }
        .onChange(of: model.bar?.generation) {
            // A shortcut pressed with the bar already open narrows it.
            guard let request = model.bar else { return }
            enter(request.scope, carrying: query)
            if !trimmed.isEmpty { selectAllRequest += 1 }
        }
        .onChange(of: settings.scopeOrders) { refreshRows(); selectFirst() }
        .onChange(of: settings.startList) { refreshRows(); selectFirst() }
        // Keyed on whether text is wanted too: that is settled when the list
        // is rebuilt, which can land after the query has already changed.
        .task(id: "\(trimmed)|\(searchesEntireVault)|\(String(describing: scope))|\(wantsText)") {
            await searchContents()
        }
    }

    // MARK: The field

    /// The height of one line of the field, which everything beside it is
    /// centred on, so they stay with the first line as the field grows.
    private static let lineHeight: CGFloat = 22

    private var field: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .frame(height: Self.lineHeight)
            if let scope {
                ScopeChip(scope: scope)
                    // One identity per scope, so going from the tags into a
                    // tag pops a new chip in rather than relabelling the old.
                    .id(scope)
                    .frame(height: Self.lineHeight)
                    // The chip alone springs; the field's text and the clear
                    // button slide over with the plain ease of the change, so
                    // only the new thing moves with any life.
                    .transition(.asymmetric(
                        // From its own middle, so it swells evenly rather
                        // than growing out of one corner.
                        insertion: .scale(scale: 0.7, anchor: .center)
                            .combined(with: .opacity)
                            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.4)),
                        removal: .opacity
                    ))
            }
            BarField(
                text: $query,
                placeholder: scope?.placeholder ?? BarScope.unscopedPlaceholder,
                onSubmit: { choose(at: selection) },
                onMove: move,
                onCancel: { dismiss() },
                onTab: goIntoSelection,
                onBackspaceWhenEmpty: leaveScope,
                selectAllRequest: selectAllRequest
            )
            .padding(.vertical, -BarField.edge)
            .onChange(of: query) { old, new in
                if scope == nil, let entered = BarScope.entered(byTyping: new) {
                    enter(entered, carrying: "")
                } else if new == old + " ", let target = spaceTarget(after: old) {
                    enter(target, carrying: "")
                } else {
                    refreshRows()
                    selectFirst()
                }
            }
            if searchesText {
                if isSearching {
                    ProgressView().controlSize(.small)
                        .frame(height: Self.lineHeight)
                } else if showsTextSummary, !trimmed.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(height: Self.lineHeight)
                }
            }
            PaletteDismissButton(query: $query) { dismiss() }
                .frame(height: Self.lineHeight)
            if model.scopePath != nil, scope?.followsFolderFocus ?? true {
                Button { searchesEntireVault.toggle(); refreshRows(); selectFirst() } label: {
                    Image(systemName: searchesEntireVault ? "globe" : "scope")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(searchesEntireVault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(searchesEntireVault ? "Showing the entire vault" : "Showing \(model.scopeName)")
                .frame(height: Self.lineHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, BarField.edge)
    }

    private var summary: String {
        let matchWord = contents.totalOccurrences == 1 ? "match" : "matches"
        let noteWord = contents.matchedNotes == 1 ? "note" : "notes"
        return "\(contents.totalOccurrences) \(matchWord) in \(contents.matchedNotes) \(noteWord)"
    }

    /// The scopes as chips under the field, so the bar with no scope shows
    /// where else it can look without spending list rows on it.
    private var scopeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) { scopeChips }
            .padding(.bottom, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(BarScope.chips, id: \.self) { candidate in
                Button {
                    enter(candidate, carrying: "")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: candidate.symbol).font(.system(size: 10, weight: .semibold))
                        Text(candidate.title).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(keys(for: candidate).map { "\(candidate.title)  \($0)" } ?? candidate.title)
            }
        }
        .padding(.horizontal, 16)
    }

    /// The scope Space after `old` would enter: the highlighted row's, when
    /// it is a scope, a tag or a heading, and the reader either moved to it
    /// or typed the start of its name. Otherwise Space is a space.
    private func spaceTarget(after old: String) -> BarScope? {
        // Not refreshed yet, so still the list for `old`: the row the reader
        // was looking at when they pressed Space.
        guard rows.indices.contains(selection) else { return nil }
        let row = rows[selection]
        switch row {
        case .scope(let target):
            return isSelectionChosen || target.isNamed(byPrefix: old) ? target : nil
        case .tag(let name, _):
            return isSelectionChosen || BarScope.tag(name).isNamed(byPrefix: old) ? .tag(name) : nil
        case .folder(let path, _):
            let target = BarScope.folder(path)
            return isSelectionChosen || target.isNamed(byPrefix: old) ? target : nil
        case .heading(_, let target?):
            return isSelectionChosen ? target : nil
        default:
            return nil
        }
    }

    // MARK: The list

    private func list(_ rows: [BarRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty, !trimmed.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: trimmed)
                        .padding(.top, 90)
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isSelected: index == selection)
                                .id(row.id)
                                .onTapGesture {
                                    guard row.isSelectable else { return }
                                    selection = index
                                    isSelectionChosen = true
                                    choose(at: index)
                                }
                        }
                    }
                    .padding(6)
                    #if os(macOS)
                    .background(OverlayScrollerConfiguration())
                    #endif
                }
            }
            // No anchor, so the list scrolls the least it can to reveal the
            // row and holds still while the selection is already visible.
            // Naming one asks for the row to be put *there* on every move,
            // which scrolls from the first arrow press and pins the
            // selection mid-list, unlike every other menu on the system.
            .onChange(of: selection) {
                if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
            }
        }
        // A sheet's scrolling subtree can retain its initial children while
        // the query updates, so the list takes the query as its identity,
        // and the family of its scope. Within one family, Notes and its own
        // Recent and Frequent, entering is animated row by row, keeping what
        // both share and fading the rest. Across families the list is
        // replaced: a tag the reader uses sat in ⌘T's Frequent and, kept,
        // travelled to the top of the tags while every other row faded in.
        .id("\(trimmed)#\(searchesEntireVault)#\(listFamily)")
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: BarRow, isSelected: Bool) -> some View {
        switch row {
        case .heading(let title, let target):
            if target == nil {
                SectionLabel(title: title)
            } else {
                HeadingRow(
                    title: title, hint: "Show All",
                    isSelected: isSelected, isFlashing: flashing == row.id
                )
            }
        case .note(let note):
            NoteResultRow(note: note, isSelected: isSelected)
                // A result is a file, and dragging one out beats opening it
                // to find its path. Simultaneous so a click still opens it,
                // and only once the pointer has travelled.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in beginFileDrag(for: note.url) }
                )
        case .command(let command):
            CommandRow(
                command: command, title: command.title(on: model),
                isSelected: isSelected, isEnabled: command.isEnabled(on: model)
            )
        case .tag(let name, let count):
            ActionRow(
                symbol: "number", title: name,
                detail: isSelected
                    ? "Space to search"
                    : (count == 1 ? "1 note" : "\(count) notes"),
                isSelected: isSelected
            )
        case .folder(let path, let count):
            ActionRow(
                symbol: "folder", title: path,
                detail: isSelected
                    ? "Space to search"
                    : (count == 1 ? "1 note" : "\(count) notes"),
                isSelected: isSelected
            )
        case .scope(let target):
            // As Chrome says "Press Tab to search" on a keyword's row.
            ActionRow(
                symbol: target.symbol, title: target.title,
                detail: isSelected ? "Space to search" : keys(for: target),
                isSelected: isSelected
            )
        case .hit(let hit):
            HitRow(hit: hit, query: trimmed, isSelected: isSelected)
                // Arriving after the names, a match fades in where it lands;
                // nothing around it moves.
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.18)))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in beginFileDrag(for: hit.note.url) }
                )
        case .searchText(let text, let matches):
            ActionRow(
                symbol: "text.magnifyingglass",
                title: matches.map { $0 == 1 ? "1 match in text" : "All \($0) matches in text" }
                    ?? "Search text in notes for \u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D}",
                detail: AppCommandShortcut.searchVault.display, isSelected: isSelected
            )
        case .elsewhere(let count):
            ActionRow(
                symbol: "globe",
                title: "None in \(model.scopeName). Show \(count) in the entire vault",
                detail: nil, isSelected: isSelected
            )
        }
    }

    /// The ways into a scope, typed or pressed.
    private func keys(for scope: BarScope) -> String? {
        let shortcut: AppCommandShortcut? = switch scope {
        case .notes: .quickOpen
        case .commands: .commandPalette
        case .contents: .searchVault
        default: nil
        }
        return [scope.trigger.map(String.init), shortcut?.display]
            .compactMap { $0 }
            .joined(separator: "  ")
    }

    // MARK: Choosing

    private func selectFirst() {
        isSelectionChosen = false
        selection = rows.firstIndex { row in
            if case .heading = row { return false }
            return row.isSelectable
        } ?? 0
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var next = selection
        repeat {
            next += delta
        } while rows.indices.contains(next) && !rows[next].isSelectable
        if rows.indices.contains(next) {
            selection = next
            isSelectionChosen = true
        }
    }

    private func choose(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if let target = row.scope {
            if case .heading = row {
                // Drawn in a turn of its own, then animated away with the
                // change of scope; set together, it would never be seen.
                flashing = row.id
                // Into text the words come along, as from its row below.
                let carried = target == .contents ? query : ""
                DispatchQueue.main.async { enter(target, carrying: carried) }
                return
            }
            if case .searchText(let text, _) = row {
                enter(target, carrying: text)
            } else {
                enter(target, carrying: "")
            }
            return
        }
        switch row {
        case .note(let note):
            model.open(note)
            dismiss()
        case .command(let command):
            guard command.isEnabled(on: model) else { return }
            command.perform(on: model)
            dismiss()
        case .hit(let hit):
            // Land on the line that matched, not at the top of the note.
            model.open(hit.note, revealingLine: hit.line)
            dismiss()
        case .elsewhere:
            searchesEntireVault = true
            selectFirst()
        default:
            break
        }
    }

    /// Tab goes into whatever the selected row is a way into, and does
    /// nothing on a row that is not: focus has nowhere else to go.
    private func goIntoSelection() -> Bool {
        if rows.indices.contains(selection), rows[selection].scope != nil {
            choose(at: selection)
        }
        return true
    }

    /// Backspace in an empty field leaves the scope: a tag for the list of
    /// tags, anything else for the bar with none.
    private func leaveScope() -> Bool {
        guard let scope else { return false }
        enter(scope.parent, carrying: "", isLeaving: true)
        return true
    }

    private func enter(_ target: BarScope?, carrying text: String, isLeaving: Bool = false) {
        // Eased, not sprung: a bounce made the chip, the text and the clear
        // button all wobble, where sliding them aside is the whole effect.
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.22)
        withAnimation(animation) {
            scope = target
            query = text
            flashing = nil
            textStuck = false
            contents = .empty()
            refreshRows()
        }
        selectFirst()
        if !isLeaving, let target { model.recordScopeUse(target) }
    }


    // MARK: Text in notes

    private func searchContents() async {
        if trimmed.isEmpty { textStuck = false }
        guard searchesText, !trimmed.isEmpty else {
            isSearching = false
            contents = .empty()
            return
        }
        let term = trimmed
        isSearching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, trimmed == term else { return }
        let searched = scope
        let notes = model.barSearchableNotes(scope: searched, entireVault: searchesEntireVault)
        let result = await Task.detached(priority: .userInitiated) {
            ContentSearch.run(notes: notes, query: term, limit: 500)
        }.value
        guard !Task.isCancelled, trimmed == term, scope == searched else { return }
        // Not in an animation: one animated the list's whole layout, which
        // opened out from the middle where every other change is instant.
        // The new rows fade by themselves instead (`HitRow`'s transition).
        contentsScope = searched
        if searched == nil { textStuck = true }
        contents = ContentSearchResult(
            query: term, matches: result.matches,
            totalOccurrences: result.totalOccurrences, matchedNotes: result.matchedNotes,
            totalMatches: result.totalMatches
        )
        refreshRows()
        // The answer can put a heading where the selection was, or shorten
        // the list under it. A selection the reader did not move goes back
        // to the first row, which is now the first match rather than the
        // Text heading or the "all matches" row that held its place; one
        // they moved stays, unless it now sits on a label.
        if !isSelectionChosen || !rows.indices.contains(selection) || !rows[selection].isSelectable {
            selectFirst()
        }
        isSearching = false
    }
}

// MARK: - The field

/// An AppKit text view, because the bar needs keys a SwiftUI field does not
/// hand over: Tab to go into a scope and Backspace in an empty field to leave
/// one, as well as the arrows, Return and Escape.
///
/// A text view in a scroll view rather than a text field. The field it
/// replaced wrapped once it was allowed to grow, but did not scroll by
/// trackpad, clipped its text short of its edges and had no way to move
/// between its lines; this is how a chat prompt such as Siri's is built.
struct BarField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void
    let onTab: () -> Bool
    let onBackspaceWhenEmpty: () -> Bool
    let selectAllRequest: Int

    static let font = NSFont.systemFont(ofSize: 16)
    /// Lines the field grows to before it scrolls, as Siri's prompt does.
    static let maximumLines = 5
    /// The row everything beside the field is centred on; one line of text
    /// is centred in it by the inset.
    static let rowHeight: CGFloat = 22

    static var lineHeight: CGFloat {
        let layout = NSLayoutManager()
        return ceil(layout.defaultLineHeight(for: font))
    }

    static var inset: CGFloat { max(0, (rowHeight - lineHeight) / 2) }
    /// The header's padding above and below the field. The field reaches
    /// into it and insets its text by as much, so text scrolled out of the
    /// way goes on to the sheet's edge and the divider instead of stopping
    /// short of them, while at rest it sits exactly where it did.
    static let edge: CGFloat = 13

    /// How tall the field is for `text` at `width`: one line at least, and
    /// at most `maximumLines`, past which it scrolls within itself. Laid out
    /// the way the text view lays it out, so the two agree on every wrap.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        let lines = min(max(used, lineHeight), lineHeight * CGFloat(maximumLines))
        return lines + inset * 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return CGSize(width: width, height: Self.height(for: text, width: width) + Self.edge * 2)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FadingScrollView()
        scroll.fade = Self.edge
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.edge, left: 0, bottom: Self.edge, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: Self.edge, left: 0, bottom: Self.edge, right: 0)

        // TextKit 1, as `height(for:width:)` measures with it, so the frame
        // and the lines it holds cannot disagree by a wrap.
        let view = NSTextView(usingTextLayoutManager: false)
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        // A query is not prose to rewrite: as a multi-line text view the
        // field drew the Writing Tools button beside its first line.
        view.writingToolsBehavior = .none
        view.textContainerInset = NSSize(width: 0, height: Self.inset)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.string = text
        view.delegate = context.coordinator
        view.setAccessibilityPlaceholderValue(placeholder)
        scroll.documentView = view
        context.coordinator.view = view
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.placeholder.stringValue = placeholder
        context.coordinator.placeholder.isHidden = !text.isEmpty
        context.coordinator.attachPlaceholder()
        view.setAccessibilityPlaceholderValue(placeholder)
        if selectAllRequest != context.coordinator.selectAllRequest {
            context.coordinator.selectAllRequest = selectAllRequest
            DispatchQueue.main.async { view.selectAll(nil) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BarField
        var selectAllRequest = 0
        weak var view: NSTextView?
        /// Drawn as a label inside the text view, where a text field draws its
        /// own; a text view has none.
        let placeholder: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.font = BarField.font
            label.textColor = .placeholderTextColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }()

        init(_ parent: BarField) {
            self.parent = parent
            selectAllRequest = parent.selectAllRequest
        }

        func attachPlaceholder() {
            guard let view, placeholder.superview !== view else { return }
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                placeholder.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
                placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: BarField.inset),
            ])
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView,
                  parent.text != view.string
            else { return }
            parent.text = view.string
        }

        /// A query is one line of meaning however many it is shown on, so a
        /// pasted line break becomes a space.
        func textView(
            _ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard let replacement = replacementString,
                  replacement.rangeOfCharacter(from: .newlines) != nil
            else { return true }
            let flat = replacement.components(separatedBy: .newlines).joined(separator: " ")
            view.insertText(flat, replacementRange: range)
            return false
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                // Up moves between the field's own lines first, and to the
                // list from the top one; Down likewise from the bottom one.
                guard isOnEdgeLine(view, top: true) else { return false }
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                guard isOnEdgeLine(view, top: false) else { return false }
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.deleteBackward(_:)):
                guard view.string.isEmpty else { return false }
                return parent.onBackspaceWhenEmpty()
            default:
                return false
            }
            return true
        }

        /// Whether the caret is on the first line (or the last), where a text
        /// view's own Up (or Down) has nowhere to go.
        private func isOnEdgeLine(_ view: NSTextView, top: Bool) -> Bool {
            guard let layout = view.layoutManager, let container = view.textContainer,
                  !view.string.isEmpty
            else { return true }
            let caret = view.selectedRange().location
            let length = (view.string as NSString).length
            let glyphs = layout.numberOfGlyphs
            guard glyphs > 0 else { return true }
            let glyph = min(layout.glyphIndexForCharacter(at: min(caret, max(length - 1, 0))), glyphs - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = layout.usedRect(for: container)
            // A caret after a trailing space can sit past the last fragment.
            if caret >= length, !top { return true }
            return top ? line.minY <= used.minY + 0.5 : line.maxY >= used.maxY - 0.5
        }
    }
}

/// A scroll view whose content fades out over `fade` points at its top and
/// bottom, so text scrolled into the field's margins softens toward the
/// sheet's edge and the divider instead of being cut off there. At rest the
/// text sits inside the margins and the fade touches nothing.
private final class FadingScrollView: NSScrollView {
    var fade: CGFloat = 0
    private let gradient = CAGradientLayer()

    override func layout() {
        super.layout()
        guard fade > 0, bounds.height > fade * 2 else { return }
        wantsLayer = true
        if layer?.mask !== gradient {
            gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            layer?.mask = gradient
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let edge = fade / bounds.height
        gradient.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }
}

// MARK: - Rows

/// The scope at the start of the field.
///
/// A new chip springs in from the leading edge, which is the whole of its
/// entrance. A highlight swept across it afterwards, as Dia does, read as a
/// second event once the chip had already arrived; a glow around the sheet
/// never fitted the corners AppKit gives it.
private struct ScopeChip: View {
    @Environment(\.appAccent) private var accent
    let scope: BarScope

    var body: some View {
        // The text keeps the text colour: a light accent such as yellow is
        // unreadable as text on a tint of itself.
        HStack(spacing: 4) {
            Image(systemName: scope.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(scope.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.22)))
        .fixedSize()
        .accessibilityLabel("Searching \(scope.title)")
    }
}

/// A heading that only labels, styled as a sidebar section is.
private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A heading that is a way into its own scope, so it says what Return will
/// do once the arrows reach it.
private struct HeadingRow: View {
    @Environment(\.appAccent) private var accent

    let title: String
    let hint: String
    let isSelected: Bool
    var isFlashing = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            if isSelected {
                Text(hint).font(.system(size: 11))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected || isFlashing {
                RoundedRectangle(cornerRadius: 6).fill(accent)
                    .overlay(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isFlashing ? 0.35 : 0)))
            }
        }
        .contentShape(.rect)
        // The gap above a heading sits outside its highlight, or the label
        // is drawn low inside it.
        .padding(.top, 3)
    }
}

private struct NoteResultRow: View {
    @Environment(\.appAccent) private var accent

    let note: NoteRef
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(note.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !note.folder.isEmpty {
                Text(note.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}

private struct CommandRow: View {
    @Environment(\.appAccent) private var accent

    let command: AppCommand
    let title: String
    let isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(.rect)
    }
}

/// A row that goes somewhere rather than naming a note or a command: a tag,
/// a scope, a search of the text, the rest of the vault.
private struct ActionRow: View {
    @Environment(\.appAccent) private var accent

    let symbol: String
    let title: String
    let detail: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }
}

/// A line of a note that matched, two lines tall: where, then the line.
private struct HitRow: View {
    @Environment(\.appAccent) private var accent

    let hit: ContentMatch
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(hit.note.name).font(.system(size: 13)).fontWeight(.medium)
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    Spacer(minLength: 8)
                    if hit.occurrences > 1 {
                        Text("\(hit.occurrences) matches")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
                            )
                    }
                }
                highlightedPreview
                    .font(.system(size: 12))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(accent) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    private var location: String {
        hit.note.folder.isEmpty ? "Line \(hit.line)" : "\(hit.note.folder) · Line \(hit.line)"
    }

    private var highlightedPreview: Text {
        let plain = hit.preview
        var result = AttributedString(plain)
        var cursor = plain.startIndex
        while cursor < plain.endIndex,
              let range = plain.range(
                of: query, options: .caseInsensitive, range: cursor..<plain.endIndex
              ),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].font = .system(size: 12, weight: .bold)
            if !isSelected { result[lower..<upper].foregroundColor = accent }
            cursor = range.upperBound
        }
        return Text(result)
    }
}

#if os(macOS)
/// SwiftUI follows the system's scrollbar preference, which can select a
/// space-taking legacy scroller. A palette needs the macOS overlay treatment:
/// visible while scrolling, faded at rest, and never part of row geometry.
private struct OverlayScrollerConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? ConfiguringView)?.configureScroller()
    }

    private final class ConfiguringView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureNowOrRetry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureNowOrRetry()
        }

        @discardableResult
        func configureScroller() -> Bool {
            guard let scrollView = enclosingScrollView else { return false }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = true
            scrollView.verticalScroller?.controlSize = .small
            return true
        }

        private func configureNowOrRetry() {
            // `viewDidMoveToSuperview` normally has the NSScrollView ancestor
            // already, which lets us set overlay style before the first frame.
            // Keep one next-turn retry for SwiftUI hierarchy changes where the
            // representable is attached from the inside out.
            guard !configureScroller() else { return }
            DispatchQueue.main.async { [weak self] in
                self?.configureScroller()
            }
        }
    }
}
#endif
