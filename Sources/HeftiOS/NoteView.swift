import HeftCore
import SwiftUI

/// One note's text and its editing state, kept apart from any one screen so
/// the note view and the calendar load, edit and save it the same way.
@MainActor @Observable
final class NoteDocument {
    let path: String
    private(set) var source: String?
    private(set) var failure: String?
    var editing = false
    var draft = ""
    var saveError: String?

    init(path: String) {
        self.path = path
    }

    func load(in vault: MobileVault) async {
        guard let url = vault.note(at: path)?.url else {
            failure = "The note is no longer in the vault."
            return
        }
        do {
            source = try await Task.detached { try MobileVault.read(url) }.value
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func beginEditing() {
        draft = source ?? ""
        editing = true
    }

    func save(in vault: MobileVault) async {
        guard let url = vault.note(at: path)?.url, let original = source else { return }
        let text = draft
        do {
            try await Task.detached {
                try MobileVault.write(text, to: url, replacing: original)
            }.value
            source = text
            editing = false
            vault.refresh()
        } catch {
            saveError = error.localizedDescription
            if case MobileWriteError.changedElsewhere = error {
                // Show the newer text underneath; the draft stays put.
                await load(in: vault)
            }
        }
    }
}

/// A note, rendered, with an Edit button for the plain text underneath.
struct NoteView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
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
            .navigationBarBackButtonHidden(document.editing)
            .toolbar { NoteEditingToolbar(document: document) }
            .onAppear {
                if let note { vault.recordOpen(note) }
            }
    }
}

/// Edit, or Cancel and Save while editing: the same three buttons wherever
/// a note is shown.
///
/// Edit is always there, only disabled while the note loads: a button that
/// came and went with each note made the whole bar reflow, which flickered
/// every time the calendar moved to another day.
struct NoteEditingToolbar: ToolbarContent {
    let document: NoteDocument
    @Environment(MobileVault.self) private var vault

    var body: some ToolbarContent {
        if document.editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { document.editing = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") { Task { await document.save(in: vault) } }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { document.beginEditing() }
                    .disabled(document.source == nil)
            }
        }
    }
}

/// The note itself: the editor while editing, else the rendered text in a
/// scroll view, else why it could not be read.
///
/// `scrolledDown` reports whether the reader has left the top, which the
/// calendar uses to fold itself away above the note.
struct NoteContent: View {
    let document: NoteDocument
    var scrolledDown: ((Bool) -> Void)? = nil
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @State private var unresolved: String?
    /// Set only once loading has taken a moment, so a note that opens
    /// quickly never flashes a spinner first.
    @State private var slow = false

    var body: some View {
        @Bindable var document = document
        Group {
            if document.editing {
                TextEditor(text: $document.draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
            } else if let source = document.source, let root = vault.root {
                reader(source, root: root)
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
        .task(id: "\(document.path)#\(vault.generation)") {
            // A rescan after this note's own save, or one that brought it
            // down from iCloud, re-reads it; an edit in progress is left be.
            if !document.editing { await document.load(in: vault) }
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

    private func reader(_ source: String, root: URL) -> some View {
        let note = vault.note(at: document.path)
        let parsed = MarkdownModel.parse(source)
        let context = MarkdownContext(index: vault.index, root: root, note: note)
        let backlinks = vault.index.backlinks(to: document.path)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let frontmatter = parsed.frontmatter {
                    PropertiesView(properties: Frontmatter.parse(frontmatter))
                }
                MarkdownBlocksView(blocks: parsed.blocks, context: context)
                if !backlinks.isEmpty {
                    BacklinksView(backlinks: backlinks)
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 24
        } action: { was, down in
            // Movement only: a note that has just opened sits at the top,
            // which is not the reader scrolling back up to it.
            if was != down { scrolledDown?(down) }
        }
        .environment(\.openURL, OpenURLAction { url in follow(url, from: note) })
        .refreshable { await document.load(in: vault) }
    }

    private func follow(_ url: URL, from note: NoteRef?) -> OpenURLAction.Result {
        guard let target = MarkdownInlines.target(of: url) else { return .systemAction }
        switch target {
        case .tag(let tag):
            push(.tag(tag))
        case .note(let link):
            // `[[#Heading]]` points into this note, which is already open.
            guard !link.target.isEmpty else { return .handled }
            if let ref = vault.index.resolve(link, from: note) {
                push(ref.kind == .image ? .image(ref.relativePath) : .note(ref.relativePath))
            } else {
                unresolved = link.target
            }
        }
        return .handled
    }
}

private struct PropertiesView: View {
    let properties: [NoteProperty]

    var body: some View {
        if !properties.isEmpty {
            DisclosureGroup("Properties") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(properties) { property in
                        GridRow {
                            Text(property.key).foregroundStyle(.secondary)
                            Text(property.value.display)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 6)
            }
            .tint(.secondary)
        }
    }
}

private struct BacklinksView: View {
    let backlinks: [Backlink]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Linked from")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(backlinks) { backlink in
                NavigationLink(value: MobileRoute.note(backlink.source.relativePath)) {
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
        .padding(.top, 8)
    }
}
