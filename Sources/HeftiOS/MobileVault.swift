import Foundation
import HeftCore
import Observation

/// The open vault on iOS: the folder, its tree and index, and its settings.
///
/// The phone cannot look the vault up the way the Mac does, because Obsidian's
/// iCloud container belongs to another app. The reader picks the folder once
/// in the Files picker, and what is kept is a bookmark to it: the path alone
/// would open nothing on the next launch, since the access the picker grants
/// lives in the bookmark.
@MainActor @Observable
final class MobileVault {
    private(set) var root: URL?
    private(set) var tree: VaultItem?
    private(set) var index: VaultIndex = .empty
    /// Every note, newest edit first, with its date and opening lines. Read
    /// from the last run's snapshot at launch, so the list is there at once,
    /// and replaced when this run's scan lands.
    private(set) var recent: [SharedVault.ListedNote] = []
    private(set) var pins = Pins()
    private(set) var settings = ObsidianSettings()
    /// The vault's colours, shared with the Mac through `.heft/appearance.json`.
    private(set) var appearance = AppearancePreferences()
    private(set) var isScanning = false
    /// Bumped whenever a scan lands, so an open note can re-read itself.
    private(set) var generation = 0
    var problem: String?

    private var accessed: URL?
    private var frecency: FrecencyStore?
    private var scanToken = 0
    /// How many more scans to run while iCloud is still downloading notes.
    private var downloadRetries = 0
    private var appearanceWrite: Task<Void, Never>?

    init() {
        #if DEBUG
        // Lets a simulator launch open a vault without the picker:
        // `SIMCTL_CHILD_HEFT_IOS_VAULT=<path> xcrun simctl launch …`.
        if let path = ProcessInfo.processInfo.environment["HEFT_IOS_VAULT"], !path.isEmpty {
            open(URL(fileURLWithPath: path), remember: false)
            return
        }
        #endif
        if let url = SharedVault.bookmarkedRoot(startAccessing: true) {
            accessed = url
            adopt(url)
        }
    }

    var name: String { root?.lastPathComponent ?? "Heft" }

    var dailyNotes: DailyNotes? {
        root.map { DailyNotes(vaultRoot: $0, settings: settings) }
    }

    /// Opens a folder the Files picker handed over.
    func choose(_ url: URL) {
        open(url, remember: true)
    }

    private func open(_ url: URL, remember: Bool) {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url.startAccessingSecurityScopedResource() ? url : nil
        // The bookmark has to be made while access is held, or it carries none.
        if remember {
            do {
                SharedVault.remember(try url.bookmarkData())
            } catch {
                problem = "Heft could not remember this folder: \(error.localizedDescription)"
            }
        }
        adopt(url)
    }

    private func adopt(_ url: URL) {
        root = url
        index = .empty
        // The last run's picture of the vault, until the scan says otherwise.
        recent = SharedVault.noteList()
        tree = recent.isEmpty ? nil : Self.provisionalTree(recent, root: url)
        pins = Pins.load(from: url)
        appearance = AppearancePreferences()
        frecency = FrecencyStore.notes(forVaultAt: url.path)
        downloadRetries = 3
        refresh()
    }

    /// Scans the folder again. There is no FSEvents on iOS, so this runs on
    /// launch, on returning to the foreground, on pull to refresh, and after
    /// anything Heft itself writes.
    func refresh() {
        guard let root else { return }
        scanToken += 1
        let token = scanToken
        let previous = index
        let known = Dictionary(recent.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        isScanning = true
        Task.detached(priority: .userInitiated) {
            // Shares the extension could not write itself land first, so the
            // scan below already sees them.
            SharedVault.drainQueue(into: root)
            let settings = ObsidianSettings.load(vaultRoot: root)
            let appearance = AppearancePreferences.load(fromVault: root)
            let tree = VaultScanner.scan(root: root)
            // iOS keeps iCloud files evicted far more readily than the Mac
            // does, so ask for every note that is not here yet. The index is
            // built from what is present now and rebuilt as the rest arrives.
            let pending = tree.flattened().filter { $0.needsDownload && $0.isMarkdown }
            for item in pending {
                try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
            }
            // Straight from the folder scan, before the index is built: the
            // share sheet only needs names, and opening Heft right before a
            // share should be enough for it to have them.
            // Dates and excerpts carry over from the last list until the
            // index has read the notes again.
            SharedVault.publishNoteList(tree.flattened()
                .filter(\.isMarkdown)
                .sorted { ($0.fingerprint?.modifiedNanoseconds ?? .min) > ($1.fingerprint?.modifiedNanoseconds ?? .min) }
                .map { item in
                    let note = NoteRef(item: item)
                    let old = known[note.relativePath]
                    return SharedVault.ListedNote(path: note.relativePath, name: note.name,
                                                  folder: note.folder, modified: old?.modified,
                                                  excerpt: old?.excerpt)
                })
            // The first build of a run starts from what the last one left on
            // disk, as the Mac does, so a launch reads only what changed.
            let base = previous.notes.isEmpty ? IndexCache.shared.load(vault: root) ?? previous : previous
            let index = VaultIndex.build(root: tree, reusing: base)
            if index.notesRead > 0 { IndexCache.shared.save(index, vault: root) }
            let listed = index.notesByLastEdit.map {
                SharedVault.ListedNote(path: $0.relativePath, name: $0.name, folder: $0.folder,
                                       modified: index.modificationDate(of: $0.relativePath),
                                       excerpt: index.excerpt(of: $0.relativePath))
            }
            SharedVault.publishNoteList(listed)
            let pins = Pins.load(from: root)
            await self.land(token: token, tree: tree, index: index, settings: settings,
                            appearance: appearance, listed: listed, pins: pins, pending: pending.count)
        }
    }

    private func land(token: Int, tree: VaultItem, index: VaultIndex, settings: ObsidianSettings,
                      appearance: AppearancePreferences?, listed: [SharedVault.ListedNote],
                      pins: Pins, pending: Int) {
        guard token == scanToken else { return }
        // Only what changed, so a rescan that found nothing new redraws nothing.
        if self.tree != tree { self.tree = tree }
        self.index = index
        if recent != listed { recent = listed }
        if self.pins != pins { self.pins = pins }
        self.settings = settings
        // Not while a change made here is still waiting to be written: the
        // file read by this scan is older than what is on screen.
        if appearanceWrite == nil, let appearance, self.appearance != appearance {
            self.appearance = appearance
        }
        isScanning = false
        generation += 1
        if pending > 0, downloadRetries > 0 {
            downloadRetries -= 1
            Task {
                try? await Task.sleep(for: .seconds(4))
                self.refresh()
            }
        }
    }

    func returnedToForeground() {
        downloadRetries = 3
        refresh()
    }

    // MARK: Notes

    /// Folders and notes from a saved list of note paths: enough to browse
    /// while the real scan runs. Folders holding no note are missing from it
    /// until then.
    static func provisionalTree(_ notes: [SharedVault.ListedNote], root: URL) -> VaultItem {
        final class Node {
            var folders: [String: Node] = [:]
            var notes: [SharedVault.ListedNote] = []
        }
        let top = Node()
        for note in notes {
            var node = top
            for part in note.folder.split(separator: "/").map(String.init) {
                if let next = node.folders[part] {
                    node = next
                } else {
                    let next = Node()
                    node.folders[part] = next
                    node = next
                }
            }
            node.notes.append(note)
        }
        func item(_ node: Node, path: String, name: String) -> VaultItem {
            let folders = node.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { key in
                    item(node.folders[key]!, path: path.isEmpty ? key : "\(path)/\(key)", name: key)
                }
            let files = node.notes
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map {
                    VaultItem(url: root.appendingPathComponent($0.path), relativePath: $0.path,
                              kind: .markdown, name: $0.name)
                }
            return VaultItem(url: path.isEmpty ? root : root.appendingPathComponent(path),
                             relativePath: path, kind: .folder, name: name,
                             children: folders + files)
        }
        return item(top, path: "", name: root.lastPathComponent)
    }

    func isPinned(_ path: String) -> Bool {
        pins.contains(Pins.Pin(.note, path))
    }

    /// Pins live in the vault, beside the Mac's, so the file is read again
    /// just before the change: a pin made on the Mac meanwhile is kept.
    func togglePin(_ path: String) {
        guard let root else { return }
        var current = Pins.load(from: root)
        current.toggle(Pins.Pin(.note, path))
        do {
            try current.save(to: root)
            pins = current
        } catch {
            problem = "Heft could not save the pin: \(error.localizedDescription)"
        }
    }

    var pinnedNotes: [SharedVault.ListedNote] {
        let byPath = Dictionary(recent.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return pins.values(of: .note).compactMap { byPath[$0] }
    }

    func folder(at path: String) -> VaultItem? {
        guard let tree else { return nil }
        if path.isEmpty { return tree }
        var node = tree
        for part in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.isFolder && $0.name == part })
            else { return nil }
            node = next
        }
        return node
    }

    /// The note at `path`, from the index when it is there, else from disk:
    /// a note just created or still downloading is not indexed yet.
    func note(at path: String) -> NoteRef? {
        if let known = index.note(atRelativePath: path) { return known }
        guard let root else { return nil }
        return NoteRef(url: root.appendingPathComponent(path), vaultRoot: root)
    }

    func recordOpen(_ note: NoteRef) {
        frecency?.record(note.relativePath)
    }

    func familiarity(_ note: NoteRef) -> Double {
        frecency?.score(note.relativePath) ?? 0
    }

    /// Reads through a file coordinator, which is also what makes iCloud
    /// fetch a note that is not on the phone yet.
    nonisolated static func read(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinated in
            result = Result { try String(contentsOf: coordinated, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Writes `text` over the note only if it still holds `original`.
    ///
    /// The phone's edit is the one most likely to be stale: the Mac autosaves,
    /// iCloud delivers that late, and silently replacing what the Mac wrote is
    /// the one outcome worse than not saving. A changed file is refused and
    /// the reader sees the newer text.
    nonisolated static func write(_ text: String, to url: URL, replacing original: String) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging,
                                       error: &coordinationError) { coordinated in
            result = Result {
                let current = try String(contentsOf: coordinated, encoding: .utf8)
                guard current == original else { throw MobileWriteError.changedElsewhere }
                try text.write(to: coordinated, atomically: true, encoding: .utf8)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Writes `text` whatever the file holds now: what the reader chose when
    /// told the note had changed on another device.
    nonisolated static func overwrite(_ text: String, at url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { coordinated in
            result = Result { try text.write(to: coordinated, atomically: true, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Where New Note starts when it is not made inside a folder: the vault's
    /// own Obsidian setting, which syncs, rather than the Mac's preference,
    /// which stays on the Mac. With no note open, "beside the open note" is
    /// the root.
    var newNoteFolder: String {
        settings.newNoteLocation.directory(openNoteFolder: nil, focus: nil)
    }

    /// Every folder, vault-relative and in sidebar order, for choosing where
    /// a note goes. The configured folder is offered even before it exists.
    var folderPaths: [String] {
        var paths = [""]
        func walk(_ item: VaultItem) {
            for child in item.children where child.isFolder {
                paths.append(child.relativePath)
                walk(child)
            }
        }
        if let tree { walk(tree) }
        if !paths.contains(newNoteFolder) { paths.append(newNoteFolder) }
        return paths
    }

    /// Makes an empty note called `name` in `folder` and answers its path.
    ///
    /// A name already taken opens that note instead, as on the Mac: the name
    /// is the title links use, so a numbered copy would be a second note
    /// nobody meant. Only an existing folder or the configured one is used;
    /// the latter is created, since naming it was asking for notes to go there.
    func createNote(named name: String, in folder: String) throws -> (path: String, existed: Bool) {
        guard let root else { throw DailyNoteCaptureError.vaultUnavailable }
        var stem = VaultOperations.sanitise(name)
        if stem.lowercased().hasSuffix(".md") { stem = String(stem.dropLast(3)) }
        guard !stem.isEmpty, !stem.contains("/"), stem != ".", stem != ".." else {
            throw NoteCreation.Failure.unusableName(name)
        }
        let folder = NewNoteLocation.normalised(folder)
        let directory = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        let prefix = folder.isEmpty ? "" : folder + "/"
        // By listing rather than `fileExists`, which takes "groceries" for a
        // new name beside `Groceries.md`; the write below would then refuse.
        let taken = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if let existing = taken.first(where: { $0.caseInsensitiveCompare(stem + ".md") == .orderedSame }) {
            return (prefix + existing, true)
        }
        let url = directory.appendingPathComponent(stem + ".md")
        let path = prefix + stem + ".md"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try Data().write(to: coordinated, options: .withoutOverwriting) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        frecency?.record(path)
        refresh()
        return (path, false)
    }

    /// Makes an empty folder called `name` inside `parent`.
    func createFolder(named name: String, in parent: String) throws {
        guard let root else { throw DailyNoteCaptureError.vaultUnavailable }
        let stem = VaultOperations.sanitise(name)
        guard !stem.isEmpty, !stem.contains("/"), !stem.hasPrefix(".") else {
            throw MobileFolderError.unusableName(name)
        }
        let parent = NewNoteLocation.normalised(parent)
        let directory = parent.isEmpty ? root : root.appendingPathComponent(parent, isDirectory: true)
        let taken = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard !taken.contains(where: { $0.caseInsensitiveCompare(stem) == .orderedSame }) else {
            throw MobileFolderError.taken(stem)
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(stem, isDirectory: true),
            withIntermediateDirectories: false
        )
        refresh()
    }

    /// Shows the colours at once and writes the vault's file a moment after
    /// the last change, since a colour picker reports every step of a drag.
    func setAppearance(_ preferences: AppearancePreferences) {
        guard preferences != appearance, let root else { return }
        appearance = preferences
        appearanceWrite?.cancel()
        appearanceWrite = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try preferences.save(toVault: root)
            } catch {
                problem = "Heft could not save the colours: \(error.localizedDescription)"
            }
            appearanceWrite = nil
        }
    }

    /// Today's note, made from the daily template when it does not exist.
    /// `ensureNote` never overwrites, so tapping a day twice is harmless.
    func dailyNote(for date: Date) throws -> NoteRef {
        guard let dailyNotes, let root else { throw DailyNoteCaptureError.vaultUnavailable }
        let url = try dailyNotes.ensureNote(for: date)
        refresh()
        guard let note = NoteRef(url: url, vaultRoot: root) else {
            throw DailyNoteCaptureError.vaultUnavailable
        }
        return note
    }
}

enum MobileFolderError: LocalizedError {
    case unusableName(String)
    case taken(String)

    var errorDescription: String? {
        switch self {
        case .unusableName(let name): "\(name) is not a name a folder can have."
        case .taken(let name): "There is already something called \(name) here."
        }
    }
}

enum MobileWriteError: LocalizedError {
    case changedElsewhere

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This note changed on another device while you were editing. Heft kept that version; your edit is still in the editor."
        }
    }
}
