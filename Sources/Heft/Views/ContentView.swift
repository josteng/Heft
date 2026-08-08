import AppKit
import HeftCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
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
        .sheet(isPresented: $model.isSearchPresented) {
            UnifiedSearchView(initialQuery: model.searchSeed)
        }
        .sheet(isPresented: $model.isVaultSearchPresented) { VaultSearchView() }
        .onChange(of: model.isPresentationPresented) { _, isPresented in
            if isPresented { openWindow(id: "presentation") }
        }
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
            ControlGroup {
                Button { model.navigateBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canNavigateBack)
                .help("Back (⌘[)")
                .keyboardShortcut("[", modifiers: .command)

                Button { model.navigateForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canNavigateForward)
                .help("Forward (⌘])")
                .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
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
    @State private var findQuery = ""
    @State private var findMatches: [NSRange] = []
    @State private var findIndex = 0
    @State private var findSelection: FindSelection?
    @State private var findSelectionGeneration = 0
    @FocusState private var findFieldFocused: Bool

    private var context: RenderContext {
        RenderContext(
            index: model.index, current: model.current, vaultRoot: model.vaultRoot,
            strictLineBreaks: model.settings.strictLineBreaks,
            colorfulFormatting: model.isColorfulFormattingEnabled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // No document header row: the note's name and folder are in the
            // window toolbar now.

            if model.isFindPresented {
                findBar
            }

            // One surface, always. Source and preview modes were removed once
            // live mode could render everything they could: keeping them meant
            // three editors to fix every bug in.
            LiveTextEditor(
                text: $model.text,
                generation: model.documentGeneration,
                findSelection: findSelection,
                context: context,
                onAttachment: handleAttachment,
                onFollowLink: { url in
                    if !model.handle(url: url) { NSWorkspace.shared.open(url) }
                }
            )
            // Keep prose readable in wide windows while preserving the
            // editor's existing 28pt TextKit inset on either side.
            .frame(maxWidth: Theme.contentMaxWidth + 56)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            StatusBar()
        }
        .task(id: model.documentGeneration) {
            closeFind()
        }
        .task(id: model.pendingLineReveal) {
            guard let line = model.pendingLineReveal else { return }
            // Opening the note resets the caret to the top, and that reset is
            // queued behind this change. Jumping before it lands would be
            // undone a moment later.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            reveal(line: line)
            model.pendingLineReveal = nil
        }
        .onChange(of: model.isFindPresented) { _, presented in
            if presented {
                findFieldFocused = true
            } else {
                findSelection = nil
            }
        }
        .onChange(of: model.findFocusGeneration) { _, _ in
            findFieldFocused = true
        }
        .onChange(of: model.findNavigationGeneration) { _, _ in
            moveFind(by: model.findNavigationDirection)
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Spacer()
            TextField("Find", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($findFieldFocused)
                .onSubmit { moveFind(by: 1) }
                .onExitCommand { closeFind() }
                .onChange(of: findQuery) { _, _ in refreshFindMatches() }
            Text(findMatches.isEmpty ? "0 of 0" : "\(findIndex + 1) of \(findMatches.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
            Button { moveFind(by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(findMatches.isEmpty)
                .help("Previous match (⇧⌘G)")
            Button { moveFind(by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(findMatches.isEmpty)
                .help("Next match (⌘G)")
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close Find")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { findFieldFocused = true }
    }

    private func refreshFindMatches() {
        let source = model.text as NSString
        findMatches.removeAll(keepingCapacity: true)
        guard !findQuery.isEmpty else {
            findSelection = nil
            return
        }
        var cursor = 0
        while cursor < source.length {
            let range = source.range(
                of: findQuery, options: .caseInsensitive,
                range: NSRange(location: cursor, length: source.length - cursor)
            )
            guard range.location != NSNotFound else { break }
            findMatches.append(range)
            cursor = NSMaxRange(range)
        }
        findIndex = 0
        selectFindMatch()
    }

    private func moveFind(by offset: Int) {
        guard !findMatches.isEmpty else {
            if !model.isFindPresented { model.showFind() }
            findFieldFocused = true
            return
        }
        findIndex = (findIndex + offset + findMatches.count) % findMatches.count
        selectFindMatch()
    }

    private func selectFindMatch() {
        guard findMatches.indices.contains(findIndex) else { return }
        findSelectionGeneration += 1
        findSelection = FindSelection(
            range: findMatches[findIndex], generation: findSelectionGeneration
        )
    }

    /// Selects a 1-based line and scrolls to it, which is how a search result
    /// lands on the text it matched instead of at the top of the note.
    private func reveal(line: Int) {
        let text = model.text as NSString
        guard text.length > 0, line > 0 else { return }

        var start = 0
        var number = 1
        while number < line {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard next > start, next < text.length else { break }
            start = next
            number += 1
        }

        var range = text.lineRange(for: NSRange(location: start, length: 0))
        // Drop the trailing newline so the highlight covers the text alone.
        while range.length > 0,
              let last = text.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).first,
              last == "\n" || last == "\r" {
            range.length -= 1
        }
        guard range.length > 0 else { return }

        findSelectionGeneration += 1
        findSelection = FindSelection(range: range, generation: findSelectionGeneration)
    }

    private func closeFind() {
        model.isFindPresented = false
        findQuery = ""
        findMatches = []
        findIndex = 0
        findSelection = nil
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
                Button("Search…") { model.presentSearch() }
                Button("Today's Note") { model.openDailyNote(for: Date()) }
            }
        }
    }
}
