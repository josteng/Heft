import AppKit
import HeftCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                // The minimum has to clear the traffic lights and sidebar
                // toggle, or the toolbar starts dropping items into overflow.
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 380)
        } detail: {
            Group {
                if model.vaultRoot == nil {
                    WelcomeView()
                } else if model.current == nil {
                    EmptySelectionView()
                } else {
                    EditorPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            // The note's name belongs in the toolbar, the way every document
            // app puts it there. It used to sit in a row of its own below,
            // which cost a strip of height and left the toolbar looking empty.
            .navigationTitle(model.current?.name ?? "Heft")
            .navigationSubtitle(subtitle)
        }
        .inspector(isPresented: $model.isInspectorVisible) {
            BacklinksPanel()
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.isQuickOpenPresented) { QuickOpenView() }
        .sheet(isPresented: $model.isCommandPalettePresented) { CommandPaletteView() }
        // Wikilinks in the rendered preview come back through this handler;
        // anything not addressed to Heft falls through to the browser.
        .environment(\.openURL, OpenURLAction { url in
            model.handle(url: url) ? .handled : .systemAction
        })
    }

    /// Folder, or the note count when nothing is open, mirroring how Notes
    /// captions its title.
    private var subtitle: String {
        guard let current = model.current else {
            return model.vaultRoot == nil ? "" : "\(model.index.notes.count) notes"
        }
        let folder = current.folder
        let where_ = folder.isEmpty ? "Vault root" : folder
        return model.isDirty ? "\(where_) · Edited" : where_
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A flexible centre item restores what the removed mode picker used to
        // provide: something between the leading buttons and these, pushing
        // them back to the trailing edge.
        ToolbarItem(placement: .principal) { Spacer() }

        ToolbarItem(placement: .primaryAction) {
            Button { model.isQuickOpenPresented = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Quick open (⌘O)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { model.isInspectorVisible.toggle() } label: {
                Image(systemName: "link")
            }
            .help("Toggle backlinks (⌥⌘B)")
        }
    }
}

// MARK: - Editor

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var parsed: (frontmatter: String?, blocks: [MDBlock]) = (nil, [])

    private var context: RenderContext {
        RenderContext(
            index: model.index, current: model.current, vaultRoot: model.vaultRoot,
            strictLineBreaks: model.settings.strictLineBreaks
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // No document header row: the note's name and folder are in the
            // window toolbar now.

            // One surface. `--source-mode` exposes the raw text view as a
            // debugging escape hatch, not as a user-facing mode.
            LiveTextEditor(
                text: $model.text,
                generation: model.documentGeneration,
                context: context,
                onAttachment: handleAttachment,
                onFollowLink: { url in
                    if !model.handle(url: url) { NSWorkspace.shared.open(url) }
                }
            )
            .background(Color(nsColor: .textBackgroundColor))

            StatusBar()
        }
        // Re-parsing on every keystroke is wasted work while typing; a short
        // debounce keeps the preview feeling live without the churn.
        .task(id: model.text) {
            if model.viewMode == .source { return }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            parsed = MarkdownModel.parse(model.text)
        }
        .task(id: model.documentGeneration) {
            parsed = MarkdownModel.parse(model.text)
        }
    }

    /// TextKit 2 live surface under evaluation; see `EngineEditor`.
    private var engineEditor: some View {
        EngineEditor(
            text: $model.text,
            documentID: model.current?.relativePath ?? "untitled",
            vaultRoot: model.vaultRoot,
            index: model.index,
            current: model.current,
            onAttachment: handleAttachment,
            onFollowLink: { target in
                model.follow(WikiLinkParser.links(in: "[[\(target)]]").first ?? WikiLink(target: target))
            }
        )
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var editor: some View {
        SourceEditor(
            text: $model.text,
            generation: model.documentGeneration,
            isLive: model.viewMode == .live,
            onAttachment: handleAttachment,
            onFollowLink: { url in
                // Wikilinks route back into the app; anything else is external.
                if !model.handle(url: url) { NSWorkspace.shared.open(url) }
            }
        )
        // Live mode is prose, so it gets the same measure as the preview.
        .frame(maxWidth: model.viewMode == .live ? Theme.contentMaxWidth + 80 : .infinity)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let frontmatter = parsed.frontmatter, !frontmatter.isEmpty {
                    FrontmatterView(yaml: frontmatter)
                        .padding(.bottom, Theme.blockSpacing)
                }
                MarkdownView(blocks: parsed.blocks, context: context)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, Theme.verticalPadding)
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Called by the text view on paste and drop. Returning nil lets the text
    /// view handle the pasteboard normally.
    private func handleAttachment(_ pasteboard: NSPasteboard) -> String? {
        guard let vaultRoot = model.vaultRoot else { return nil }
        do {
            if let payload = Attachments.imagePayload(from: pasteboard) {
                return try Attachments.save(
                    imageData: payload.data, preferredName: payload.name,
                    vaultRoot: vaultRoot, noteURL: model.current?.url, settings: model.settings
                )
            }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
               let file = urls.first, file.isFileURL {
                return try Attachments.importFile(
                    at: file, vaultRoot: vaultRoot,
                    noteURL: model.current?.url, settings: model.settings
                )
            }
        } catch {
            model.status = "Attachment failed: \(error.localizedDescription)"
        }
        return nil
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.status).lineLimit(1)
            Spacer()
            if let path = model.current?.relativePath {
                Text("\(wordCount) words")
                Text(path).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var wordCount: Int {
        model.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

private struct FrontmatterView: View {
    let yaml: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(yaml)
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Properties", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.codeBackground.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Empty states

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    private let candidates = ObsidianVaultLocator.knownVaults()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 5) {
                Text("Open a vault").font(.title2.weight(.semibold))
                Text("Any folder of markdown files. An existing Obsidian vault works unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !candidates.isEmpty {
                VStack(spacing: 6) {
                    ForEach(candidates.prefix(4)) { candidate in
                        Button {
                            model.openVault(at: candidate.url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.isInICloud ? "icloud" : "folder")
                                    .foregroundStyle(.secondary)
                                Text(candidate.name)
                                Spacer()
                            }
                            .contentShape(.rect)
                            .frame(width: 300)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
            }

            Button("Choose Folder…") { model.promptForVault() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

private struct EmptySelectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(model.index.notes.count) notes")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            HStack {
                Button("Quick Open…") { model.isQuickOpenPresented = true }
                Button("Today's Note") { model.openDailyNote(for: Date()) }
            }
        }
    }
}
