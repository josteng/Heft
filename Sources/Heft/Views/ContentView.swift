import AppKit
import HeftCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var registry: VaultRegistry
    @Environment(\.openWindow) private var openWindow
    @State private var windowTopChromeHeight: CGFloat = 0
    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                // The minimum has to clear the traffic lights and sidebar
                // toggle, or the toolbar starts dropping items into overflow.
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 380)
                // A toolbar contributed by the sidebar lands in the title-bar
                // region above that column, not in the detail pane.
                .toolbar { sidebarToolbar }
        } detail: {
            Group {
                if model.vaultRoot == nil {
                    WelcomeView()
                } else if model.current == nil {
                    // The offer belongs here above all: opening a folder that
                    // has never been set up is exactly the moment there is no
                    // note open yet, so hanging it only over the editor meant
                    // it appeared everywhere except where it was needed.
                    VStack(spacing: 0) {
                        if model.shouldOfferAgentSetup {
                            // The unified toolbar draws over the top of this
                            // column, so a banner placed flush with it is
                            // hidden behind the title. `EditorPane` reserves
                            // the same height for the same reason.
                            Color.clear.frame(height: windowTopChromeHeight)
                            AgentSetupBanner()
                        }
                        EmptySelectionView()
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    EditorPane(topChromeHeight: windowTopChromeHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            // This has to live on the detail column's root. Applying it only
            // to EditorPane is too late: NavigationSplitView has already
            // clipped that child to the title-bar safe area.
            .ignoresSafeArea(.container, edges: .top)
            // Let macOS choose the native transition between scrolling content
            // and the floating window controls for the current toolbar state.
            .scrollEdgeEffectStyle(.automatic, for: .top)
            // The note's name belongs in the toolbar, the way every document
            // app puts it there. It used to sit in a row of its own below,
            // which cost a strip of height and left the toolbar looking empty.
            .navigationTitle(model.current?.name ?? "Heft")
            .navigationSubtitle(model.windowSubtitle)
        }
        .inspector(isPresented: $model.isInspectorVisible) {
            BacklinksPanel()
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .toolbar { toolbarContent }
        .background(WindowToolbarConfiguration(
            registry: registry,
            workspaceID: model.workspaceID,
            topChromeHeight: $windowTopChromeHeight
        ))
        .sheet(isPresented: $model.isQuickOpenPresented) { QuickOpenView() }
        .sheet(
            isPresented: $model.isCommandPalettePresented,
            onDismiss: { model.commandPaletteDidDismiss() }
        ) { CommandPaletteView() }
        .sheet(isPresented: $model.isVaultSearchPresented) { VaultSearchView() }
        .sheet(isPresented: $model.isDailyNotesSettingsPresented) {
            DailyNotesSettingsView()
        }
        .sheet(isPresented: $model.isInboxCapturePresented) {
            InboxCaptureView()
        }
        .sheet(item: $model.reviewing) { proposal in
            // A delete, a move or a note that does not exist yet has no hunks
            // to answer: there is nothing to accept part of.
            if proposal.isStructural || proposal.kind == .create {
                StructuralReviewView(proposal: proposal).environmentObject(model)
            } else {
                ProposalReviewView(proposal: proposal).environmentObject(model)
            }
        }
        .sheet(item: $model.reviewingConflict) { conflict in
            ConflictReviewView(conflict: conflict).environmentObject(model)
        }
        .alert(
            model.saveConflict?.diskVersionExists == false
                ? "This Note Was Removed Outside Heft"
                : "This Note Changed Outside Heft",
            isPresented: Binding(
                get: { model.saveConflict != nil },
                set: { presented in
                    if !presented, model.saveConflict != nil {
                        model.resolveSaveConflict(.cancel)
                    }
                }
            ),
            presenting: model.saveConflict
        ) { conflict in
            Button("Keep My Changes", role: .destructive) {
                model.resolveSaveConflict(.keepMine)
            }
            if conflict.diskVersionExists {
                Button("Review Changes…") {
                    model.reviewSaveConflict(conflict)
                }
                Button("Use Disk Version") {
                    model.resolveSaveConflict(.useDisk)
                }
            }
            Button("Cancel", role: .cancel) {
                model.resolveSaveConflict(.cancel)
            }
        } message: { conflict in
            Text(
                conflict.diskVersionExists
                    ? "\(conflict.relativePath) was modified after Heft opened it. Choose which version to keep."
                    : "\(conflict.relativePath) was removed after Heft opened it. Keeping your changes will recreate it."
            )
        }
        .alert(
            "That Folder Isn't in \(model.vaultName)",
            isPresented: Binding(
                get: { model.pendingOutsideVaultFolder != nil },
                set: { presented in if !presented { model.pendingOutsideVaultFolder = nil } }
            ),
            presenting: model.pendingOutsideVaultFolder
        ) { url in
            Button("Open as New Vault") {
                openAsNewVault(url)
                model.pendingOutsideVaultFolder = nil
            }
            Button("Cancel", role: .cancel) { model.pendingOutsideVaultFolder = nil }
        } message: { url in
            Text(
                "\(url.lastPathComponent) is outside \(model.vaultName), so it can't be a focus "
                    + "folder here. Open it as its own vault in a new window instead?"
            )
        }
        .onChange(of: model.isPresentationPresented) { _, isPresented in
            if isPresented {
                registry.presentationModel = model
                openWindow(id: "presentation")
            } else if registry.presentationModel === model {
                registry.presentationModel = nil
            }
        }
        // Wikilinks in the rendered preview come back through this handler;
        // anything not addressed to Heft falls through to the browser.
        .environment(\.openURL, OpenURLAction { url in
            model.handle(url: url) ? .handled : .systemAction
        })
    }

    private func openAsNewVault(_ url: URL) {
        switch registry.resolveOpen(for: url) {
        case .open(let descriptor):
            openWindow(value: descriptor)
        case .overlapping(let vaultName):
            let alert = NSAlert()
            alert.messageText = "That folder contains an open vault"
            alert.informativeText = "Close \(vaultName) before opening its parent as a separate vault. Overlapping vaults can race while indexing and editing."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if model.columnVisibility != .detailOnly {
            ToolbarSpacer(.flexible, placement: .status)
        }
        ToolbarItem(placement: .status) {
            // Keep the toolbar item's identity stable across a collapse. Fully
            // removing it made AppKit occasionally forget to restore it when
            // a very narrow sidebar was reopened. A zero-width item also stays
            // out of the overflow menu during the closing animation.
            WorkspaceScopePicker()
                .frame(width: model.columnVisibility == .detailOnly ? 0 : nil)
                .opacity(model.columnVisibility == .detailOnly ? 0 : 1)
                .clipped()
                .allowsHitTesting(model.columnVisibility != .detailOnly)
                .accessibilityHidden(model.columnVisibility == .detailOnly)
        }
        if model.columnVisibility != .detailOnly {
            ToolbarSpacer(.flexible, placement: .status)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Keeps detail actions at the trailing edge without putting workspace
        // scope in the centre of the document pane.
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

/// SwiftUI opts modern toolbars into a display-mode context menu by default.
/// Heft's toolbar has purpose-built icon controls and a custom scope picker,
/// so "Icon and Text" is neither meaningful nor a layout the app supports.
private struct WindowToolbarConfiguration: NSViewRepresentable {
    let registry: VaultRegistry
    let workspaceID: UUID
    @Binding var topChromeHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.toolbar?.displayMode = .iconOnly
        window.toolbar?.allowsDisplayModeCustomization = false
        // Full-size content lets NSScrollView extend beneath the toolbar and
        // automatically inset its starting position. Do not also set AppKit's
        // `titlebarAppearsTransparent`: AppKit explicitly disables that
        // automatic scroll-view overlap when the property is true. Leaving the
        // normal toolbar background in place gives it the native translucent
        // material rather than making the entire title bar fully clear.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        let measuredHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        if abs(topChromeHeight - measuredHeight) > 0.5 {
            let height = measuredHeight
            DispatchQueue.main.async { topChromeHeight = height }
        }
        registry.register(window: window, for: workspaceID)
    }
}

/// The window's browsing boundary belongs in the title bar: it describes the
/// whole workspace, while the sidebar below is free to describe its contents.
private struct WorkspaceScopePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Button("Entire Vault") { model.showEntireVault() }
                .disabled(model.scopePath == nil)
            Button("Choose Folder…") { model.promptForScope() }
            if model.scopePath != nil {
                Divider()
                Button("Reveal Focused Folder in Finder") {
                    if let root = model.scopeRoot { model.revealInFinder(root) }
                }
            }
        } label: {
            // Text alone, and the chevron left to the system.
            //
            // A hand-drawn one had to go: an `Image` anywhere in a toolbar
            // menu's label — even inside an overlay, positioned trailing — is
            // hoisted out and re-laid as a *leading* menu icon, tinted with
            // the accent colour. So the chevron sat on the wrong side and
            // turned yellow the moment the accent did. The built-in indicator
            // is trailing and label-coloured, which is what it should have
            // looked like all along.
            Text(model.scopePath == nil ? "All Notes" : model.scopeName)
                .lineLimit(1)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 76)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.visible)
        .controlSize(.small)
        .fixedSize()
        .help(model.scopePath.map { "\(model.vaultName) / \($0)" } ?? model.vaultName)
    }
}

// MARK: - Editor

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel
    let topChromeHeight: CGFloat
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var findQuery = ""
    @State private var findMatches: [NSRange] = []
    @State private var findIndex = 0
    @State private var findSelection: FindSelection?
    @State private var findSelectionGeneration = 0
    @State private var findDirection = 1
    @State private var findWholeWord = false
    @FocusState private var findFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var context: RenderContext {
        var context = model.renderContext()
        context.appearance = RenderContext.appearance(for: colorScheme)
        return context
    }

    var body: some View {
        VStack(spacing: 0) {
            // No document header row: the note's name and folder are in the
            // window toolbar now.

            if model.isFindPresented {
                // The whole detail column deliberately starts at the window's
                // top edge so document scrolling can pass beneath the toolbar.
                // Fixed find chrome opts out locally, before its own layout,
                // avoiding modifier-order and safe-area caching surprises.
                Color.clear.frame(height: topChromeHeight)
                findBar
            }

            if !model.proposalsForCurrentNote.isEmpty {
                if !model.isFindPresented {
                    Color.clear.frame(height: topChromeHeight)
                }
                ProposalBanner()
            } else if model.shouldOfferAgentSetup {
                // Below the proposals, never beside them: a vault with a
                // proposal waiting is already set up, and two banners stacked
                // over one note is noise.
                if !model.isFindPresented {
                    Color.clear.frame(height: topChromeHeight)
                }
                AgentSetupBanner()
            }

            // One surface, always. Source and preview modes were removed once
            // live mode could render everything they could: keeping them meant
            // three editors to fix every bug in.
            LiveTextEditor(
                text: $model.text,
                documentIdentity: model.current?.relativePath ?? "",
                generation: model.documentGeneration,
                generationKeepsPosition: model.documentGenerationKeepsPosition,
                findSelection: findSelection,
                insertion: model.pendingInsertion,
                context: context,
                onAttachment: handleAttachment,
                onFollowLink: { url in
                    if !model.handle(url: url) { NSWorkspace.shared.open(url) }
                },
                onVimSearch: { action in
                    switch action {
                    case let .beginSearch(backward):
                        findDirection = backward ? -1 : 1
                        findWholeWord = false
                        model.isFindPresented = true
                    case let .nextSearch(backward):
                        guard !findQuery.isEmpty else {
                            model.isFindPresented = true
                            return
                        }
                        moveFind(by: backward ? -1 : 1)
                    case let .searchWord(query, backward, origin):
                        findDirection = backward ? -1 : 1
                        findWholeWord = true
                        findQuery = query
                        refreshFindMatches()
                        guard !findMatches.isEmpty else { return }
                        if backward {
                            findIndex = findMatches.lastIndex { $0.location < origin }
                                ?? (findMatches.count - 1)
                        } else {
                            findIndex = findMatches.firstIndex { $0.location > origin } ?? 0
                        }
                        selectFindMatch()
                    default: break
                    }
                }
            )
            // The scroll view fills the pane, keeping its scroller at the
            // window edge. HeftTextKit2View centers and width-limits only the
            // text container inside it.
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            StatusBar()
        }
        .task(id: model.documentGeneration) {
            closeFind()
        }
        .task(id: model.settings.vimMode) {
            VimSettings.shared.adoptVaultDefault(model.settings.vimMode)
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
                .onSubmit { moveFind(by: findDirection) }
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
            if !findWholeWord || isWholeWordMatch(range, in: source) {
                findMatches.append(range)
            }
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
        findWholeWord = false
        findQuery = ""
        findMatches = []
        findIndex = 0
        findSelection = nil
    }

    private func isWholeWordMatch(_ range: NSRange, in source: NSString) -> Bool {
        let beforeIsWord = range.location > 0 && isWordCharacter(at: range.location - 1, in: source)
        let after = NSMaxRange(range)
        let afterIsWord = after < source.length && isWordCharacter(at: after, in: source)
        return !beforeIsWord && !afterIsWord
    }

    private func isWordCharacter(at location: Int, in source: NSString) -> Bool {
        guard source.length > 0, location >= 0, location < source.length else { return false }
        let range = source.rangeOfComposedCharacterSequence(at: location)
        return source.substring(with: range).unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    /// Called by the text view on paste and drop. Returning nil lets the text
    /// view handle the pasteboard normally.
    private func handleAttachment(_ pasteboard: NSPasteboard) -> String? {
        guard let vaultRoot = model.vaultRoot else { return nil }
        let destination = Attachments.Destination(
            rules: AttachmentSettings.shared.rules,
            index: model.index,
            settings: model.settings
        )
        do {
            if let payload = Attachments.imagePayload(from: pasteboard) {
                return try Attachments.save(
                    imageData: payload.data, preferredName: payload.name,
                    vaultRoot: vaultRoot, noteURL: model.current?.url,
                    settings: model.settings, destination: destination
                )
            }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
               let file = urls.first, file.isFileURL {
                return try Attachments.importFile(
                    at: file, vaultRoot: vaultRoot,
                    noteURL: model.current?.url, settings: model.settings,
                    destination: destination
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
    @ObservedObject private var vim = VimSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            if vim.isEnabled {
                Text("-- \(vim.mode.rawValue) --")
                    .fontWeight(.semibold)
                if let message = vim.message { Text(message).lineLimit(1) }
            }
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
            Text("\(model.scopedNoteCountLabel) in \(model.scopeName)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            HStack {
                Button("Quick Open…") { model.isQuickOpenPresented = true }
                if model.dailyNotesAreInScope {
                    Button("Today's Note") { model.openDailyNote(for: Date()) }
                }
            }
        }
    }
}
