import Foundation
import HeftCore

/// The vault as the app and its share extension both reach it.
///
/// The bookmark lives in an App Group because the extension is a process of
/// its own and cannot read the app's preferences. Whether iOS honours a
/// folder bookmark the app made when the extension resolves it is not
/// something the simulator can show, so a share that cannot reach the vault
/// is queued in the group container and filed by the app when it next runs.
enum SharedVault {
    static let group = "group.dev.stenglein.HeftMobile"
    static let bookmarkKey = "dev.stenglein.Heft.iOS.vaultBookmark"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: group) ?? HeftDefaults.shared
    }

    static func remember(_ bookmark: Data) {
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    /// The vault the reader picked. A caller that asks for access owns it and
    /// must stop it when done.
    ///
    /// Falls back to the app's own preferences, where builds before the share
    /// extension kept the bookmark, and moves it into the group from there.
    static func bookmarkedRoot(startAccessing: Bool) -> URL? {
        var data = defaults.data(forKey: bookmarkKey)
        if data == nil, let older = HeftDefaults.shared.data(forKey: bookmarkKey) {
            remember(older)
            data = older
        }
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        else { return nil }
        if startAccessing { _ = url.startAccessingSecurityScopedResource() }
        if stale, let fresh = try? url.bookmarkData() { remember(fresh) }
        return url
    }

    // MARK: Filing

    /// Where a capture or a share goes.
    enum Destination: Codable, Hashable {
        case today
        case inbox
        /// Appended as written, without the capture's time and heading.
        case note(String)
    }

    /// `date` is when the line was captured, which for a queued share can be
    /// a while before it is filed: it still belongs to that day's note.
    /// `inTimeOrder` files it among lines written since, by its time.
    static func file(_ text: String, to destination: Destination, in root: URL,
                     at date: Date = Date(), inTimeOrder: Bool = false) throws {
        switch destination {
        case .today:
            let settings = ObsidianSettings.load(vaultRoot: root)
            try DailyNoteCapture(vaultRoot: root, settings: settings)
                .capture(text, at: date, inTimeOrder: inTimeOrder)
        case .inbox:
            try InboxCapture(vaultRoot: root).capture(text, at: date, inTimeOrder: inTimeOrder)
        case .note(let path):
            try NoteAppend.append(text, to: path, in: root)
        }
    }

    /// Why the vault could not be reached, worded for the reader, so a
    /// failure on the phone says which of the three it was.
    enum Unreachable: LocalizedError {
        case noBookmark
        case unresolved(String)
        case denied

        var errorDescription: String? {
            switch self {
            case .noBookmark: "No vault is set up yet. Open Heft and choose one."
            case .unresolved(let reason): "The saved vault could not be opened (\(reason))."
            case .denied: "iOS did not let this extension read the vault folder."
            }
        }
    }

    /// The bookmarked vault with access held, or why not. The caller stops
    /// the access when done, and only when it was granted: a stop without
    /// its start can take away access the process holds otherwise.
    static func openBookmarkedRoot() throws -> (url: URL, granted: Bool) {
        guard let data = defaults.data(forKey: bookmarkKey)
                ?? HeftDefaults.shared.data(forKey: bookmarkKey)
        else { throw Unreachable.noBookmark }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        } catch {
            throw Unreachable.unresolved(error.localizedDescription)
        }
        let granted = url.startAccessingSecurityScopedResource()
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw Unreachable.denied
        }
        return (url, granted)
    }

    /// Files into the bookmarked vault, holding access for the one write.
    /// Returns the vault's name.
    @discardableResult
    static func fileIntoBookmarkedVault(_ text: String, to destination: Destination,
                                        at date: Date = Date()) throws -> String {
        let (root, granted) = try openBookmarkedRoot()
        defer { if granted { root.stopAccessingSecurityScopedResource() } }
        try file(text, to: destination, in: root, at: date)
        return root.lastPathComponent
    }

    // MARK: Note list

    /// A note as the app last saw it: what the share sheet offers, and what
    /// the app shows at launch before its first scan of this run lands.
    struct ListedNote: Codable, Identifiable, Hashable {
        var path: String
        var name: String
        var folder: String
        var modified: Date?
        var excerpt: String?
        var id: String { path }
    }

    private static var noteListURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Notes.json")
    }

    /// Written by the app after every scan, newest edit first, so the share
    /// sheet can search note names without reading the vault itself.
    static func publishNoteList(_ notes: [ListedNote]) {
        guard let url = noteListURL, let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func noteList() -> [ListedNote] {
        guard let url = noteListURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ListedNote].self, from: data)) ?? []
    }

    // MARK: Queue

    struct Pending: Codable {
        var text: String
        var destination: Destination
        var date: Date
    }

    private static var queueFolder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Pending", isDirectory: true)
    }

    static func enqueue(_ pending: Pending) throws {
        guard let folder = queueFolder else { throw InboxCaptureError.vaultUnavailable }
        try enqueue(pending, in: folder)
    }

    static func enqueue(_ pending: Pending, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pending)
        try data.write(to: folder.appendingPathComponent("\(UUID().uuidString).json"),
                       options: .atomic)
    }

    /// Files everything queued, oldest first, and removes each once written.
    /// One that fails stays queued for the next try. Returns how many landed.
    ///
    /// One drain at a time: every rescan drains, rescans overlap, and two
    /// drains listing the same queue would file each share twice.
    @discardableResult
    static func drainQueue(into root: URL) -> Int {
        guard let folder = queueFolder else { return 0 }
        return drainQueue(from: folder, into: root)
    }

    @discardableResult
    static func drainQueue(from folder: URL, into root: URL) -> Int {
        drainLock.withLock { drainLocked(from: folder, into: root) }
    }

    private static let drainLock = NSLock()

    private static func drainLocked(from folder: URL, into root: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: nil)
        else { return 0 }
        let decoder = JSONDecoder()
        let queued = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Pending)? in
                guard let data = try? Data(contentsOf: url),
                      let pending = try? decoder.decode(Pending.self, from: data)
                else { return nil }
                return (url, pending)
            }
            .sorted { $0.1.date < $1.1.date }
        var filed = 0
        for (url, pending) in queued {
            do {
                do {
                    try file(pending.text, to: pending.destination, in: root, at: pending.date,
                             inTimeOrder: true)
                } catch NoteAppend.Failure.missing(let path) where !awaitsDownload(path, in: root) {
                    // Renamed or deleted since it was shared. Queued, it was
                    // retried on every scan and never seen; the inbox is
                    // where a share with no other home goes.
                    try file(pending.text, to: .inbox, in: root, at: pending.date,
                             inTimeOrder: true)
                }
                try? FileManager.default.removeItem(at: url)
                filed += 1
            } catch {
                continue
            }
        }
        return filed
    }

    /// Whether iCloud holds the note but has not brought it down yet: the
    /// scan asks for it, so a share for it waits rather than moving.
    private static func awaitsDownload(_ path: String, in root: URL) -> Bool {
        let url = root.appendingPathComponent(path)
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }
}
