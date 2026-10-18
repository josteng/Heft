import HeftCore
import SwiftUI
import UIKit

/// One note's text and its saving, kept apart from any one screen so the
/// note view and the calendar load, edit and save it the same way.
///
/// Edits save themselves a moment after typing stops, and when the note is
/// left. A save only lands on the text it was based on: the Mac autosaves,
/// iCloud brings that late, and quietly replacing what the Mac wrote is the
/// one outcome worse than not saving. A refused save becomes a `conflict`
/// for the reader to settle.
@MainActor @Observable
final class NoteDocument {
    let path: String
    /// The text as last read or saved.
    private(set) var source: String?
    /// Moves only when `source` is replaced from disk, which is the one time
    /// the editor takes the text back rather than keeping its own.
    private(set) var revision = 0
    private(set) var failure: String?
    /// Whether the keyboard is up in the editor.
    var editing = false
    /// Moved to ask the editor for the keyboard.
    private(set) var focusRequest = 0
    private(set) var conflict = false
    var saveError: String?

    /// What is on disk as far as this document knows; a save checks it.
    @ObservationIgnored private var onDisk: String?
    /// Typed and not yet saved. Not observed: a keystroke changes nothing
    /// that any view draws.
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private weak var vault: MobileVault?
    /// The editor showing this note, for the bar's undo, redo and find.
    @ObservationIgnored weak var textView: UITextView?
    /// What applies at the caret, for the iPad's format popover.
    var formatState = FormatState()
    /// The colour the highlighter uses, shown on the popover's dot.
    var highlightColor: HighlightColor?
    /// What the editor suggests while a link, tag or callout is typed, for
    /// the iPad, which shows them in the note's pane.
    var suggestionChips: [SuggestionChip] = []

    func acceptSuggestion(_ position: Int) {
        (textView as? MobileTextView)?.onAcceptSuggestion?(position)
    }
    private(set) var canUndo = false
    private(set) var canRedo = false

    init(path: String) {
        self.path = path
    }

    func load(in vault: MobileVault) async {
        self.vault = vault
        // Unsaved typing wins until it is saved; a rescan arriving meanwhile
        // must not put the old text back under the caret.
        guard pending == nil else { return }
        guard let url = vault.note(at: path)?.url else {
            failure = "The note is no longer in the vault."
            return
        }
        do {
            let text = try await Task.detached { try MobileVault.read(url) }.value
            onDisk = text
            failure = nil
            if text != source {
                source = text
                revision += 1
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    func focus() { focusRequest += 1 }

    /// Read back from the editor's undo manager after every change.
    func updateUndo() {
        let undo = textView?.undoManager?.canUndo ?? false
        let redo = textView?.undoManager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    func undo() {
        textView?.undoManager?.undo()
        updateUndo()
    }

    func redo() {
        textView?.undoManager?.redo()
        updateUndo()
    }

    /// The system's find bar, over this note.
    /// A tool from the iPad's bar, which works on the note whether or not
    /// it already has the keyboard.
    func format(_ tool: FormatTool) {
        if textView?.isFirstResponder == false { textView?.becomeFirstResponder() }
        (textView as? MobileTextView)?.onFormat?(tool)
    }

    func attach(_ source: AttachSource) {
        (textView as? MobileTextView)?.onAttach?(source)
    }

    func find() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func edited(_ text: String) {
        pending = text
        saveSoon()
    }

    func saveSoon(immediately: Bool = false) {
        guard pending != nil else { return }
        saveTask?.cancel()
        saveTask = Task {
            if !immediately {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await save()
        }
    }

    /// Whatever was typed, written before the file is renamed or moved.
    func saveNow() async {
        saveTask?.cancel()
        await save()
    }

    /// Typing that will never be written: the note is being deleted.
    func abandon() {
        saveTask?.cancel()
        pending = nil
    }

    private func save() async {
        guard let vault, let text = pending, let base = onDisk, !conflict,
              let url = vault.note(at: path)?.url
        else { return }
        do {
            try await Task.detached { try MobileVault.write(text, to: url, replacing: base) }.value
            onDisk = text
            source = text
            if pending == text { pending = nil } else { saveSoon() }
            vault.refresh()
        } catch MobileWriteError.changedElsewhere {
            conflict = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Writes what was typed over the version that arrived meanwhile.
    func keepMine() async {
        guard let vault, let text = pending, let url = vault.note(at: path)?.url else { return }
        do {
            try await Task.detached { try MobileVault.overwrite(text, at: url) }.value
            onDisk = text
            source = text
            pending = nil
            conflict = false
            vault.refresh()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Drops what was typed for the version that arrived meanwhile.
    func useTheirs() async {
        guard let vault else { return }
        pending = nil
        conflict = false
        await load(in: vault)
    }
}

/// A note, editable in place.
struct NoteView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @Environment(\.mobileReplace) private var replace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileClose) private var close
    @State private var document: NoteDocument
    @State private var action: ItemAction?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(path: String, startsTyping: Bool = false) {
        self.path = path
        let document = NoteDocument(path: path)
        // Asked before the editor exists; it takes the keyboard on its first
        // update after the text has loaded.
        if startsTyping { document.focus() }
        _document = State(initialValue: document)
    }

    var body: some View {
        let note = vault.note(at: path)
        NoteContent(document: document)
            .environment(\.noteItemAction) { action = $0 }
            .itemActionHost($action) { action in
                // Typing is written first, so the file moves with it; a note
                // being deleted keeps none.
                if case .delete = action { document.abandon() } else { await document.saveNow() }
            } done: { outcome in
                switch outcome {
                case .moved(let path): replace(.note(path))
                case .deleted: if let close { close() } else { dismiss() }
                }
            }
            .navigationTitle(note?.name ?? (path as NSString).lastPathComponent)
            // Inline, because most notes open with their own title as a heading
            // and a large bar title above it says the same thing twice.
            .navigationBarTitleDisplayMode(.inline)
            // On the left, beside the back button, reading or typing alike:
            // centred, it jumped aside whenever typing widened the buttons.
            // The bar's own title stays for VoiceOver and the back menu.
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // As wide as the name up to what the buttons leave; a
                    // toolbar item is otherwise squeezed to a letter or two.
                    Text(note?.name ?? (path as NSString).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                        .fixedSize()
                        // Beside the sidebar there is no back button to
                        // follow, and flush to its edge the name looked cut.
                        .padding(.leading, sizeClass == .regular ? 12 : 0)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .onAppear {
                if let note { vault.recordOpen(note) }
            }
    }
}

/// While reading, Find and a "…" menu of what can be done to the note; while
/// typing, undo and redo, then Done. There is no Edit: a tap in the text
/// edits, as in Notes. Always present, so the bar does not reflow as notes
/// load.
struct NoteEditingToolbar: ToolbarContent {
    let document: NoteDocument
    var backlinkCount = 0
    /// Find behind "…" rather than beside it, where the bar already has a
    /// button of its own to make room for.
    var findInMenu = false
    var showBacklinks: () -> Void = {}
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @Environment(\.noteItemAction) private var itemAction
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some ToolbarContent {
        // On a wide iPad the keyboard strip's tools live here instead, and
        // like it only while the note is being written in.
        if UIDevice.current.userInterfaceIdiom == .pad, sizeClass == .regular, document.editing {
            PadNoteTools(document: document)
        }
        if document.editing {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Undo", systemImage: "arrow.uturn.backward") { document.undo() }
                    .disabled(!document.canUndo)
                    .tint(.primary)
                Button("Redo", systemImage: "arrow.uturn.forward") { document.redo() }
                    .disabled(!document.canRedo)
                    .tint(.primary)
            }
            ToolbarItem(placement: .primaryAction) {
                // The system's own Done: a filled checkmark, as Notes shows it
                // while typing, rather than a keyboard glyph to decode.
                Button("Done", systemImage: "checkmark", role: .confirm) { document.editing = false }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if !findInMenu {
                    Button("Find in Note", systemImage: "magnifyingglass") { document.find() }
                        .tint(.primary)
                        .keyboardShortcut("f")
                }
                Menu("More", systemImage: "ellipsis") { menu }
                    .tint(.primary)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        let path = document.path
        let pinned = vault.isPinned(path)
        if findInMenu {
            Button("Find in Note", systemImage: "magnifyingglass") { document.find() }
        }
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            vault.togglePin(path)
        }
        // Kept at (0) rather than hidden, so the item is where it always is.
        Button("Linked From (\(backlinkCount))", systemImage: "arrow.uturn.left", action: showBacklinks)
            .disabled(backlinkCount == 0)
        Divider()
        if let note = vault.note(at: path) {
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.string = "[[\(vault.index.linkDestination(for: note))]]"
            }
            ShareLink(item: note.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button("Show in Folder", systemImage: "folder") {
                push(.folder(note.folder))
            }
        }
        if let itemAction {
            Divider()
            ItemActionButtons(item: ItemRef(path: path, isFolder: false), perform: itemAction)
        }
    }
}

/// The note itself, in the live editor, or why it could not be read.
///
/// `scrolledDown` reports whether the reader has left the top, which the
/// calendar uses to fold itself away above the note.
struct NoteContent: View {
    let document: NoteDocument
    var scrolledDown: ((Bool) -> Void)? = nil
    /// Set where the screen's bar has its own button, as the calendar's has
    /// Capture.
    var findInMenu = false
    var topInset: CGFloat = 12
    /// Whether the note runs on under the top bar's glass. Not under the
    /// calendar's month, which the text view cannot inset itself from.
    var underTopBar = true
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var unresolved: String?
    /// Set only once loading has taken a moment, so a note that opens
    /// quickly never flashes a spinner first.
    @State private var slow = false
    @State private var showsBacklinks = false
    /// Only a note on screen is offered to the Mac: a tab left on another
    /// note would otherwise compete with it.
    @State private var onScreen = false

    var body: some View {
        let backlinks = vault.index.backlinks(to: document.path)
        Group {
            if document.source != nil, let root = vault.root {
                let note = vault.note(at: document.path)
                LiveNoteEditor(
                    document: document,
                    context: RenderContext(
                        index: vault.index, current: note, vaultRoot: root,
                        strictLineBreaks: vault.settings.strictLineBreaks,
                        colorfulFormatting: vault.appearance.colorfulFormatting,
                        accentColor: vault.appearance.accentColor,
                        linkColor: vault.appearance.linkColor,
                        tagColor: vault.appearance.tagColor,
                        codeColor: vault.appearance.codeColor,
                        boldColor: vault.appearance.boldColor,
                        italicColor: vault.appearance.italicColor,
                        headingColors: (1...6).map(vault.appearance.headingColor)
                    ),
                    scrolledDown: scrolledDown,
                    follow: { follow($0, from: note) },
                    topInset: topInset,
                    attach: { [vault, path = document.path] attachment in
                        switch attachment {
                        case .image(let data, let ext): try vault.attachImage(data, extension: ext, to: path)
                        case .file(let url): try vault.attachFile(at: url, to: path)
                        }
                    }
                )
                // Under the keyboard rather than above it; the editor pads
                // itself by what covers it.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Under the top bar too, which the text view insets itself
                // from, so the note scrolls on behind the bar's glass rather
                // than ending at its lower edge.
                .ignoresSafeArea(.container, edges: underTopBar ? .top : [])
                .overlay(alignment: .top) {
                    if document.conflict { conflictBanner }
                }
            } else if let failure = document.failure {
                ContentUnavailableView("Can't Open Note", systemImage: "doc.questionmark",
                                       description: Text(failure))
            } else if slow {
                ProgressView("Loading from iCloud…")
            } else {
                Color.clear
                    .task {
                        try? await Task.sleep(for: .milliseconds(500))
                        slow = true
                    }
            }
        }
        .toolbar {
            NoteEditingToolbar(document: document, backlinkCount: backlinks.count,
                               findInMenu: findInMenu) {
                showsBacklinks = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !document.suggestionChips.isEmpty { SuggestionBar(document: document) }
        }
        .preference(key: TypingInNoteKey.self, value: document.editing)
        .focusedSceneValue(\.heftNote, document)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        // The Mac shows this note in its Dock while it is open here.
        .userActivity(HandoffNote.activityType, isActive: onScreen && vault.root != nil) { activity in
            activity.title = vault.note(at: document.path)?.name
            activity.isEligibleForHandoff = true
            activity.addUserInfoEntries(from: HandoffNote(path: document.path, vault: vault.name).userInfo)
        }
        .sheet(isPresented: $showsBacklinks) {
            NavigationStack {
                ScrollView {
                    BacklinksView(backlinks: backlinks) { source in
                        showsBacklinks = false
                        push(.note(source))
                    }
                    .padding()
                }
                .navigationTitle("Linked From")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: "\(document.path)#\(vault.generation)") {
            await document.load(in: vault)
        }
        .onDisappear { document.saveSoon(immediately: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { document.saveSoon(immediately: true) }
        }
        .alert("Not Saved", isPresented: .constant(document.saveError != nil)) {
            Button("OK") { document.saveError = nil }
        } message: {
            Text(document.saveError ?? "")
        }
        .alert("No Such Note", isPresented: .constant(unresolved != nil)) {
            Button("OK") { unresolved = nil }
        } message: {
            Text("Nothing in this vault is called “\(unresolved ?? "")”.")
        }
    }

    /// The note changed on another device while this one was being typed
    /// into, so saving stopped rather than write over it.
    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Changed on another device", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            Text("Your edits are not saved. Keep yours to replace the other version, or use theirs to drop your edits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Use Theirs") { Task { await document.useTheirs() } }
                    .buttonStyle(.bordered)
                Button("Keep Mine") { Task { await document.keepMine() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding()
    }

    /// A wikilink arrives as the Mac's own `heft://follow?target=…` URL, a
    /// tag as a search; anything else is a web address.
    private func follow(_ url: URL, from note: NoteRef?) {
        guard url.scheme == HeftURL.scheme else {
            openURL(url)
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let tag = items.first(where: { $0.name == "tag" })?.value {
            push(.tag(tag))
            return
        }
        guard let target = items.first(where: { $0.name == "target" })?.value else { return }
        var link = WikiLink(target: target)
        if let mark = target.range(of: "#^") {
            link = WikiLink(target: String(target[..<mark.lowerBound]),
                            blockID: String(target[mark.upperBound...]))
        } else if let mark = target.firstIndex(of: "#") {
            link = WikiLink(target: String(target[..<mark]),
                            heading: String(target[target.index(after: mark)...]))
        }
        // `[[#Heading]]` points into this note, which is already open.
        guard !link.target.isEmpty else { return }
        if let ref = vault.index.resolve(link, from: note) {
            push(ref.kind == .image ? .image(ref.relativePath) : .note(ref.relativePath))
        } else {
            unresolved = link.target
        }
    }
}

private struct BacklinksView: View {
    let backlinks: [Backlink]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(backlinks) { backlink in
                Button { open(backlink.source.relativePath) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backlink.source.name).font(.subheadline.weight(.semibold))
                        Text(backlink.context)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

