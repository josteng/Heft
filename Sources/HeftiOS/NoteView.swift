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
    @State private var document: NoteDocument

    init(path: String) {
        self.path = path
        _document = State(initialValue: NoteDocument(path: path))
    }

    var body: some View {
        let note = vault.note(at: path)
        NoteContent(document: document)
            .navigationTitle(note?.name ?? (path as NSString).lastPathComponent)
            // Inline, because most notes open with their own title as a heading
            // and a large bar title above it says the same thing twice.
            .navigationBarTitleDisplayMode(.inline)
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

    var body: some ToolbarContent {
        if document.editing {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Undo", systemImage: "arrow.uturn.backward") { document.undo() }
                    .disabled(!document.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { document.redo() }
                    .disabled(!document.canRedo)
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
                }
                Menu("More", systemImage: "ellipsis") { menu }
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
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var unresolved: String?
    /// Set only once loading has taken a moment, so a note that opens
    /// quickly never flashes a spinner first.
    @State private var slow = false
    @State private var showsBacklinks = false

    var body: some View {
        let backlinks = vault.index.backlinks(to: document.path)
        Group {
            if document.source != nil, let root = vault.root {
                let note = vault.note(at: document.path)
                LiveNoteEditor(
                    document: document,
                    context: RenderContext(
                        index: vault.index, current: note, vaultRoot: root,
                        strictLineBreaks: vault.settings.strictLineBreaks
                    ),
                    scrolledDown: scrolledDown,
                    follow: { follow($0, from: note) },
                    topInset: topInset
                )
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
        .preference(key: TypingInNoteKey.self, value: document.editing)
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
