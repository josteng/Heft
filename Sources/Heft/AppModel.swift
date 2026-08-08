import AppKit
import Combine
import HeftCore
import SwiftUI

private enum DailyNotesSetupError: LocalizedError {
    case noVault
    case emptyFormat
    case emptyTemplatePath
    case invalidPath(String)
    case templateAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .noVault:
            return "Open a vault before setting up daily notes."
        case .emptyFormat:
            return "Enter a filename format."
        case .emptyTemplatePath:
            return "Enter a path for the template."
        case .invalidPath(let path):
            return "\(path) is not a valid path inside the vault."
        case .templateAlreadyExists(let path):
            return "\(path) already exists with different contents. Choose another path so it is not overwritten."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: Vault state
    let workspaceID: UUID
    private let registry: VaultRegistry
    private var session: VaultSession?
    private var sessionChangeSubscription: AnyCancellable?
    private var diskChangeSubscription: AnyCancellable?

    var vaultRoot: URL? { session?.root }
    var settings: ObsidianSettings { session?.settings ?? ObsidianSettings() }
    var tree: VaultItem? { session?.tree }
    var index: VaultIndex { session?.index ?? .empty }
    var isLoading: Bool { session?.isLoading ?? false }

    /// Nil means the entire vault. A non-empty path is a view boundary only:
    /// link resolution and the underlying index remain vault-wide.
    @Published private(set) var scopePath: String?

    var scopeRoot: URL? {
        guard let root = vaultRoot else { return nil }
        guard let scopePath else { return root }
        return root.appendingPathComponent(scopePath, isDirectory: true)
    }

    var scopeName: String { scopePath?.split(separator: "/").last.map(String.init) ?? "Entire Vault" }
    var vaultName: String { vaultRoot?.lastPathComponent ?? "Heft" }

    var scopedTree: VaultItem? {
        guard let tree else { return nil }
        guard let scopePath else { return tree }
        return tree.flattened().first { $0.isFolder && $0.relativePath == scopePath }
    }

    var scopedNotes: [NoteRef] { index.notes.filter(isInScope) }

    func isInScope(_ note: NoteRef) -> Bool {
        guard let scopePath else { return true }
        return note.relativePath.hasPrefix(scopePath + "/")
    }

    // MARK: Open document
    @Published private(set) var current: NoteRef?
    @Published var text: String = "" { didSet { textDidChange(from: oldValue) } }
    @Published private(set) var isDirty = false
    /// Bumped whenever `text` is replaced from outside the editor, so the
    /// NSTextView knows to reset rather than treat it as user typing.
    @Published private(set) var documentGeneration = 0

    // MARK: UI state
    @Published var isCalendarVisible = true
    /// Driven explicitly rather than left to the system. Without this, a
    /// collapsed sidebar is restored on the next launch and the app reopens
    /// with no visible file tree. Lives here rather than as view state so the
    /// View menu can toggle it too.
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var isInspectorVisible = false
    /// Three narrow pickers rather than one that does everything. A combined
    /// palette was tried and removed: mixing content hits into a note switcher
    /// made the common case — jump to a note by name — slower and noisier,
    /// which is the opposite of what a switcher is for.
    @Published var isQuickOpenPresented = false
    @Published var isCommandPalettePresented = false
    @Published var isVaultSearchPresented = false
    @Published var isDailyNotesSettingsPresented = false
    private var shouldPresentDailyNotesSettingsAfterPalette = false
    @Published var isFindPresented = false
    @Published private(set) var findFocusGeneration = 0
    @Published private(set) var findNavigationGeneration = 0
    @Published private(set) var findNavigationDirection = 1
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

    @Published private var navigationHistory: [String] = []
    @Published private var navigationIndex = -1
    /// Line the editor should jump to once the note is open, 1-based. Consumed
    /// by the editor, which clears it.
    @Published var pendingLineReveal: Int?

    var recentNotes: [NoteRef] {
        (session?.recentPaths ?? [])
            .compactMap { index.note(atRelativePath: $0) }
            .filter(isInScope)
    }

    var canNavigateBack: Bool { navigationIndex > 0 }
    var canNavigateForward: Bool {
        navigationIndex >= 0 && navigationIndex + 1 < navigationHistory.count
    }

    func showFind() {
        isFindPresented = true
        findFocusGeneration += 1
    }

    func findNext() {
        isFindPresented = true
        findNavigationDirection = 1
        findNavigationGeneration += 1
    }

    func findPrevious() {
        isFindPresented = true
        findNavigationDirection = -1
        findNavigationGeneration += 1
    }

    private var saveTask: Task<Void, Never>?
    private var lastKnownModification: Date?
    private static let colorfulFormattingKey = "dev.stenglein.Heft.colorfulFormatting"

    var dailyNotes: DailyNotes? {
        vaultRoot.map { DailyNotes(vaultRoot: $0, settings: settings) }
    }

    /// Whether the configured daily-note path lives below this window's
    /// focused folder. The calendar can still be enabled manually when false.
    var dailyNotesAreInScope: Bool {
        guard let scopePath else { return true }
        guard let dailyNotes else { return false }
        return dailyNotes.relativePath(for: Date()).hasPrefix(scopePath + "/")
    }

    init(registry: VaultRegistry, descriptor: WorkspaceDescriptor? = nil) {
        self.registry = registry
        workspaceID = descriptor?.id ?? UUID()
        scopePath = descriptor?.scopePath
        isColorfulFormattingEnabled = UserDefaults.standard.bool(forKey: Self.colorfulFormattingKey)
        // `--vault <path>` and `--open <relative-path>` let a launch go
        // straight to a known state, which is how the app gets driven during
        // development without clicking through it.
        let arguments = CommandLine.arguments
        var launchVault: URL?
        if let path = descriptor?.vaultPath {
            launchVault = URL(fileURLWithPath: path)
        } else if let index = arguments.firstIndex(of: "--vault"), index + 1 < arguments.count {
            launchVault = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        } else {
            launchVault = registry.lastVaultURL
        }

        if let launchVault, FileManager.default.fileExists(atPath: launchVault.path) {
            openVault(at: launchVault)
            if let requestedScope = descriptor?.scopePath {
                let folder = launchVault.appendingPathComponent(requestedScope, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    scopePath = requestedScope
                    registry.updateFocus(root: launchVault, scopePath: requestedScope, for: workspaceID)
                }
            }
        }

        isCalendarVisible = descriptor?.calendarVisible ?? dailyNotesAreInScope

        let requestedNote = descriptor?.notePath ?? arguments.firstIndex(of: "--open").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        if let relative = requestedNote {
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
        let chosen = url.standardizedFileURL
        if let nested = registry.activeSession(nestedInside: chosen) {
            status = "Close \(nested.root.lastPathComponent) before opening its parent as a vault"
            return
        }
        let containing = registry.activeSession(containing: chosen)
        let root = containing?.root ?? chosen
        let requestedScope: String? = chosen.path == root.path
            ? nil
            : String(chosen.path.dropFirst(root.path.count + 1))

        flushPendingSave()
        if let current { registry.release(current.url, for: workspaceID) }
        scopePath = requestedScope
        attach(to: registry.session(for: root))

        // Obsidian's own vim setting is a reasonable default for the editor,
        // even though modal editing itself is not implemented yet.
        current = nil
        text = ""
        isDirty = false
        navigationHistory = []
        navigationIndex = -1
        if let requestedScope {
            status = "Focused on \(requestedScope)"
        } else {
            status = "Opening \(root.lastPathComponent)…"
        }
    }

    private func attach(to session: VaultSession) {
        self.session = session
        registry.updateFocus(root: session.root, scopePath: scopePath, for: workspaceID)
        sessionChangeSubscription = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        diskChangeSubscription = session.$diskChangeGeneration.dropFirst().sink { [weak self] _ in
            self?.reloadCurrentIfChangedExternally()
        }
        objectWillChange.send()
    }

    func reload() {
        session?.reload()
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
        open(ref, recordingNavigation: true)
    }

    /// Opens a note and puts the caret on `line`, as a search result does.
    func open(_ ref: NoteRef, revealingLine line: Int) {
        open(ref, recordingNavigation: true)
        guard current?.relativePath == ref.relativePath else { return }
        pendingLineReveal = line
    }

    private func recordRecent(_ relativePath: String) {
        session?.recordRecent(relativePath)
    }

    private func open(_ ref: NoteRef, recordingNavigation: Bool) {
        guard ref.isMarkdown else {
            NSWorkspace.shared.open(ref.url)
            return
        }
        if current?.url.standardizedFileURL != ref.url.standardizedFileURL,
           !registry.claim(ref.url, for: workspaceID) {
            if !registry.focusWindowEditing(ref.url) {
                // The old window disappeared between the failed claim and the
                // focus attempt. Its stale lease has now been removed; retry.
                open(ref, recordingNavigation: recordingNavigation)
                return
            }
            status = "Focused the window already editing \(ref.name)"
            return
        }

        let previous = current
        flushPendingSave()

        if let contents = read(ref.url) {
            if recordingNavigation { recordNavigation(to: ref.relativePath) }
            recordRecent(ref.relativePath)
            current = ref
            setText(contents)
            isDirty = false
            lastKnownModification = (try? FileManager.default
                .attributesOfItem(atPath: ref.url.path))?[.modificationDate] as? Date
            status = ref.relativePath
            revealInTree(ref.relativePath)
            if let previous, previous.url.standardizedFileURL != ref.url.standardizedFileURL {
                registry.release(previous.url, for: workspaceID)
            }
        } else {
            if previous?.url.standardizedFileURL != ref.url.standardizedFileURL {
                registry.release(ref.url, for: workspaceID)
            }
            status = "Could not read \(ref.name)"
        }
    }

    func navigateBack() {
        navigateHistory(by: -1)
    }

    func navigateForward() {
        navigateHistory(by: 1)
    }

    private func recordNavigation(to relativePath: String) {
        guard current?.relativePath != relativePath else { return }

        // A rename can update `current` directly. Reconcile the active entry
        // before branching so Back returns to the renamed note, not its stale
        // path.
        if navigationHistory.indices.contains(navigationIndex), let current {
            navigationHistory[navigationIndex] = current.relativePath
        }

        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)...)
        }
        navigationHistory.append(relativePath)
        navigationIndex = navigationHistory.count - 1

        // Keep years of routine navigation from growing without bound.
        if navigationHistory.count > 200 {
            let overflow = navigationHistory.count - 200
            navigationHistory.removeFirst(overflow)
            navigationIndex -= overflow
        }
    }

    private func navigateHistory(by offset: Int) {
        guard offset == -1 || offset == 1, let vaultRoot else { return }
        var candidate = navigationIndex + offset

        while navigationHistory.indices.contains(candidate) {
            let url = vaultRoot.appendingPathComponent(navigationHistory[candidate])
            if FileManager.default.fileExists(atPath: url.path),
               let ref = NoteRef(url: url, vaultRoot: vaultRoot) {
                open(ref, recordingNavigation: false)
                if current?.relativePath == ref.relativePath {
                    navigationIndex = candidate
                    return
                }
            }
            candidate += offset
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
        // An unresolved link proposes a note beside the current one when it
        // carries no explicit folder. Creation remains explicit: a stray click
        // must never add a file to the vault.
        let name = link.target
        guard !name.isEmpty else { return }
        let relative = name.hasSuffix(".md") ? name : name + ".md"
        let target = name.contains("/")
            ? vaultRoot.appendingPathComponent(relative)
            : (current?.url.deletingLastPathComponent() ?? vaultRoot).appendingPathComponent(relative)

        // The index rebuild is asynchronous, so a newly appeared file may
        // already exist on disk even when resolution above has not caught up.
        if FileManager.default.fileExists(atPath: target.path) {
            if let ref = NoteRef(url: target, vaultRoot: vaultRoot) { open(ref) }
            return
        }

        let title = (target.lastPathComponent as NSString).deletingPathExtension
        guard FilePrompt.confirm(
            title: "Create Note?",
            message: "\(title) does not exist. Create it at \(relativePath(of: target))?",
            confirm: "Create Note"
        ) else { return }

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
        let directory = folder ?? current?.url.deletingLastPathComponent() ?? scopeRoot ?? vaultRoot
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
        guard !item.isFolder || !registry.isFocusedByAnotherWindow(item.url, excluding: workspaceID) else {
            status = "Another window is focused on \(item.name); show its entire vault before renaming"
            return
        }
        guard !registry.isClaimedByAnotherWindow(
            item.url, excluding: workspaceID, includingDescendants: item.isFolder
        ) else {
            status = "Close \(item.name) in the other window before renaming it"
            return
        }
        guard item.isFolder || !backlinkSourcesAreOpenElsewhere(for: item.relativePath) else {
            status = "Close notes linking to \(item.name) in other windows before renaming it"
            return
        }
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
            let renamedPath = relativePath(of: target)
            if item.isFolder, let scopePath,
               scopePath == item.relativePath || scopePath.hasPrefix(item.relativePath + "/") {
                self.scopePath = renamedPath + String(scopePath.dropFirst(item.relativePath.count))
                if let vaultRoot {
                    registry.updateFocus(root: vaultRoot, scopePath: self.scopePath, for: workspaceID)
                }
            }
            if !item.isFolder {
                navigationHistory = navigationHistory.map {
                    $0 == item.relativePath ? renamedPath : $0
                }
            }
            if wasOpen, let root = vaultRoot, let ref = NoteRef(url: target, vaultRoot: root) {
                registry.release(item.url, for: workspaceID)
                _ = registry.claim(target, for: workspaceID)
                current = ref
            }

            status = "Renamed to \(filename)"
            if !item.isFolder && hasHiddenExtension {
                let updated = repointLinks(from: item.relativePath, to: renamedPath)
                if updated.links > 0 {
                    status += ", repointed \(updated.links) link\(updated.links == 1 ? "" : "s")"
                        + " in \(updated.notes) note\(updated.notes == 1 ? "" : "s")"
                }
            }
            reload()
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
        }
    }

    /// Rewrites every wikilink that pointed at a just-renamed note.
    ///
    /// Driven off the *pre-rename* index, which still maps the old name to the
    /// old file, so "did this link mean that note" is answered by the same
    /// resolution the editor was using a moment ago rather than by string
    /// comparison — which would miss `[[folder/Note]]` and `[[Note.md]]`, and
    /// would wrongly claim a same-named note in another folder.
    ///
    /// Returns how much was touched, for the status line. A folder rename is
    /// deliberately not handled: it moves many notes at once and belongs to a
    /// bulk operation with its own confirmation.
    private func repointLinks(from oldPath: String, to newRelativePath: String) -> (links: Int, notes: Int) {
        let sources = Set(index.backlinks(to: oldPath).map(\.source.relativePath))
        guard !sources.isEmpty else { return (0, 0) }

        var totalLinks = 0
        var touchedNotes = 0

        for path in sources.sorted() {
            guard let source = index.note(atRelativePath: path) else { continue }
            // The open note is read from the buffer: it may hold unsaved edits,
            // and writing the file underneath it would lose them at the next
            // autosave anyway.
            let isOpen = current?.relativePath == path
            guard let original = isOpen ? text : try? String(contentsOf: source.url, encoding: .utf8)
            else { continue }

            let result = WikiLinkParser.rewriteTargets(
                in: original,
                matches: { index.resolve($0, from: source)?.relativePath == oldPath },
                replacement: { WikiLinkParser.retargeted($0.target, to: newRelativePath) }
            )
            guard result.count > 0, result.text != original else { continue }

            if isOpen {
                text = result.text
                documentGeneration += 1
            } else {
                do { try result.text.write(to: source.url, atomically: true, encoding: .utf8) }
                catch { continue }
            }
            totalLinks += result.count
            touchedNotes += 1
        }
        return (totalLinks, touchedNotes)
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
        guard !item.isFolder || !registry.isFocusedByAnotherWindow(item.url, excluding: workspaceID) else {
            status = "Another window is focused on \(item.name); show its entire vault before deleting"
            return
        }
        guard !registry.isClaimedByAnotherWindow(
            item.url, excluding: workspaceID, includingDescendants: item.isFolder
        ) else {
            status = "Close \(item.name) in the other window before moving it to the Trash"
            return
        }
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
            if let current { registry.release(current.url, for: workspaceID) }
            current = nil
            setText("")
            isDirty = false
        }

        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            if item.isFolder, let scopePath,
               scopePath == item.relativePath || scopePath.hasPrefix(item.relativePath + "/") {
                showEntireVault()
            }
            reload()
            status = "Moved \(item.name) to the Trash"
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Moves notes, attachments or folders into `folder`.
    ///
    /// The tree is sorted, never hand-ordered, so a drop only ever means "put
    /// this inside that" — there is no position to insert at. That is what
    /// keeps drag and drop here small: no drop indicators between rows, no
    /// ordering to persist.
    func move(_ urls: [URL], into folder: URL) {
        guard let vaultRoot else { return }
        var moved = 0
        var repointed = (links: 0, notes: 0)

        for url in urls {
            let name = url.lastPathComponent
            let destination = folder.appendingPathComponent(name)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            guard !isFolder || !registry.isFocusedByAnotherWindow(url, excluding: workspaceID) else {
                status = "Another window is focused on \(name); show its entire vault before moving it"
                continue
            }

            guard !registry.isClaimedByAnotherWindow(
                url, excluding: workspaceID, includingDescendants: isFolder
            ) else {
                status = "Close \(name) in the other window before moving it"
                continue
            }

            // A drop can carry anything Finder had on the pasteboard. Only
            // things already in the vault are moved: pulling a file in from
            // elsewhere would take it out of wherever the user keeps it, which
            // is not what dragging something onto a note list should mean.
            guard url.standardizedFileURL.path.hasPrefix(vaultRoot.standardizedFileURL.path + "/")
            else {
                status = "\(name) is outside the vault"
                continue
            }

            // Already there.
            guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL
            else { continue }
            // Into itself, or into its own descendant: the move would delete it.
            guard !isFolder || !folder.path.hasPrefix(url.path + "/") else {
                status = "Cannot move \(name) inside itself"
                continue
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                status = "\(name) already exists in \(describe(folder))"
                continue
            }

            let oldPath = relativePath(of: url)
            guard isFolder || !backlinkSourcesAreOpenElsewhere(for: oldPath) else {
                status = "Close notes linking to \(name) in other windows before moving it"
                continue
            }
            let wasOpen = current?.relativePath == oldPath
            if wasOpen { flushPendingSave() }

            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                status = "Could not move \(name): \(error.localizedDescription)"
                continue
            }

            let newPath = relativePath(of: destination)
            if isFolder, let scopePath,
               scopePath == oldPath || scopePath.hasPrefix(oldPath + "/") {
                self.scopePath = newPath + String(scopePath.dropFirst(oldPath.count))
                registry.updateFocus(root: vaultRoot, scopePath: self.scopePath, for: workspaceID)
            }
            navigationHistory = navigationHistory.map { $0 == oldPath ? newPath : $0 }
            session?.replaceRecentPath(oldPath, with: newPath)
            if wasOpen, let ref = NoteRef(url: destination, vaultRoot: vaultRoot) {
                registry.release(url, for: workspaceID)
                _ = registry.claim(destination, for: workspaceID)
                current = ref
            }

            // A link written as a bare name still resolves after a move, so
            // this usually rewrites nothing; it is the `[[folder/Note]]` form
            // that would otherwise break.
            if !isFolder {
                let result = repointLinks(from: oldPath, to: newPath)
                repointed.links += result.links
                repointed.notes += result.notes
            }
            moved += 1
        }

        guard moved > 0 else { return }
        status = "Moved \(moved) item\(moved == 1 ? "" : "s") to \(describe(folder))"
        if repointed.links > 0 {
            status += ", repointed \(repointed.links) link\(repointed.links == 1 ? "" : "s")"
        }
        expandedFolders.insert(relativePath(of: folder))
        reload()
    }

    /// Picks a destination folder and moves `item` into it.
    ///
    /// Drag and drop is the quicker way, but it needs both ends visible at
    /// once; moving into a collapsed corner of a large vault is easier chosen
    /// from a list.
    func promptToMove(_ item: VaultItem) {
        guard let vaultRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.prompt = "Move"
        panel.message = "Choose a folder inside the vault to move \(item.name) into."
        guard panel.runModal() == .OK, let target = panel.url else { return }

        let root = vaultRoot.standardizedFileURL.path
        let chosen = target.standardizedFileURL.path
        guard chosen == root || chosen.hasPrefix(root + "/") else {
            status = "That folder is outside the vault"
            return
        }
        move([item.url], into: target)
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

    private func backlinkSourcesAreOpenElsewhere(for relativePath: String) -> Bool {
        index.backlinks(to: relativePath).contains {
            registry.isClaimedByAnotherWindow($0.source.url, excluding: workspaceID)
        }
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

    @discardableResult
    func openDailyNote(for date: Date) -> Bool {
        guard let daily = dailyNotes, let vaultRoot else {
            promptForVault()
            return false
        }

        let exists = daily.exists(for: date)
        if !exists {
            guard FilePrompt.confirm(
                title: "Create Daily Note?",
                message: "No daily note exists for \(date.formatted(date: .long, time: .omitted)). Create it at \(daily.relativePath(for: date))?",
                confirm: "Create Note"
            ) else { return false }
        }

        do {
            let url = try daily.ensureNote(for: date)
            guard let ref = NoteRef(url: url, vaultRoot: vaultRoot) else { return false }
            open(ref)
            if !exists { reload() }
            return true
        } catch {
            status = "Could not create daily note: \(error.localizedDescription)"
            return false
        }
    }

    func hasDailyNote(for date: Date) -> Bool {
        dailyNotes?.exists(for: date) ?? false
    }

    func presentDailyNotesSettings() {
        if isCommandPalettePresented {
            shouldPresentDailyNotesSettingsAfterPalette = true
            isCommandPalettePresented = false
        } else {
            isDailyNotesSettingsPresented = true
        }
    }

    func commandPaletteDidDismiss() {
        guard shouldPresentDailyNotesSettingsAfterPalette else { return }
        shouldPresentDailyNotesSettingsAfterPalette = false
        isDailyNotesSettingsPresented = true
    }

    var hasDailyNoteTemplate: Bool {
        dailyNotes?.templateBody() != nil
    }

    /// Creates the daily-note folder and template, then points Obsidian's
    /// daily-notes configuration at them. Saving may update the template that
    /// is already configured, but never replaces an unrelated existing file.
    func configureDailyNotes(
        folder: String, format: String, templatePath: String, templateBody: String
    ) throws {
        guard let vaultRoot else { throw DailyNotesSetupError.noVault }

        let folder = try safeVaultRelativePath(folder, allowingEmpty: true)
        let format = format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.isEmpty else { throw DailyNotesSetupError.emptyFormat }
        _ = try safeVaultRelativePath(
            MomentFormat.format(Date(), pattern: format) + ".md", allowingEmpty: false
        )

        var templatePath = try safeVaultRelativePath(templatePath, allowingEmpty: false)
        if templatePath.lowercased().hasSuffix(".md") {
            templatePath.removeLast(3)
        }
        guard !templatePath.isEmpty else { throw DailyNotesSetupError.emptyTemplatePath }

        let dailyFolderURL = folder.isEmpty
            ? vaultRoot
            : vaultRoot.appendingPathComponent(folder, isDirectory: true)
        let templateURL = vaultRoot.appendingPathComponent(templatePath + ".md")

        let configuredTemplatePath = settings.dailyNoteTemplate.map {
            $0.lowercased().hasSuffix(".md") ? String($0.dropLast(3)) : $0
        }
        let mayReplaceTemplate = configuredTemplatePath?.caseInsensitiveCompare(templatePath)
            == .orderedSame
        let templateExists = FileManager.default.fileExists(atPath: templateURL.path)
        if templateExists {
            let existing = try String(contentsOf: templateURL, encoding: .utf8)
            guard existing == templateBody || mayReplaceTemplate else {
                throw DailyNotesSetupError.templateAlreadyExists(templatePath + ".md")
            }
        }

        try FileManager.default.createDirectory(
            at: dailyFolderURL, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !templateExists || mayReplaceTemplate {
            try templateBody.write(to: templateURL, atomically: true, encoding: .utf8)
        }

        var updated = settings
        updated.dailyNotesFolder = folder
        updated.dailyNoteFormat = format
        updated.dailyNoteTemplate = templatePath
        try updated.saveDailyNotesConfiguration(vaultRoot: vaultRoot)
        session?.reload()
        status = "Daily notes set up in \(folder.isEmpty ? vaultName : folder)"
    }

    func templateBody(at relativePath: String) -> String? {
        guard let vaultRoot,
              let path = try? safeVaultRelativePath(relativePath, allowingEmpty: false)
        else { return nil }
        let withExtension = path.lowercased().hasSuffix(".md") ? path : path + ".md"
        return try? String(
            contentsOf: vaultRoot.appendingPathComponent(withExtension), encoding: .utf8
        )
    }

    private func safeVaultRelativePath(_ raw: String, allowingEmpty: Bool) throws -> String {
        let whitespaceTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whitespaceTrimmed.hasPrefix("/") else {
            throw DailyNotesSetupError.invalidPath(raw)
        }
        let trimmed = whitespaceTrimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            if allowingEmpty { return "" }
            throw DailyNotesSetupError.emptyTemplatePath
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DailyNotesSetupError.invalidPath(raw)
        }
        return parts.joined(separator: "/")
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
            self?.save()
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty { save() }
    }

    func save() {
        guard isDirty, let current else { return }
        do {
            try text.write(to: current.url, atomically: true, encoding: .utf8)
            isDirty = false
            lastKnownModification = (try? FileManager.default
                .attributesOfItem(atPath: current.url.path))?[.modificationDate] as? Date
            status = "Saved \(current.relativePath)"
            reindexIfMetadataChanged(for: current)
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Rebuilds the index after Heft's own save, when the note's metadata moved.
    ///
    /// The watcher is created with `kFSEventStreamCreateFlagIgnoreSelf`, so
    /// writes made here never come back as filesystem events — and nothing else
    /// rebuilds the index. A tag added in Heft stayed missing from the tag list,
    /// and a new link never showed up in backlinks, until the vault changed from
    /// outside or the app was restarted.
    ///
    /// A rebuild re-reads every note in the vault, so it is worth doing only
    /// when the note's *metadata* actually changed. Typing prose — very nearly
    /// all typing — moves neither its tags nor its links and costs nothing here.
    private func reindexIfMetadataChanged(for note: NoteRef) {
        let tags = NoteTags.all(in: text)
        var targets: [String] = []
        NoteText.forEachProseLine(text) { _, line in
            targets.append(contentsOf: WikiLinkParser.links(in: line).map(\.target))
        }

        guard tags != index.tags(of: note.relativePath)
            || targets != index.outgoingLinks(from: note.relativePath).map(\.target)
        else { return }
        reload()
    }

    // MARK: - Tree helpers

    func setScope(to folder: VaultItem?) {
        guard folder == nil || folder?.isFolder == true else { return }
        scopePath = folder?.relativePath
        if let vaultRoot { registry.updateFocus(root: vaultRoot, scopePath: scopePath, for: workspaceID) }
        expandedFolders = []
        status = folder.map { "Focused on \($0.relativePath)" } ?? "Showing the entire vault"
    }

    func promptForScope() {
        guard let vaultRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = scopeRoot ?? vaultRoot
        panel.prompt = "Focus"
        panel.message = "Choose a folder inside \(vaultName)."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let rootPath = vaultRoot.standardizedFileURL.path
        let chosenPath = chosen.standardizedFileURL.path
        guard chosenPath == rootPath || chosenPath.hasPrefix(rootPath + "/") else {
            status = "That folder is outside \(vaultName)"
            return
        }
        if chosenPath == rootPath {
            showEntireVault()
            return
        }
        let relative = String(chosenPath.dropFirst(rootPath.count + 1))
        guard let folder = tree?.flattened().first(where: {
            $0.isFolder && $0.relativePath == relative
        }) else {
            status = "That folder is not available in the vault yet"
            return
        }
        setScope(to: folder)
    }

    func showEntireVault() {
        setScope(to: nil)
    }

    func searchNotes(_ query: String, limit: Int = 50) -> [NoteRef] {
        let candidates = index.search(query, limit: max(index.notes.count, limit))
        return Array(candidates.filter(isInScope).prefix(limit))
    }

    func scopedNotes(taggedWith tag: String) -> [NoteRef] {
        index.notes(taggedWith: tag).filter(isInScope)
    }

    func scopedTags(matching query: String) -> [String] {
        index.tags(matching: query).filter { !scopedNotes(taggedWith: $0).isEmpty }
    }

    func descriptor(scopePath: String? = nil, notePath: String? = nil) -> WorkspaceDescriptor {
        WorkspaceDescriptor(
            vaultPath: vaultRoot?.path,
            scopePath: scopePath,
            notePath: notePath
        )
    }

    var restorationDescriptor: WorkspaceDescriptor {
        WorkspaceDescriptor(
            id: workspaceID,
            vaultPath: vaultRoot?.path,
            scopePath: scopePath,
            notePath: current?.relativePath,
            calendarVisible: isCalendarVisible
        )
    }

    func closeWorkspace() {
        flushPendingSave()
        registry.releaseAll(for: workspaceID)
    }

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
