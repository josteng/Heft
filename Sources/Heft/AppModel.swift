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
    @Published var isInspectorVisible = true
    @Published var isQuickOpenPresented = false
    @Published var calendarMonth = Date()
    @Published var expandedFolders: Set<String> = []
    @Published var status: String = ""

    private var watcher: VaultWatcher?
    private var saveTask: Task<Void, Never>?
    private var lastKnownModification: Date?
    private static let vaultPathKey = "dev.stenglein.Heft.vaultPath"

    var dailyNotes: DailyNotes? {
        vaultRoot.map { DailyNotes(vaultRoot: $0, settings: settings) }
    }

    init() {
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

    func createNote() {
        guard let vaultRoot else { promptForVault(); return }
        let folder = current?.url.deletingLastPathComponent() ?? vaultRoot
        var target = folder.appendingPathComponent("Untitled.md")
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("Untitled \(counter).md")
            counter += 1
        }
        createFile(at: target, contents: "")
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

    func insertAtCursor(_ snippet: String) {
        NotificationCenter.default.post(name: .heftInsertSnippet, object: snippet)
    }
}

extension Notification.Name {
    static let heftInsertSnippet = Notification.Name("dev.stenglein.Heft.insertSnippet")
}
