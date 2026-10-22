import CryptoKit
import Foundation
import HeftCore
import Observation
import WidgetKit

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
    /// Between choosing a folder and the vault being open: making the
    /// bookmark to an iCloud folder can take a moment.
    private(set) var isOpening = false
    /// What a long first scan is doing, for the line under the list; nil
    /// for an ordinary rescan, which is quick and says nothing.
    private(set) var status: String?
    /// Set when a vault is adopted, until its first scan has landed.
    private var firstScan = false
    /// Bumped whenever a scan lands, so an open note can re-read itself.
    private(set) var generation = 0
    var problem: String?
    /// What the last rename or move repointed, to tell the reader once.
    var lastSummary: String?

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
            open(URL(fileURLWithPath: path))
            return
        }
        // `HEFT_IOS_CHOOSE=<path>` takes a folder as the Files picker hands
        // one over, bookmark and all, for a later launch to reopen.
        if let path = ProcessInfo.processInfo.environment["HEFT_IOS_CHOOSE"], !path.isEmpty {
            choose(URL(fileURLWithPath: path))
            return
        }
        #endif
        if let url = SharedVault.bookmarkedRoot(startAccessing: false) {
            // Kept only when granted, so the stop on choosing another
            // folder balances a start that happened.
            accessed = url.startAccessingSecurityScopedResource() ? url : nil
            adopt(url)
        }
    }

    var name: String { root?.lastPathComponent ?? "Heft" }

    /// The open vault, for intents and their entity queries, which run
    /// outside any view. Set with `root`.
    nonisolated(unsafe) static var currentRoot: URL?
    private var donation: Task<Void, Never>?

    /// Today's note for the widget, which cannot read the vault itself.
    /// Written and the widget reloaded only when something it shows changed.
    private func publishToday() {
        guard let dailyNotes else { return }
        let day = Calendar.current.startOfDay(for: Date())
        let path = dailyNotes.relativePath(for: day)
        let url = note(at: path)?.url
        let title = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        Task.detached(priority: .utility) {
            let text = url.flatMap { try? MobileVault.read($0) }
            // What comes just before where a capture goes: above the last
            // marker when the template has one, else the end of the note.
            let written = text.map { text -> String in
                guard let marker = text.range(of: DailyNoteCapture.insertionMarker, options: .backwards)
                else { return text }
                return String(text[..<marker.lowerBound])
            }
            let snapshot = TodaySnapshot(
                day: day, title: title, exists: text != nil,
                lines: written.map { TodaySnapshot.lines(from: $0, latest: true) } ?? [],
                opening: text.map { TodaySnapshot.lines(from: $0) } ?? []
            )
            guard snapshot != TodaySnapshot.load() else { return }
            snapshot.save()
            WidgetCenter.shared.reloadTimelines(ofKind: TodaySnapshot.widgetKind)
        }
    }

    /// Tells Spotlight about the vault's notes, so a search there finds one
    /// and a tap on it opens it through `MobileOpenNoteIntent`. Coalesced,
    /// since iCloud delivers a vault in bursts of rescans.
    private func donateToSpotlight() {
        guard let root else { return }
        let notes = index.notes, index = index
        donation?.cancel()
        donation = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await NoteIndexing.donate(notes, in: root, vaultIndex: index)
        }
    }

    var dailyNotes: DailyNotes? {
        root.map { DailyNotes(vaultRoot: $0, settings: settings) }
    }

    /// Opens a folder the Files picker handed over. The bookmark is made
    /// off the main thread: for a folder in iCloud that took long enough
    /// that choosing one looked like nothing had happened.
    func choose(_ url: URL) {
        isOpening = true
        problem = nil
        accessed?.stopAccessingSecurityScopedResource()
        let granted = url.startAccessingSecurityScopedResource()
        Task {
            let bookmark = await Task.detached { Result { try url.bookmarkData() } }.value
            switch bookmark {
            case .success(let data): SharedVault.remember(data)
            case .failure(let error): problem = "Heft could not remember this folder: \(error.localizedDescription)"
            }
            accessed = granted ? url : nil
            adopt(url)
            isOpening = false
        }
    }

    /// A folder opened for this run only, as the debug launch does.
    private func open(_ url: URL) {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url.startAccessingSecurityScopedResource() ? url : nil
        adopt(url)
    }

    private func adopt(_ url: URL) {
        root = url
        Self.currentRoot = url
        index = .empty
        // The last run's picture of the vault, until the scan says otherwise.
        recent = SharedVault.noteList()
        tree = recent.isEmpty ? nil : Self.provisionalTree(recent, root: url)
        pins = Pins.load(from: url)
        appearance = AppearancePreferences()
        loadOpenings()
        firstScan = true
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
            // index has read the notes again; a note never listed before
            // takes its file's date.
            let quick = tree.flattened()
                .filter(\.isMarkdown)
                .sorted { ($0.fingerprint?.modifiedNanoseconds ?? .min) > ($1.fingerprint?.modifiedNanoseconds ?? .min) }
                .map { item in
                    let note = NoteRef(item: item)
                    let old = known[note.relativePath]
                    let fileDate = item.fingerprint.map {
                        Date(timeIntervalSince1970: Double($0.modifiedNanoseconds) / 1_000_000_000)
                    }
                    return SharedVault.ListedNote(path: note.relativePath, name: note.name,
                                                  folder: note.folder, modified: old?.modified ?? fileDate,
                                                  excerpt: old?.excerpt)
                }
            SharedVault.publishNoteList(quick)
            // A vault opened for the first time shows its notes now, rather
            // than once every one of them has been read.
            await self.preview(token: token, tree: tree, listed: quick, pending: pending.count)
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

    private func preview(token: Int, tree: VaultItem, listed: [SharedVault.ListedNote], pending: Int) {
        guard token == scanToken else { return }
        if self.tree == nil || recent.isEmpty {
            self.tree = tree
            recent = listed
        }
        if pending > 0 {
            status = "Downloading \(pending) note\(pending == 1 ? "" : "s") from iCloud…"
        } else if firstScan {
            status = "Reading \(listed.count) notes…"
        }
    }

    private func land(token: Int, tree: VaultItem, index: VaultIndex, settings: ObsidianSettings,
                      appearance: AppearancePreferences?, listed: [SharedVault.ListedNote],
                      pins: Pins, pending: Int) {
        guard token == scanToken else { return }
        // Only what changed, so a rescan that found nothing new redraws nothing.
        let treeChanged = self.tree != tree
        if treeChanged { self.tree = tree }
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
        firstScan = false
        status = pending > 0 && downloadRetries > 0
            ? "Downloading \(pending) note\(pending == 1 ? "" : "s") from iCloud…" : nil
        generation += 1
        if treeChanged || generation == 1 { donateToSpotlight() }
        publishToday()
        #if DEBUG
        runLaunchOperation()
        #endif
        if pending > 0, downloadRetries > 0 {
            downloadRetries -= 1
            Task {
                try? await Task.sleep(for: .seconds(4))
                self.refresh()
            }
        }
    }

    /// Not while a scan is running: at launch the app becomes active just
    /// after `init` has started one, and a second full scan of a cold vault
    /// doubled the wait for the first list.
    func returnedToForeground() {
        downloadRetries = 3
        guard !isScanning else { return }
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

    func isPinned(_ path: String) -> Bool { isPinned(Pins.Pin(.note, path)) }

    /// A note, folder, tag or command, as the Mac's bar pins them.
    func isPinned(_ pin: Pins.Pin) -> Bool { pins.contains(pin) }

    func togglePin(_ path: String) { togglePin(Pins.Pin(.note, path)) }

    /// Pins live in the vault, beside the Mac's, so the file is read again
    /// just before the change: a pin made on the Mac meanwhile is kept.
    func togglePin(_ pin: Pins.Pin) {
        guard let root else { return }
        var current = Pins.load(from: root)
        current.toggle(pin)
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

    /// When each note was last opened on this device, for Recent ordered by
    /// Last Opened. Kept here, as the Mac keeps its own: opening a note leaves
    /// nothing in the files to sync.
    private(set) var openedAt: [String: Date] = [:]

    private var openedKey: String? {
        root.map { "dev.stenglein.Heft.iOS.openedAt.\($0.path)" }
    }

    private func loadOpenings() {
        let stored = openedKey.flatMap { HeftDefaults.shared.dictionary(forKey: $0) as? [String: Double] } ?? [:]
        openedAt = stored.mapValues(Date.init(timeIntervalSince1970:))
    }

    func recordOpen(_ note: NoteRef) {
        frecency?.record(note.relativePath)
        openedAt[note.relativePath] = Date()
        // A bound, as the Mac's list of 100 has: the oldest drop off.
        if openedAt.count > 200 {
            for (path, _) in openedAt.sorted(by: { $0.value < $1.value }).prefix(openedAt.count - 200) {
                openedAt[path] = nil
            }
        }
        if let openedKey {
            HeftDefaults.shared.set(openedAt.mapValues(\.timeIntervalSince1970), forKey: openedKey)
        }
    }

    func familiarity(_ note: NoteRef) -> Double {
        frecency?.score(note.relativePath) ?? 0
    }

    /// Reads through a file coordinator, which is also what makes iCloud
    /// fetch a note that is not on the phone yet.
    nonisolated static func read(_ url: URL) throws -> String {
        try NoteFile.read(url)
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

    #if DEBUG
    private var launchOperationRan = false

    /// `HEFT_IOS_RUN=rename:<path>:<name>`, `move:<path>:<folder>` or
    /// `delete:<path>`, once the first scan has an index to repoint with.
    private func runLaunchOperation() {
        guard !launchOperationRan, !index.notes.isEmpty,
              let request = ProcessInfo.processInfo.environment["HEFT_IOS_RUN"]
        else { return }
        launchOperationRan = true
        let parts = request.split(separator: ":", maxSplits: 2).map(String.init)
        do {
            switch (parts.first, parts.count) {
            case ("rename", 3): _ = try rename(parts[1], to: parts[2])
            case ("move", 3): _ = try move(parts[1], into: parts[2])
            case ("move", 2): _ = try move(parts[1], into: "")
            case ("delete", 2): try delete(parts[1])
            case ("duplicate", 2): _ = try duplicate(parts[1])
            default: problem = "Unknown HEFT_IOS_RUN: \(request)"
            }
        } catch {
            problem = error.localizedDescription
        }
    }
    #endif

    // MARK: Attachments

    /// Where a file attached to `noteURL` goes: the Mac's standard plan, so
    /// a photo taken on the phone lands beside the ones pasted on the Mac.
    private func attachmentDirectory(for noteURL: URL, in root: URL) throws -> URL {
        let folder = AttachmentDestination.folder(of: noteURL, in: root)
        let chosen = AttachmentDestination(
            rules: AttachmentPlan.standard.rules, vaultRoot: root, settings: settings
        ).resolve(noteURL: noteURL, learned: index.attachmentDestination(near: folder))
        guard !chosen.folder.isEmpty else { return root }
        let url = root.appendingPathComponent(chosen.folder, isDirectory: true)
        if chosen.needsCreating {
            guard chosen.rule.mayCreate else { return root }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Saves a picture for the note at `notePath` and answers the embed to
    /// write. Named as the Mac names a pasted one, with a short hash of the
    /// bytes, so saving the same picture twice keeps one file.
    func attachImage(_ data: Data, extension ext: String, to notePath: String) throws -> String {
        guard let root, let note = note(at: notePath) else { throw MobileVaultActionError.missing }
        let directory = try attachmentDirectory(for: note.url, in: root)
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = "Pasted image " + MomentFormat.format(Date(), pattern: "YYYYMMDDHHmmss")
        let target = directory.appendingPathComponent("\(stem) \(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: target.path) {
            try Self.writeNew(data, to: target)
        }
        refresh()
        return AttachmentDestination.link(to: target, from: note.url, vaultRoot: root, settings: settings)
    }

    /// Copies a file in under its own name, `Name copy` when that is taken.
    func attachFile(at source: URL, to notePath: String) throws -> String {
        guard let root, let note = note(at: notePath) else { throw MobileVaultActionError.missing }
        let directory = try attachmentDirectory(for: note.url, in: root)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let taken = { (name: String) in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        let name = taken(source.lastPathComponent)
            ? VaultOperations.uniqueName(base: stem + " copy", extension: ext, isTaken: taken)
            : source.lastPathComponent
        let target = directory.appendingPathComponent(name)
        try Self.writeNew(try Data(contentsOf: source), to: target)
        refresh()
        return AttachmentDestination.link(to: target, from: note.url, vaultRoot: root, settings: settings)
    }

    private nonisolated static func writeNew(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try data.write(to: coordinated, options: .withoutOverwriting) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    // MARK: Renaming, moving, deleting

    /// The file or folder at a vault-relative path, from the last scan.
    func item(at path: String) -> VaultItem? {
        guard let tree else { return nil }
        if path.isEmpty { return tree }
        return tree.flattened().first { $0.relativePath == path }
    }

    /// Renames a note or folder in place and answers its new path. Links to
    /// it, or to anything inside it, are repointed as on the Mac.
    func rename(_ path: String, to typed: String) throws -> String {
        guard let item = item(at: path) else { throw MobileVaultActionError.missing }
        // A name somebody typed, where a slash is part of it, a date most
        // often. `planRename` reads one as a path from the vault's root, the
        // command line's spelling of a move: `Meeting 10/20` made a folder,
        // and `../` left the vault.
        let name = VaultOperations.sanitise(typed)
        let plan = VaultOperations.planRename(item, to: name) { [root] candidate in
            guard let root else { return false }
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path)
        }
        switch plan {
        case .success(let move):
            return try perform(move, of: item)
        case .failure(.alreadyExists) where Self.differsOnlyInCase(item, name):
            // "groceries" for `Groceries.md`: the file system calls that the
            // same name, and links already find it either way.
            return try changeCase(of: item, to: name)
        case .failure(let refusal):
            throw MobileVaultActionError.refused(refusal)
        }
    }

    /// Moves a note or folder into `folder` and answers its new path.
    func move(_ path: String, into folder: String) throws -> String {
        guard let item = item(at: path) else { throw MobileVaultActionError.missing }
        let plan = VaultOperations.planMove(path, into: folder, isFolder: item.isFolder) { [root] candidate in
            guard let root else { return false }
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path)
        }
        switch plan {
        case .success(let move): return try perform(move, of: item)
        case .failure(let refusal): throw MobileVaultActionError.refused(refusal)
        }
    }

    private func perform(_ move: VaultOperations.Move, of item: VaultItem) throws -> String {
        guard let root else { throw DailyNoteCaptureError.vaultUnavailable }
        guard move.from != move.to else { return move.to }
        // Links are found through the index; one still being built would
        // find none, and the move would leave them pointing at nothing.
        if index.notes.isEmpty, isScanning {
            throw MobileVaultActionError.refused(.stillLoading(name: item.name))
        }
        let summary = try VaultRename.perform(item: item, to: move.to, index: index, vaultRoot: root)
        followMove(from: move.from, to: move.to, isFolder: item.isFolder)
        lastSummary = summary.notes > 0 ? VaultOperations.repointSummary(summary) : nil
        refresh()
        return move.to
    }

    private static func differsOnlyInCase(_ item: VaultItem, _ name: String) -> Bool {
        guard let destination = VaultOperations.destination(for: item, named: name) else { return false }
        return destination != item.relativePath
            && destination.lowercased() == item.relativePath.lowercased()
    }

    /// Through a temporary name, since a direct move to a name that differs
    /// only in case is a move onto itself.
    private func changeCase(of item: VaultItem, to name: String) throws -> String {
        guard let root, let destination = VaultOperations.destination(for: item, named: name) else {
            throw MobileVaultActionError.missing
        }
        let target = root.appendingPathComponent(destination)
        let step = item.url.deletingLastPathComponent()
            .appendingPathComponent(".heft-rename-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: item.url, to: step)
        try FileManager.default.moveItem(at: step, to: target)
        followMove(from: item.relativePath, to: destination, isFolder: item.isFolder)
        refresh()
        return destination
    }

    /// Pins and the ranking follow a note to where it went.
    private func followMove(from old: String, to new: String, isFolder: Bool) {
        guard let root else { return }
        var current = Pins.load(from: root)
        let before = current
        current.move(isFolder ? .folder : .note, from: old, to: new)
        if current != before {
            try? current.save(to: root)
            pins = current
        }
        if !isFolder { frecency?.move(old, to: new) }
    }

    /// A copy beside the original, `Name copy` as on the Mac.
    func duplicate(_ path: String) throws -> String {
        guard let root, let item = item(at: path) else { throw MobileVaultActionError.missing }
        let parent = (path as NSString).deletingLastPathComponent
        let plan = VaultOperations.planCopy(path, into: parent, isFolder: item.isFolder) { candidate in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path)
        }
        switch plan {
        case .success(let copy):
            try FileManager.default.copyItem(at: item.url, to: root.appendingPathComponent(copy.to))
            refresh()
            return copy.to
        case .failure(let refusal):
            throw MobileVaultActionError.refused(refusal)
        }
    }

    /// Moves a note or folder to the Trash: the Files app's Recently
    /// Deleted when iOS allows it for this folder, else the vault's own
    /// `.trash`, which is where Obsidian keeps what it deletes.
    func delete(_ path: String) throws {
        guard let root, let item = item(at: path) else { throw MobileVaultActionError.missing }
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: item.url, options: .forDeleting,
                                       error: &coordinationError) { url in
            result = Result {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    let trash = root.appendingPathComponent(".trash", isDirectory: true)
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    let name = VaultOperations.uniqueName(
                        base: url.deletingPathExtension().lastPathComponent,
                        extension: item.isFolder ? "" : (item.url.pathExtension)
                    ) { FileManager.default.fileExists(atPath: trash.appendingPathComponent($0).path) }
                    try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(name))
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        var current = Pins.load(from: root)
        let pin = Pins.Pin(item.isFolder ? .folder : .note, path)
        if current.contains(pin) {
            _ = current.toggle(pin)
            try? current.save(to: root)
            pins = current
        }
        refresh()
    }

    /// The day a daily note is for, found by writing nearby dates in the
    /// vault's own format: the format has no parser, and a note handed over
    /// from the Mac is about a day within a year or two of today.
    func dailyDate(of path: String) -> Date? {
        guard let dailyNotes else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for distance in 0...730 {
            for sign in distance == 0 ? [1] : [1, -1] {
                guard let day = calendar.date(byAdding: .day, value: sign * distance, to: today) else { continue }
                if dailyNotes.relativePath(for: day) == path { return day }
            }
        }
        return nil
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

enum MobileVaultActionError: LocalizedError {
    case missing
    case refused(VaultOperations.Refusal)

    var errorDescription: String? {
        switch self {
        case .missing: "It is no longer in the vault."
        case .refused(let refusal): refusal.message
        }
    }
}

extension MobileVault: NoteSyncVault {
    func noteURL(at path: String) -> URL? { note(at: path)?.url }
    func noteWritten() { refresh() }
}
