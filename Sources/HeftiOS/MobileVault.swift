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
    private(set) var settings = ObsidianSettings()
    private(set) var isScanning = false
    /// Bumped whenever a scan lands, so an open note can re-read itself.
    private(set) var generation = 0
    var problem: String?

    private var accessed: URL?
    private var frecency: FrecencyStore?
    private var scanToken = 0
    /// How many more scans to run while iCloud is still downloading notes.
    private var downloadRetries = 0

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
        tree = nil
        index = .empty
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
        isScanning = true
        Task.detached(priority: .userInitiated) {
            // Shares the extension could not write itself land first, so the
            // scan below already sees them.
            SharedVault.drainQueue(into: root)
            let settings = ObsidianSettings.load(vaultRoot: root)
            let tree = VaultScanner.scan(root: root)
            // iOS keeps iCloud files evicted far more readily than the Mac
            // does, so ask for every note that is not here yet. The index is
            // built from what is present now and rebuilt as the rest arrives.
            let pending = tree.flattened().filter { $0.needsDownload && $0.isMarkdown }
            for item in pending {
                try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
            }
            let index = VaultIndex.build(root: tree, reusing: previous)
            SharedVault.publishNoteList(index.notesByLastEdit.map {
                SharedVault.ListedNote(path: $0.relativePath, name: $0.name, folder: $0.folder)
            })
            await self.land(token: token, tree: tree, index: index, settings: settings,
                            pending: pending.count)
        }
    }

    private func land(token: Int, tree: VaultItem, index: VaultIndex, settings: ObsidianSettings,
                      pending: Int) {
        guard token == scanToken else { return }
        self.tree = tree
        self.index = index
        self.settings = settings
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

enum MobileWriteError: LocalizedError {
    case changedElsewhere

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This note changed on another device while you were editing. Heft kept that version; your edit is still in the editor."
        }
    }
}
