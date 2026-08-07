import AppKit
import Combine
import HeftCore
import SwiftUI

enum EditorMode: String, CaseIterable, Identifiable {
    /// Hybrid: one editable buffer, markup hidden until the cursor enters a
    /// line. This makes a separate side-by-side pane redundant, so there is no
    /// split mode.
    case live
    case source
    case preview

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"
        case .source: "Source"
        case .preview: "Preview"
        }
    }
    var symbol: String {
        switch self {
        case .live: "text.cursor"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .preview: "doc.richtext"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: Vault state
    @Published private(set) var vaultRoot: URL?
    @Published private(set) var settings = ObsidianSettings()
    @Published private(set) var tree: VaultItem?
    @Published private(set) var index = VaultIndex.empty
    @Published private(set) var isLoading = false

    // MARK: Open document
    @Published private(set) var current: NoteRef?
    @Published var text: String = "" { didSet { textDidChange(from: oldValue) } }
    @Published private(set) var isDirty = false
    /// Bumped whenever `text` is replaced from outside the editor, so the
    /// NSTextView knows to reset rather than treat it as user typing.
    @Published private(set) var documentGeneration = 0

    // MARK: UI state
    @Published var viewMode: EditorMode = .live
    /// Escape hatch back to the hand-rolled TextKit 1 editor via
    /// `--legacy-editor`. It renders fewer constructs but still styles `#tags`
    /// and callouts, which the engine has no token for.
    let useLegacyEditor = CommandLine.arguments.contains("--legacy-editor")
    @Published var isCalendarVisible = true
    /// Driven explicitly rather than left to the system. Without this, a
    /// collapsed sidebar is restored on the next launch and the app reopens
    /// with no visible file tree. Lives here rather than as view state so the
    /// View menu can toggle it too.
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var isInspectorVisible = true
    @Published var isQuickOpenPresented = false
    @Published var isCommandPalettePresented = false
    @Published var isPresentationPresented = false
    @Published var isColorfulFormattingEnabled = false {
        didSet {
            UserDefaults.standard.set(
                isColorfulFormattingEnabled, forKey: Self.colorfulFormattingKey
            )
        }
    }
    @Published var calendarMonth = Date()
    @Published var expandedFolders: Set<String> = []
    @Published var status: String = ""

    private var watcher: VaultWatcher?
    private var saveTask: Task<Void, Never>?
    private var lastKnownModification: Date?
    private static let vaultPathKey = "dev.stenglein.Heft.vaultPath"
    private static let colorfulFormattingKey = "dev.stenglein.Heft.colorfulFormatting"

    var dailyNotes: DailyNotes? {
        vaultRoot.map { DailyNotes(vaultRoot: $0, settings: settings) }
    }

    init() {
        isColorfulFormattingEnabled = UserDefaults.standard.bool(forKey: Self.colorfulFormattingKey)
        // `--vault <path>` and `--open <relative-path>` let a launch go
        // straight to a known state, which is how the app gets driven during
        // development without clicking through it.
        let arguments = CommandLine.arguments
        var launchVault: URL?
        if let index = arguments.firstIndex(of: "--vault"), index + 1 < arguments.count {
            launchVault = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        } else if let saved = UserDefaults.standard.string(forKey: Self.vaultPathKey) {
            launchVault = URL(fileURLWithPath: saved)
        }

        if let launchVault, FileManager.default.fileExists(atPath: launchVault.path) {
            openVault(at: launchVault)
        }

        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
            let relative = arguments[index + 1]
            // The index builds asynchronously, so resolve against the file
            // system rather than waiting on it.
            if let root = vaultRoot {
                let url = root.appendingPathComponent(relative)
                if let ref = NoteRef(url: url, vaultRoot: root),
                   FileManager.default.fileExists(atPath: url.path) {
                    open(ref)
                }
            }
        }
    }

    // MARK: - Vault lifecycle

    func promptForVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        panel.message = "Choose a folder of markdown notes. An existing Obsidian vault works as-is."
        if let existing = vaultRoot { panel.directoryURL = existing.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(at: url)
    }

    func openVault(at url: URL) {
        watcher?.stop()
        vaultRoot = url
        settings = ObsidianSettings.load(vaultRoot: url)
        UserDefaults.standard.set(url.path, forKey: Self.vaultPathKey)

        // Obsidian's own vim setting is a reasonable default for the editor,
        // even though modal editing itself is not implemented yet.
        current = nil
        text = ""
        isDirty = false

        reload()
        watcher = VaultWatcher(root: url) { [weak self] in self?.vaultDidChangeOnDisk() }
    }

    /// Rescans and reindexes off the main thread; the vault is hundreds of
    /// files and this runs on every external change.
    func reload() {
        guard let root = vaultRoot else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let tree = VaultScanner.scan(root: root)
            let index = VaultIndex.build(root: tree)
            await MainActor.run {
                self.tree = tree
                self.index = index
                self.isLoading = false
                if self.current == nil { self.status = "\(index.notes.count) notes" }
            }
        }
    }

    private func vaultDidChangeOnDisk() {
        reload()
        reloadCurrentIfChangedExternally()
    }

    /// Picks up edits made elsewhere (another device via iCloud, or Obsidian
    /// itself). Local unsaved edits always win: we never clobber the buffer.
    private func reloadCurrentIfChangedExternally() {
        guard let current, !isDirty else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: current.url.path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified != lastKnownModification else { return }
        guard let fresh = try? String(contentsOf: current.url, encoding: .utf8), fresh != text else { return }
        lastKnownModification = modified
        setText(fresh)
    }

    // MARK: - Opening notes

    func open(_ ref: NoteRef) {
        guard ref.isMarkdown else {
            NSWorkspace.shared.open(ref.url)
            return
        }
        flushPendingSave()

        if let contents = read(ref.url) {
            current = ref
            setText(contents)
            isDirty = false
            lastKnownModification = (try? FileManager.default
                .attributesOfItem(atPath: ref.url.path))?[.modificationDate] as? Date
            status = ref.relativePath
            revealInTree(ref.relativePath)
        } else {
            status = "Could not read \(ref.name)"
        }
    }

    func open(item: VaultItem) {
        open(NoteRef(item: item))
    }

    /// Reads a note, asking iCloud to materialise it first if only a
    /// placeholder is present on disk.
    private func read(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }

        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            status = "Downloading \(url.lastPathComponent) from iCloud…"
            return nil
        }
        // Fall back to a lenient encoding rather than refusing to open the file.
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private func setText(_ new: String) {
        // Assign through the backing store so didSet does not mark it dirty.
        isApplyingExternalText = true
        text = new
        isApplyingExternalText = false
        documentGeneration += 1
    }

    private var isApplyingExternalText = false

    // MARK: - Links

    func follow(_ link: WikiLink) {
        guard let vaultRoot else { return }
        if let target = index.resolve(link, from: current) {
            if target.isMarkdown { open(target) } else { NSWorkspace.shared.open(target.url) }
            return
        }
        // Obsidian creates an unresolved note on click; mirror that, placing it
        // beside the current note when the link carried no explicit folder.
        let name = link.target
        guard !name.isEmpty else { return }
        let relative = name.hasSuffix(".md") ? name : name + ".md"
        let target = name.contains("/")
            ? vaultRoot.appendingPathComponent(relative)
            : (current?.url.deletingLastPathComponent() ?? vaultRoot).appendingPathComponent(relative)

        createFile(at: target, contents: "# \((relative as NSString).deletingPathExtension)\n\n")
    }

    /// Handles the internal URLs the preview renderer emits.
    func handle(url: URL) -> Bool {
        guard url.scheme == "heft" else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first(where: { $0.name == "target" })?.value ?? ""
        guard let decoded = value.removingPercentEncoding else { return true }
        follow(WikiLinkParser.links(in: "[[\(decoded)]]").first ?? WikiLink(target: decoded))
        return true
    }

    // MARK: - Creating notes

    /// Creates a note in `folder`, or beside the open note when none is given.
    ///
    /// Asks for the name up front. The filename *is* the note's title here:
    /// wikilinks address notes by it, so being dropped into an `Untitled.md`
    /// with no obvious way to name it leaves the note unlinkable.
    func createNote(in folder: URL? = nil) {
        guard let vaultRoot else { promptForVault(); return }
        let directory = folder ?? current?.url.deletingLastPathComponent() ?? vaultRoot
        // Pre-filled and selected, so Return alone still gives the old
        // behaviour and typing replaces it.
        let suggestion = (uniqueURL(in: directory, base: "Untitled", extension: "md")
            .lastPathComponent as NSString).deletingPathExtension

        guard let entered = FilePrompt.name(
            title: "New Note", message: "In \(describe(directory))",
            initial: suggestion, confirm: "Create"
        ) else { return }

        var filename = sanitised(entered)
        guard !filename.isEmpty else { return }
        if !filename.lowercased().hasSuffix(".md") { filename += ".md" }

        let target = directory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            // Opening the existing note beats silently doing nothing.
            status = "\(filename) already exists"
            if let ref = NoteRef(url: target, vaultRoot: vaultRoot) { open(ref) }
            return
        }
        createFile(at: target, contents: "")
    }

    /// Human-readable location for a folder, for use in prompts.
    private func describe(_ directory: URL) -> String {
        guard let vaultRoot else { return directory.lastPathComponent }
        return directory.path == vaultRoot.path
            ? "the vault root"
            : relativePath(of: directory)
    }

    func createFolder(in parent: URL) {
        guard vaultRoot != nil else { return }
        guard let name = FilePrompt.name(
            title: "New Folder", message: "Name for the new folder.", initial: "Untitled",
            confirm: "Create"
        ) else { return }

        let target = parent.appendingPathComponent(sanitised(name))
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            expandedFolders.insert(relativePath(of: target))
            reload()
            status = "Created \(relativePath(of: target))"
        } catch {
            status = "Could not create folder: \(error.localizedDescription)"
        }
    }

    /// A name not already taken in `directory`, as `Untitled`, `Untitled 1`, …
    private func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = directory.appendingPathComponent(base + suffix)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter)\(suffix)")
            counter += 1
        }
        return candidate
    }

    // MARK: - File operations

    func rename(_ item: VaultItem) {
        // Markdown items display without their extension, so it must not appear
        // in the field and must be put back afterwards.
        let hasHiddenExtension = item.isMarkdown
        guard let entered = FilePrompt.name(
            title: "Rename \(item.isFolder ? "Folder" : "Note")",
            message: item.relativePath, initial: item.name, confirm: "Rename"
        ) else { return }

        let cleaned = sanitised(entered)
        guard !cleaned.isEmpty, cleaned != item.name else { return }
        let filename = hasHiddenExtension && !cleaned.lowercased().hasSuffix(".md")
            ? cleaned + ".md"
            : cleaned
        let target = item.url.deletingLastPathComponent().appendingPathComponent(filename)

        guard !FileManager.default.fileExists(atPath: target.path) else {
            status = "\(filename) already exists"
            return
        }

        // Renaming the open note would otherwise leave the editor pointed at a
        // path that no longer exists, and the next autosave would recreate it.
        let wasOpen = current?.relativePath == item.relativePath
        if wasOpen { flushPendingSave() }

        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            if wasOpen, let root = vaultRoot, let ref = NoteRef(url: target, vaultRoot: root) {
                current = ref
            }
            reload()
            status = "Renamed to \(filename)"
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
        }
        // Links pointing at the old name are deliberately left alone: rewriting
        // them across the vault is a bulk edit, not a rename.
        if !item.isFolder && hasHiddenExtension {
            status += ". Links to the old name were not updated"
        }
    }

    func duplicate(_ item: VaultItem) {
        guard let vaultRoot else { return }
        let directory = item.url.deletingLastPathComponent()
        let ext = item.url.pathExtension
        let base = (item.url.lastPathComponent as NSString).deletingPathExtension
        let target = uniqueURL(in: directory, base: base + " copy", extension: ext)
        do {
            try FileManager.default.copyItem(at: item.url, to: target)
            reload()
            if item.isMarkdown, let ref = NoteRef(url: target, vaultRoot: vaultRoot) { open(ref) }
            status = "Duplicated to \(target.lastPathComponent)"
        } catch {
            status = "Duplicate failed: \(error.localizedDescription)"
        }
    }

    /// Moves to the Trash rather than unlinking, so a mis-click stays
    /// recoverable, and confirms first because this is the user's real vault.
    func delete(_ item: VaultItem) {
        let count = item.isFolder ? item.flattened().filter { !$0.isFolder }.count : 0
        let detail = item.isFolder
            ? "The folder and its \(count) file\(count == 1 ? "" : "s") will be moved to the Trash."
            : "It will be moved to the Trash."
        guard FilePrompt.confirm(
            title: "Delete \(item.name)?", message: detail, confirm: "Delete", destructive: true
        ) else { return }

        if current?.relativePath == item.relativePath
            || (item.isFolder && current?.relativePath.hasPrefix(item.relativePath + "/") == true) {
            // Drop the buffer first so the pending save cannot write the file
            // back out after it has gone.
            saveTask?.cancel()
            saveTask = nil
            current = nil
            setText("")
            isDirty = false
        }

        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            reload()
            status = "Moved \(item.name) to the Trash"
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToPasteboard(_ string: String, describedAs label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        status = "Copied \(label)"
    }

    /// Strips path separators so a typed name cannot move the file elsewhere.
    private func sanitised(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func relativePath(of url: URL) -> String {
        guard let vaultRoot else { return url.lastPathComponent }
        return url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
    }

    private func createFile(at url: URL, contents: String) {
        guard let vaultRoot else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            if let ref = NoteRef(url: url, vaultRoot: vaultRoot) { open(ref) }
            reload()
        } catch {
            status = "Could not create note: \(error.localizedDescription)"
        }
    }

    func openDailyNote(for date: Date) {
        guard let daily = dailyNotes, let vaultRoot else { promptForVault(); return }
        do {
            let url = try daily.ensureNote(for: date)
            if let ref = NoteRef(url: url, vaultRoot: vaultRoot) { open(ref) }
            reload()
        } catch {
            status = "Could not create daily note: \(error.localizedDescription)"
        }
    }

    func hasDailyNote(for date: Date) -> Bool {
        dailyNotes?.exists(for: date) ?? false
    }

    // MARK: - Saving

    private func textDidChange(from oldValue: String) {
        guard !isApplyingExternalText, current != nil, text != oldValue else { return }
        isDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty { Task { await save() } }
    }

    func save() async {
        guard isDirty, let current else { return }
        do {
            try text.write(to: current.url, atomically: true, encoding: .utf8)
            isDirty = false
            lastKnownModification = (try? FileManager.default
                .attributesOfItem(atPath: current.url.path))?[.modificationDate] as? Date
            status = "Saved \(current.relativePath)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tree helpers

    /// Expands every ancestor folder so a note opened from search or the
    /// calendar becomes visible in the sidebar.
    private func revealInTree(_ relativePath: String) {
        var parts = relativePath.split(separator: "/").map(String.init)
        parts.removeLast()
        var prefix = ""
        for part in parts {
            prefix = prefix.isEmpty ? part : "\(prefix)/\(part)"
            expandedFolders.insert(prefix)
        }
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.2)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    func insertAtCursor(_ snippet: String) {
        NotificationCenter.default.post(name: .heftInsertSnippet, object: snippet)
    }
}

extension Notification.Name {
    static let heftInsertSnippet = Notification.Name("dev.stenglein.Heft.insertSnippet")
}
