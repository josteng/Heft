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

struct SaveConflict: Identifiable, Equatable {
    let id = UUID()
    let noteName: String
    let relativePath: String
    let diskVersionExists: Bool
    /// The buffer as the editor holds it, and the file as it now reads.
    ///
    /// Both are captured when the conflict is raised rather than re-read when
    /// the review sheet opens: the diff the user is deciding about has to be
    /// the one they were shown, and a note being written from another device
    /// can change again while the sheet is up.
    let mine: String
    let disk: String?

    /// The hunks between the two, measured from the buffer. `removed` is
    /// therefore what the editor holds and `added` is what disk says instead,
    /// so accepting a hunk takes the outside change.
    func diff() -> NoteDiff {
        guard let disk else { return NoteDiff(hunks: []) }
        return NoteDiff.between(original: mine, proposed: disk)
    }
}

enum SaveConflictResolution {
    case keepMine
    case useDisk
    case cancel
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

    /// What the window shows beneath its title.
    ///
    /// Nothing here may depend on state that changes while typing. The
    /// subtitle shares its row with the toolbar's `.status` region, and the
    /// scope picker sits centred between two flexible spacers there, so a word
    /// that comes and goes drags the picker left and right with it. "Edited"
    /// used to be exactly that word: it was appended whenever `isDirty` was
    /// set, and autosave clears that 700ms after the last keystroke, so it
    /// appeared and vanished on a cycle for as long as anyone kept typing. A
    /// state with a 700ms lifetime is not worth a word, let alone a moving
    /// one; unsaved work is reported by `saveConflict`, which persists.
    var windowSubtitle: String {
        guard let current else {
            return vaultRoot == nil ? "" : "\(scopedNotes.count) notes · \(scopeName)"
        }
        let folder = current.folder
        var parts = [folder.isEmpty ? "Vault root" : folder]
        if !isInScope(current) { parts.append("Outside \(scopeName)") }
        return parts.joined(separator: " · ")
    }

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
    /// Whether that replacement was the same note changing underneath the
    /// reader — in which case caret and scroll survive it — or a different
    /// note being opened. Set in lockstep with `documentGeneration`, which is
    /// what the view observes.
    private(set) var documentGenerationKeepsPosition = false

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
    @Published var isInboxCapturePresented = false
    private var shouldPresentDailyNotesSettingsAfterPalette = false
    private var shouldPresentInboxCaptureAfterPalette = false
    @Published var isFindPresented = false
    @Published private(set) var findFocusGeneration = 0
    @Published private(set) var findNavigationGeneration = 0
    @Published private(set) var findNavigationDirection = 1
    @Published var isPresentationPresented = false
    @Published var calendarMonth = Date()
    @Published var expandedFolders: Set<String> = []
    @Published var status: String = ""
    /// Edits agents have proposed and nobody has answered yet, vault-wide.
    @Published private(set) var proposals: [Proposal] = []
    /// The proposal whose review sheet is open.
    @Published var reviewing: Proposal?
    @Published private(set) var saveConflict: SaveConflict?
    /// The conflict currently open in the merge sheet. Held separately from
    /// `saveConflict`, because dismissing the alert to show the sheet resolves
    /// the alert as `.cancel` and clears it.
    @Published var reviewingConflict: SaveConflict?
    /// Set when `promptForScope()`'s folder panel returns a folder outside
    /// the current vault. That can't become a focus folder, so the picker
    /// offers to open it as its own vault instead of failing silently.
    @Published var pendingOutsideVaultFolder: URL?

    @Published private var navigationHistory: [String] = []
    @Published private var navigationIndex = -1
    /// Line the editor should jump to once the note is open, 1-based. Consumed
    /// by the editor, which clears it.
    @Published var pendingLineReveal: Int?
    /// Text a command asked to be typed at the caret. Stamped with a
    /// generation so the editor performs it exactly once, the way a find
    /// selection is applied.
    @Published private(set) var pendingInsertion: EditorInsertion?

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
    private var externalChangePollTask: Task<Void, Never>?
    private var lastKnownModification: Date?
    /// Exact source last read from or written to disk. Comparing contents,
    /// rather than timestamps, catches same-tick writes and filesystems with
    /// coarse modification dates without producing false conflicts.
    private var lastKnownDiskText: String?

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

        startExternalChangePolling()
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

        guard flushPendingSave() else {
            status = "Resolve the save conflict before changing vaults"
            return
        }
        if let current { registry.release(current.url, for: workspaceID) }
        scopePath = requestedScope
        attach(to: registry.session(for: root))

        // Obsidian's own vim setting is a reasonable default for the editor,
        // even though modal editing itself is not implemented yet.
        current = nil
        text = ""
        isDirty = false
        lastKnownDiskText = nil
        saveConflict = nil
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
            self?.refreshProposals()
        }
        refreshProposals()
        objectWillChange.send()
    }

    func reload(immediately: Bool = false) {
        session?.reload(immediately: immediately)
    }

    /// Picks up edits made elsewhere (another device via iCloud, Obsidian, or
    /// an App Intent). Exact contents are authoritative: timestamps are only a
    /// hint and can remain unchanged for two writes in the same filesystem tick.
    private func reloadCurrentIfChangedExternally() {
        guard let current else { return }
        let exists = FileManager.default.fileExists(atPath: current.url.path)
        guard exists else {
            if isDirty {
                presentExternalChangeConflict(for: current, diskVersionExists: false)
            } else if lastKnownDiskText != nil {
                lastKnownDiskText = nil
                lastKnownModification = nil
                status = "\(current.name) was removed from disk"
            }
            return
        }

        guard let fresh = try? String(contentsOf: current.url, encoding: .utf8) else { return }
        let modified = modificationDate(of: current.url)
        guard fresh != lastKnownDiskText else {
            lastKnownModification = modified
            return
        }

        guard !isDirty else {
            presentExternalChangeConflict(for: current, diskVersionExists: true)
            return
        }

        lastKnownModification = modified
        lastKnownDiskText = fresh
        if fresh != text {
            setText(fresh, keepingPosition: true)
            status = "Reloaded \(current.relativePath) from disk"
        }
    }

    private func presentExternalChangeConflict(
        for current: NoteRef,
        diskVersionExists: Bool
    ) {
        guard saveConflict == nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveConflict = SaveConflict(
            noteName: current.name,
            relativePath: current.relativePath,
            diskVersionExists: diskVersionExists,
            mine: text,
            disk: diskVersionExists
                ? (try? String(contentsOf: current.url, encoding: .utf8))
                : nil
        )
        status = diskVersionExists
            ? "Save paused: \(current.name) changed on disk"
            : "Save paused: \(current.name) was removed from disk"
    }

    /// FSEvents remains the fast path. Polling one open file is a cheap safety
    /// net for same-process writers (which the vault watcher deliberately
    /// ignores), dropped events, and coarse filesystem modification dates.
    private func startExternalChangePolling() {
        externalChangePollTask?.cancel()
        externalChangePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.reloadCurrentIfChangedExternally()
            }
        }
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
        guard flushPendingSave() else {
            if previous?.url.standardizedFileURL != ref.url.standardizedFileURL {
                registry.release(ref.url, for: workspaceID)
            }
            status = "Resolve the save conflict before opening another note"
            return
        }

        if let contents = read(ref.url) {
            if recordingNavigation { recordNavigation(to: ref.relativePath) }
            recordRecent(ref.relativePath)
            current = ref
            setText(contents)
            isDirty = false
            lastKnownDiskText = contents
            saveConflict = nil
            lastKnownModification = modificationDate(of: ref.url)
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

    private func setText(_ new: String, keepingPosition: Bool = false) {
        // Assign through the backing store so didSet does not mark it dirty.
        isApplyingExternalText = true
        text = new
        isApplyingExternalText = false
        documentGenerationKeepsPosition = keepingPosition
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
        guard url.scheme == HeftURL.scheme else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Only a link click. `heft://open` arrives from outside the app and is
        // a vault to open, not a wikilink to follow; without this it would be
        // taken as a target named "…?path=…" and silently go nowhere.
        guard components?.host == HeftURL.Host.follow.rawValue else { return false }
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

    /// Creates a real, recoverable item immediately, then lets the sidebar put
    /// its suggested name into inline edit mode. Escape therefore leaves the
    /// harmless Untitled item behind, matching Finder rather than deleting a
    /// file as a side effect of cancelling a text field.
    func createUntitledNote(in directory: URL) -> (path: String, name: String)? {
        guard let vaultRoot else { return nil }
        let target = uniqueURL(in: directory, base: "Untitled", extension: "md")
        do {
            try "".write(to: target, atomically: true, encoding: .utf8)
            guard let ref = NoteRef(url: target, vaultRoot: vaultRoot) else { return nil }
            open(ref)
            let parentPath = relativePath(of: directory)
            if !parentPath.isEmpty { expandedFolders.insert(parentPath) }
            reload(immediately: true)
            status = "Created \(ref.relativePath)"
            return (ref.relativePath, ref.name)
        } catch {
            status = "Could not create note: \(error.localizedDescription)"
            return nil
        }
    }

    func createUntitledFolder(in parent: URL) -> (path: String, name: String)? {
        guard vaultRoot != nil else { return nil }
        let target = uniqueURL(in: parent, base: "Untitled", extension: "")
        do {
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: false
            )
            let parentPath = relativePath(of: parent)
            if !parentPath.isEmpty { expandedFolders.insert(parentPath) }
            let path = relativePath(of: target)
            reload(immediately: true)
            status = "Created \(path)"
            return (path, target.lastPathComponent)
        } catch {
            status = "Could not create folder: \(error.localizedDescription)"
            return nil
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

    @discardableResult
    func rename(_ item: VaultItem, to proposedName: String? = nil) -> Bool {
        guard !item.isFolder || !registry.isFocusedByAnotherWindow(item.url, excluding: workspaceID) else {
            status = "Another window is focused on \(item.name); show its entire vault before renaming"
            return false
        }
        guard !registry.isClaimedByAnotherWindow(
            item.url, excluding: workspaceID, includingDescendants: item.isFolder
        ) else {
            status = "Close \(item.name) in the other window before renaming it"
            return false
        }
        // Markdown items display without their extension, so it must not appear
        // in the field and must be put back afterwards.
        let hasHiddenExtension = item.isMarkdown
        let entered: String
        if let proposedName {
            entered = proposedName
        } else {
            guard let prompted = FilePrompt.name(
                title: "Rename \(item.isFolder ? "Folder" : "Note")",
                message: item.relativePath, initial: item.name, confirm: "Rename"
            ) else { return false }
            entered = prompted
        }

        let cleaned = sanitised(entered)
        guard !cleaned.isEmpty else { return false }
        guard cleaned != item.name else { return true }
        let filename = hasHiddenExtension && !cleaned.lowercased().hasSuffix(".md")
            ? cleaned + ".md"
            : cleaned
        let target = item.url.deletingLastPathComponent().appendingPathComponent(filename)

        guard !FileManager.default.fileExists(atPath: target.path) else {
            status = "\(filename) already exists"
            return false
        }

        let renamedPath = relativePath(of: target)
        let changes = pathChanges(for: item, movingTo: renamedPath)
        let currentOldPath = current?.relativePath
        if let currentOldPath, changes[currentOldPath] != nil,
           !flushPendingSave() {
            status = "Resolve the save conflict before renaming \(item.name)"
            return false
        }
        guard let rewrites = prepareLinkRewrites(for: changes) else { return false }

        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            if item.isFolder, let scopePath,
               scopePath == item.relativePath || scopePath.hasPrefix(item.relativePath + "/") {
                self.scopePath = renamedPath + String(scopePath.dropFirst(item.relativePath.count))
                if let vaultRoot {
                    registry.updateFocus(root: vaultRoot, scopePath: self.scopePath, for: workspaceID)
                }
            }
            navigationHistory = navigationHistory.map { changes[$0] ?? $0 }
            for (oldPath, newPath) in changes {
                session?.replaceRecentPath(oldPath, with: newPath)
            }
            if let currentOldPath, let currentNewPath = changes[currentOldPath],
               let root = vaultRoot,
               let ref = NoteRef(url: root.appendingPathComponent(currentNewPath), vaultRoot: root) {
                registry.release(root.appendingPathComponent(currentOldPath), for: workspaceID)
                _ = registry.claim(ref.url, for: workspaceID)
                current = ref
            }

            status = "Renamed to \(filename)"
            let updated = applyLinkRewrites(rewrites, after: changes)
            if updated.links > 0 {
                status += ", repointed \(updated.links) link\(updated.links == 1 ? "" : "s")"
                    + " in \(updated.notes) note\(updated.notes == 1 ? "" : "s")"
            }
            if updated.failures > 0 {
                status += "; \(updated.failures) note\(updated.failures == 1 ? "" : "s") changed concurrently and was left untouched"
            }
            reload(immediately: true)
            return true
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
            return false
        }
    }

    private struct LinkRewrite {
        let source: NoteRef
        let original: String
        let rewritten: String
        let count: Int
        let usesOpenBuffer: Bool
    }

    /// Builds file-level path changes for a note, attachment, or every file
    /// below a folder. The index is still pre-move here, so link resolution can
    /// identify intended targets without guessing from filenames.
    private func pathChanges(for item: VaultItem, movingTo newPath: String) -> [String: String] {
        guard item.isFolder else { return [item.relativePath: newPath] }
        return Dictionary(uniqueKeysWithValues: item.flattened().compactMap { descendant in
            guard !descendant.isFolder else { return nil }
            let suffix = descendant.relativePath.dropFirst(item.relativePath.count)
            return (descendant.relativePath, newPath + suffix)
        })
    }

    /// Reads and rewrites every source before the move, but performs no writes.
    /// A source open in another window blocks the operation, because writing
    /// underneath that window would defeat the editor lease.
    private func prepareLinkRewrites(for changes: [String: String]) -> [LinkRewrite]? {
        let sources = Set(changes.keys.flatMap {
            index.backlinks(to: $0).map(\.source.relativePath)
        })
        var plans: [LinkRewrite] = []

        for path in sources.sorted() {
            guard let source = index.note(atRelativePath: path) else { continue }
            guard !registry.isClaimedByAnotherWindow(source.url, excluding: workspaceID) else {
                status = "Close \(source.name) in the other window before moving linked files"
                return nil
            }
            let usesOpenBuffer = current?.relativePath == path
            guard let original = usesOpenBuffer
                ? text
                : try? String(contentsOf: source.url, encoding: .utf8)
            else {
                status = "Could not read \(source.relativePath) before updating its links"
                return nil
            }

            let result = WikiLinkParser.rewriteTargets(
                in: original,
                matches: { link in
                    guard let old = index.resolve(link, from: source)?.relativePath else {
                        return false
                    }
                    return changes[old] != nil
                },
                replacement: { link in
                    guard let old = index.resolve(link, from: source)?.relativePath,
                          let new = changes[old]
                    else { return link.target }
                    return WikiLinkParser.retargeted(link.target, to: new)
                }
            )
            guard result.count > 0, result.text != original else { continue }
            plans.append(LinkRewrite(
                source: source,
                original: original,
                rewritten: result.text,
                count: result.count,
                usesOpenBuffer: usesOpenBuffer
            ))
        }
        return plans
    }

    /// Applies prepared rewrites after the move. Sources that moved with a
    /// folder are addressed by their new path. A final content comparison
    /// prevents a last-millisecond external edit from being overwritten.
    private func applyLinkRewrites(
        _ plans: [LinkRewrite], after changes: [String: String]
    ) -> (links: Int, notes: Int, failures: Int) {
        guard let vaultRoot else { return (0, 0, plans.count) }
        var links = 0
        var notes = 0
        var failures = 0

        for plan in plans {
            if plan.usesOpenBuffer {
                text = plan.rewritten
                documentGeneration += 1
                links += plan.count
                notes += 1
                continue
            }

            let path = changes[plan.source.relativePath] ?? plan.source.relativePath
            let url = vaultRoot.appendingPathComponent(path)
            guard (try? String(contentsOf: url, encoding: .utf8)) == plan.original else {
                failures += 1
                continue
            }
            do {
                try plan.rewritten.write(to: url, atomically: true, encoding: .utf8)
                links += plan.count
                notes += 1
            } catch {
                failures += 1
            }
        }
        return (links, notes, failures)
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
        var repointed = (links: 0, notes: 0, failures: 0)

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
            let newPath = relativePath(of: destination)
            let indexedItem = tree?.flattened().first { $0.relativePath == oldPath }
            guard !isFolder || indexedItem != nil else {
                status = "Wait for the vault to finish loading before moving \(name)"
                continue
            }
            let movingItem = indexedItem ?? VaultItem(
                url: url, relativePath: oldPath, kind: .other, name: name
            )
            let changes = pathChanges(for: movingItem, movingTo: newPath)
            let currentOldPath = current?.relativePath
            if let currentOldPath, changes[currentOldPath] != nil,
               !flushPendingSave() {
                status = "Resolve the save conflict before moving \(name)"
                continue
            }
            guard let rewrites = prepareLinkRewrites(for: changes) else { continue }

            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                status = "Could not move \(name): \(error.localizedDescription)"
                continue
            }

            if isFolder, let scopePath,
               scopePath == oldPath || scopePath.hasPrefix(oldPath + "/") {
                self.scopePath = newPath + String(scopePath.dropFirst(oldPath.count))
                registry.updateFocus(root: vaultRoot, scopePath: self.scopePath, for: workspaceID)
            }
            navigationHistory = navigationHistory.map { changes[$0] ?? $0 }
            for (changedOldPath, changedNewPath) in changes {
                session?.replaceRecentPath(changedOldPath, with: changedNewPath)
            }
            if let currentOldPath, let currentNewPath = changes[currentOldPath],
               let ref = NoteRef(
                   url: vaultRoot.appendingPathComponent(currentNewPath), vaultRoot: vaultRoot
               ) {
                registry.release(
                    vaultRoot.appendingPathComponent(currentOldPath), for: workspaceID
                )
                _ = registry.claim(ref.url, for: workspaceID)
                current = ref
            }

            let result = applyLinkRewrites(rewrites, after: changes)
            repointed.links += result.links
            repointed.notes += result.notes
            repointed.failures += result.failures
            moved += 1
        }

        guard moved > 0 else { return }
        status = "Moved \(moved) item\(moved == 1 ? "" : "s") to \(describe(folder))"
        if repointed.links > 0 {
            status += ", repointed \(repointed.links) link\(repointed.links == 1 ? "" : "s")"
        }
        if repointed.failures > 0 {
            status += "; \(repointed.failures) concurrently changed note\(repointed.failures == 1 ? "" : "s") left untouched"
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
        let root = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        if candidate == root { return "" }
        guard candidate.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(candidate.dropFirst(root.count + 1))
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

    func presentInboxCapture() {
        guard vaultRoot != nil else {
            promptForVault()
            return
        }
        if isCommandPalettePresented {
            shouldPresentInboxCaptureAfterPalette = true
            isCommandPalettePresented = false
        } else {
            isInboxCapturePresented = true
        }
    }

    /// Types `text` at the caret, putting the caret `caretOffset` into it.
    ///
    /// Goes through the editor rather than the buffer so it joins the same
    /// undo, autosave and styling path as anything typed by hand.
    func insertAtCaret(_ text: String, caretOffset: Int) {
        pendingInsertion = EditorInsertion(
            text: text, caretOffset: caretOffset, startsBlock: false,
            generation: (pendingInsertion?.generation ?? 0) + 1
        )
    }

    /// Types a blank table at the caret. How many newlines it needs in front
    /// of it depends on where the caret is, which only the editor knows.
    func insertTable(rows: Int = 2, columns: Int = 2) {
        let table = TableEditing.blankTable(rows: rows, columns: columns, newlinesBefore: 0)
        pendingInsertion = EditorInsertion(
            text: table.text, caretOffset: table.caretOffset, startsBlock: true,
            generation: (pendingInsertion?.generation ?? 0) + 1
        )
    }

    func commandPaletteDidDismiss() {
        if shouldPresentDailyNotesSettingsAfterPalette {
            shouldPresentDailyNotesSettingsAfterPalette = false
            isDailyNotesSettingsPresented = true
        } else if shouldPresentInboxCaptureAfterPalette {
            shouldPresentInboxCaptureAfterPalette = false
            isInboxCapturePresented = true
        }
    }

    /// Adds a timestamped bullet without changing the note this window is
    /// showing. If Inbox.md itself is being edited here, save and reload it so
    /// the capture and the editor cannot silently overwrite each other.
    @discardableResult
    func captureToInbox(_ capture: String, at date: Date = Date()) -> Bool {
        guard let vaultRoot else {
            status = InboxCaptureError.vaultUnavailable.localizedDescription
            return false
        }

        let inbox = InboxCapture(vaultRoot: vaultRoot)
        let isEditingInbox = current?.url.standardizedFileURL == inbox.url.standardizedFileURL
        if isEditingInbox, !flushPendingSave() {
            status = "Resolve the Inbox save conflict before capturing"
            return false
        }

        do {
            let url = try inbox.capture(capture, at: date)
            if isEditingInbox, let ref = NoteRef(url: url, vaultRoot: vaultRoot) {
                open(ref, recordingNavigation: false)
            }
            reload(immediately: true)
            status = "Captured to Inbox.md"
            return true
        } catch {
            status = "Could not capture to Inbox: \(error.localizedDescription)"
            return false
        }
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
        updated.dailyNotesFolderIsConfigured = true
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

    @discardableResult
    func flushPendingSave() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        if isDirty { save() }
        return !isDirty
    }

    func save() {
        guard isDirty, let current else { return }

        let diskExists = FileManager.default.fileExists(atPath: current.url.path)
        let diskText = diskExists
            ? (try? String(contentsOf: current.url, encoding: .utf8))
            : nil

        // Never recreate a file that disappeared, or overwrite an externally
        // edited note, merely because the autosave timer fired. The buffer
        // stays intact until the user makes an explicit choice.
        if !diskExists || diskText != lastKnownDiskText {
            // Another writer may have produced exactly our buffered text.
            if diskText == text {
                lastKnownDiskText = text
                isDirty = false
                saveConflict = nil
                status = "Already saved \(current.relativePath)"
                return
            }
            saveConflict = SaveConflict(
                noteName: current.name,
                relativePath: current.relativePath,
                diskVersionExists: diskExists,
                mine: text,
                disk: diskText
            )
            status = diskExists
                ? "Save paused: \(current.name) changed on disk"
                : "Save paused: \(current.name) was removed from disk"
            return
        }

        writeCurrentBuffer()
    }

    /// Moves a conflict from the all-or-nothing alert into hunk-by-hunk review.
    /// Only a modified note can be reviewed; a removed one has no second
    /// version to diff against.
    /// Takes the conflict rather than reading `saveConflict`, because
    /// dismissing the alert to open the sheet clears it, and the order of the
    /// two is not ours to depend on.
    func reviewSaveConflict(_ conflict: SaveConflict) {
        guard conflict.disk != nil else { return }
        reviewingConflict = conflict
    }

    /// Writes the merged result of a reviewed conflict.
    ///
    /// This is the deliberate end of the conflict: the user has seen both
    /// versions and said what the file should read, so the merge is written
    /// even though disk no longer matches what Heft last loaded — exactly as
    /// `.keepMine` does.
    func applyMergedConflict(_ merged: String) {
        guard current != nil else { return }
        reviewingConflict = nil
        saveConflict = nil
        saveTask?.cancel()
        saveTask = nil
        setText(merged, keepingPosition: true)
        writeCurrentBuffer()
    }

    func resolveSaveConflict(_ resolution: SaveConflictResolution) {
        guard saveConflict != nil, let current else { return }
        switch resolution {
        case .keepMine:
            saveConflict = nil
            writeCurrentBuffer()
        case .useDisk:
            guard let fresh = try? String(contentsOf: current.url, encoding: .utf8) else {
                status = "The disk version of \(current.name) is no longer available"
                return
            }
            saveTask?.cancel()
            saveTask = nil
            setText(fresh)
            isDirty = false
            lastKnownDiskText = fresh
            lastKnownModification = modificationDate(of: current.url)
            saveConflict = nil
            status = "Loaded the disk version of \(current.relativePath)"
        case .cancel:
            saveConflict = nil
            status = "Save still paused for \(current.relativePath)"
        }
    }

    private func writeCurrentBuffer() {
        guard let current else { return }
        do {
            try text.write(to: current.url, atomically: true, encoding: .utf8)
            isDirty = false
            lastKnownDiskText = text
            lastKnownModification = modificationDate(of: current.url)
            saveConflict = nil
            status = "Saved \(current.relativePath)"
            reindexIfMetadataChanged(for: current)
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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

    /// True when the vault has no agent guidance yet, so the menu can say
    /// whether this would create the file or refresh it.
    var hasAgentGuide: Bool {
        guard let vaultRoot else { return false }
        let text = try? String(
            contentsOf: vaultRoot.appendingPathComponent("CLAUDE.md"), encoding: .utf8
        )
        return text?.contains(AgentGuide.markerStart) == true
    }

    /// What the open vault's `CLAUDE.md` carries, so the banner can offer a
    /// refresh rather than only a first-time setup.
    var agentGuideStatus: AgentGuide.Status {
        guard let vaultRoot else { return .absent }
        return AgentGuide.status(of: try? String(
            contentsOf: vaultRoot.appendingPathComponent("CLAUDE.md"), encoding: .utf8
        ))
    }

    private static let agentOfferDismissedKey = "dev.stenglein.Heft.agentOfferDismissed"

    /// Turning the offer down is remembered per vault *and per guide version*,
    /// so a vault that said no once is asked again when the instructions it
    /// would receive have actually changed — and not before.
    private static func offerKey(for vaultRoot: URL) -> String {
        "\(vaultRoot.standardizedFileURL.path)#\(AgentGuide.version)"
    }

    /// Whether to offer agent setup for the open vault.
    ///
    /// Opt-in only works if something actually asks. The menu item alone left
    /// the proposal flow invisible: open a folder, and a Claude Code session
    /// in it would reach for Write, which is the one thing proposals exist to
    /// prevent. So a vault without the guide says so once, and remembers being
    /// turned down.
    var shouldOfferAgentSetup: Bool {
        guard let vaultRoot, agentGuideStatus != .current else { return false }
        let dismissed = UserDefaults.standard.stringArray(
            forKey: Self.agentOfferDismissedKey
        ) ?? []
        return !dismissed.contains(Self.offerKey(for: vaultRoot))
    }

    /// Remembers that this vault was offered agent setup and turned down, so
    /// the banner is a one-time question rather than a recurring one.
    func dismissAgentSetupOffer() {
        guard let vaultRoot else { return }
        var dismissed = UserDefaults.standard.stringArray(
            forKey: Self.agentOfferDismissedKey
        ) ?? []
        let path = Self.offerKey(for: vaultRoot)
        guard !dismissed.contains(path) else { return }
        dismissed.append(path)
        UserDefaults.standard.set(dismissed, forKey: Self.agentOfferDismissedKey)
        objectWillChange.send()
    }

    /// Writes the vault's `CLAUDE.md` so an agent started in that folder knows
    /// to propose changes rather than write notes.
    ///
    /// Offered rather than done silently on open: this writes a file into
    /// somebody's vault, and a vault is not ours to add things to unasked.
    func setUpAgentAccess() {
        guard let vaultRoot else { promptForVault(); return }
        let target = vaultRoot.appendingPathComponent("CLAUDE.md")
        let existing = try? String(contentsOf: target, encoding: .utf8)

        let binary = Bundle.main.executablePath ?? "heft"
        let section = AgentGuide.section(binaryPath: binary)
        let saved = try? AgentGuide.backUpIfEdited(
            existing: existing, replacement: section, vaultRoot: vaultRoot
        )
        let merged = AgentGuide.merged(
            into: existing,
            section: section,
            preamble: AgentGuide.preamble(vaultName: vaultName)
        )
        do {
            try merged.write(to: target, atomically: true, encoding: .utf8)
            if let saved = saved ?? nil {
                status = "Updated CLAUDE.md; your edits inside it were saved to "
                    + saved.lastPathComponent
            } else {
                status = existing == nil
                    ? "Wrote CLAUDE.md: agents in this vault will propose changes"
                    : "Updated CLAUDE.md for agents"
            }
        } catch {
            status = "Could not write CLAUDE.md: \(error.localizedDescription)"
        }
    }

    /// Asks for a path and goes wherever it points.
    ///
    /// The system's own Go to Folder sheet is not ours to preprocess, and it
    /// takes a literal path, so a shell-escaped one pasted into a file panel
    /// simply fails to resolve. This is the entry point that accepts the forms
    /// a path is actually copied in; `PathInput` documents which and why.
    func promptToGoToPath() {
        guard let entered = FilePrompt.path(
            title: "Go to Path",
            message: "Paste a path to a note or folder. Escaped paths, quoted "
                + "paths and file:// URLs are all accepted."
        ) else { return }
        goToPath(entered)
    }

    /// Focuses a folder, opens a note, or offers to open a vault, depending on
    /// what the path turns out to be.
    @discardableResult
    func goToPath(_ raw: String) -> Bool {
        guard let normalized = PathInput.normalize(raw) else { return false }
        let url = URL(fileURLWithPath: normalized)

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            status = "There is nothing at \(normalized)"
            return false
        }

        // With no vault open, any folder is a candidate to become one.
        guard let vaultRoot else {
            guard isFolder.boolValue else {
                status = "Open a vault before opening a note"
                return false
            }
            openVault(at: url)
            return true
        }

        let rootPath = vaultRoot.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target == rootPath || target.hasPrefix(rootPath + "/") else {
            // Outside the vault entirely. A folder can become its own vault,
            // which is the same offer the scope picker makes.
            guard isFolder.boolValue else {
                status = "\(url.lastPathComponent) is outside \(vaultName)"
                return false
            }
            pendingOutsideVaultFolder = url
            return true
        }

        if target == rootPath {
            showEntireVault()
            return true
        }

        let relative = String(target.dropFirst(rootPath.count + 1))
        if isFolder.boolValue {
            guard let folder = tree?.flattened().first(where: {
                $0.isFolder && $0.relativePath == relative
            }) else {
                status = "That folder is not available in the vault yet"
                return false
            }
            setScope(to: folder)
            return true
        }

        guard let note = index.note(atRelativePath: relative) else {
            status = "That note is not in the vault index yet"
            return false
        }
        open(note)
        return true
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
            pendingOutsideVaultFolder = chosen
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
        externalChangePollTask?.cancel()
        externalChangePollTask = nil
        if !flushPendingSave() {
            preserveRecoveryCopy()
        }
        registry.releaseAll(for: workspaceID)
    }

    /// A SwiftUI window can disappear before an alert can resolve a save
    /// conflict. Preserve the local buffer as a plainly named markdown file so
    /// closing or quitting can never throw away the version the user typed.
    private func preserveRecoveryCopy() {
        guard isDirty, let current else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = "\(current.name) (Heft Recovery \(formatter.string(from: Date())))"

        let sibling = uniqueURL(
            in: current.url.deletingLastPathComponent(), base: base, extension: "md"
        )
        if (try? text.write(to: sibling, atomically: true, encoding: .utf8)) != nil {
            isDirty = false
            status = "Preserved unsaved edits in \(sibling.lastPathComponent)"
            return
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Heft/Recovery", isDirectory: true)
        guard let support else { return }
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true
            )
            let fallback = uniqueURL(in: support, base: base, extension: "md")
            try text.write(to: fallback, atomically: true, encoding: .utf8)
            isDirty = false
            status = "Preserved unsaved edits in \(fallback.path)"
        } catch {
            status = "Could not preserve unsaved edits: \(error.localizedDescription)"
        }
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

    // MARK: - Agent proposals

    /// Re-reads `.heft/proposals`. Cheap: a handful of small JSON files, and
    /// only when the vault reports a change or a review is acted on.
    func refreshProposals() {
        guard let vaultRoot else {
            proposals = []
            return
        }
        let found = ProposalStore.all(in: vaultRoot)
        guard found != proposals else { return }
        proposals = found
        if let reviewing, !found.contains(where: { $0.id == reviewing.id }) {
            self.reviewing = nil
        }
    }

    var proposalsForCurrentNote: [Proposal] {
        guard let current else { return [] }
        return proposals.filter { $0.notePath == current.relativePath }
    }

    /// The note a proposal is about, as it stands right now. The open buffer
    /// wins over the file: what the user is looking at is what they are
    /// deciding about, even if the autosave has not fired yet.
    func currentText(for proposal: Proposal) -> String {
        if let current, current.relativePath == proposal.notePath { return text }
        guard let vaultRoot else { return "" }
        return (try? String(
            contentsOf: vaultRoot.appendingPathComponent(proposal.notePath), encoding: .utf8
        )) ?? ""
    }

    func beginReview(of proposal: Proposal) {
        reviewing = proposal
    }

    /// Opens the note a proposal is about, then reviews it.
    func openAndReview(_ proposal: Proposal) {
        if current?.relativePath != proposal.notePath,
           let note = index.notes.first(where: { $0.relativePath == proposal.notePath }) {
            open(note)
        }
        reviewing = proposal
    }

    /// Accepts or rejects one hunk. Either way the proposal is rewritten to
    /// hold only what is still undecided, so a half-reviewed proposal is a
    /// smaller proposal rather than a lost one.
    func decide(_ proposal: Proposal, hunk: Int, accept: Bool) {
        guard let vaultRoot else { return }
        let before = currentText(for: proposal)
        do {
            let outcome = try ProposalStore.settle(
                proposal,
                currentText: before,
                accepted: accept ? [hunk] : [],
                rejected: accept ? [] : [hunk],
                in: vaultRoot
            )
            if accept { write(outcome.noteText, to: proposal.notePath) }
            reviewing = outcome.remaining
            refreshProposals()
            status = accept
                ? "Applied one change to \(proposal.noteName)"
                : "Rejected one change to \(proposal.noteName)"
        } catch {
            status = "Could not update the proposal: \(error.localizedDescription)"
        }
    }

    func acceptAll(_ proposal: Proposal) {
        guard let vaultRoot else { return }
        let before = currentText(for: proposal)
        write(proposal.body, to: proposal.notePath)
        ProposalStore.remove(proposal.id, in: vaultRoot)
        reviewing = nil
        refreshProposals()
        let diff = proposal.diff(against: before)
        status = "Applied \(diff.hunks.count) change(s) to \(proposal.noteName)"
    }

    func discard(_ proposal: Proposal) {
        guard let vaultRoot else { return }
        ProposalStore.remove(proposal.id, in: vaultRoot)
        reviewing = nil
        refreshProposals()
        status = "Discarded \(proposal.agent)'s proposal for \(proposal.noteName)"
    }

    /// Writes an accepted change. Through the open buffer when it is the note
    /// on screen, so the edit joins the normal autosave and undo path instead
    /// of racing it; straight to disk otherwise.
    private func write(_ new: String, to relativePath: String) {
        if let current, current.relativePath == relativePath {
            text = new
            documentGenerationKeepsPosition = true
            documentGeneration += 1
            save()
            return
        }
        guard let vaultRoot else { return }
        let url = vaultRoot.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try new.write(to: url, atomically: true, encoding: .utf8)
            reload(immediately: true)
        } catch {
            status = "Could not write \(relativePath): \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    static let heftInsertSnippet = Notification.Name("dev.stenglein.Heft.insertSnippet")
}
