import HeftCore
import SwiftUI

/// A note, rendered, with an Edit button for the plain text underneath.
struct NoteView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push

    @State private var source: String?
    @State private var failure: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var saveError: String?
    @State private var unresolved: String?
    /// Set only once loading has taken a moment, so a note that opens
    /// quickly never flashes a spinner first.
    @State private var slow = false

    var body: some View {
        let note = vault.note(at: path)
        Group {
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
            } else if let source, let root = vault.root {
                reader(source, note: note, root: root)
            } else if let failure {
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
        .navigationTitle(note?.name ?? (path as NSString).lastPathComponent)
        // Inline, because most notes open with their own title as a heading
        // and a large bar title above it says the same thing twice.
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar { toolbar }
        .task(id: "\(path)#\(vault.generation)") {
            // A rescan after this note's own save, or one that brought it
            // down from iCloud, re-reads it; an edit in progress is left be.
            if !editing { await load() }
        }
        .onAppear {
            if let note { vault.recordOpen(note) }
        }
        .alert("Not Saved", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("No Such Note", isPresented: .constant(unresolved != nil)) {
            Button("OK") { unresolved = nil }
        } message: {
            Text("Nothing in this vault is called “\(unresolved ?? "")”.")
        }
    }

    private func reader(_ source: String, note: NoteRef?, root: URL) -> some View {
        let parsed = MarkdownModel.parse(source)
        let context = MarkdownContext(index: vault.index, root: root, note: note)
        let backlinks = vault.index.backlinks(to: path)
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
        .environment(\.openURL, OpenURLAction { url in follow(url, from: note) })
        .refreshable { await load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { editing = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        } else if source != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    draft = source ?? ""
                    editing = true
                }
            }
        }
    }

    private func load() async {
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

    private func save() {
        guard let url = vault.note(at: path)?.url, let original = source else { return }
        let text = draft
        Task {
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
                    await load()
                }
            }
        }
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
