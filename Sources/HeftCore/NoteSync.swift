import Foundation
import Observation

/// The vault a `NoteSync` saves into, as the iOS app's vault provides it.
@MainActor
public protocol NoteSyncVault: AnyObject {
    /// The vault's folder, which drafts are kept against.
    var root: URL? { get }
    /// Where the note at a vault-relative path is now.
    func noteURL(at path: String) -> URL?
    /// Called after each write, for the vault to see the change.
    func noteWritten()
}

/// One note's text on its way between an editor and its file: loading,
/// saving a moment after typing stops, and refusing to write over a file
/// that changed meanwhile. The iOS editor's `NoteDocument` holds one; it
/// lives here, apart from UIKit, so its ordering can be tested.
///
/// A save only lands on the text it was based on: the Mac autosaves,
/// iCloud brings that late, and quietly replacing what the Mac wrote is the
/// one outcome worse than not saving. A refused save becomes a `conflict`
/// for the reader to settle.
///
/// Typing that cannot reach its note, refused or failed, is mirrored to a
/// `DraftStore` draft as the Mac does: otherwise leaving the note, or iOS
/// ending the app in the background, lost it. A draft left over when the
/// note is next opened becomes a recovery note beside it.
@MainActor @Observable
public final class NoteSync {
    /// How the note's file is read and written; tests hold a read or a
    /// write back to see what overtakes it.
    public struct Storage: Sendable {
        public var read: @Sendable (URL) async throws -> String
        /// Writes the text only if the file still holds `original`.
        public var write: @Sendable (_ text: String, _ url: URL, _ original: String) async throws -> Void
        /// Writes the text whatever the file holds.
        public var overwrite: @Sendable (_ text: String, _ url: URL) async throws -> Void

        public init(
            read: @escaping @Sendable (URL) async throws -> String,
            write: @escaping @Sendable (_ text: String, _ url: URL, _ original: String) async throws -> Void,
            overwrite: @escaping @Sendable (_ text: String, _ url: URL) async throws -> Void
        ) {
            self.read = read
            self.write = write
            self.overwrite = overwrite
        }

        /// The file through a file coordinator, off the main actor.
        public static let coordinated = Storage(
            read: { url in try await Task.detached { try NoteFile.read(url) }.value },
            write: { text, url, original in
                try await Task.detached { try NoteFile.write(text, to: url, replacing: original) }.value
            },
            overwrite: { text, url in
                try await Task.detached { try NoteFile.overwrite(text, at: url) }.value
            }
        )
    }

    public let path: String
    /// The text as last read or saved.
    public private(set) var source: String?
    /// Moves only when `source` is replaced from disk, which is the one time
    /// the editor takes the text back rather than keeping its own.
    public private(set) var revision = 0
    public private(set) var failure: String?
    public private(set) var conflict = false
    public var saveError: String?

    /// What is on disk as far as this document knows; a save checks it.
    @ObservationIgnored private var onDisk: String?
    /// The version on disk the conflict was raised against, which Keep
    /// Mine decides against; nil when the note was gone or unreadable.
    @ObservationIgnored private var shown: String?
    /// Typed and not yet saved. Not observed: a keystroke changes nothing
    /// that any view draws.
    @ObservationIgnored private var pending: String?
    /// What the editor held when `revision` last moved, which a keystroke
    /// made before the editor took the new text was typed into.
    @ObservationIgnored private var replaced: String?
    /// Typing Use Theirs dropped, still on screen until the editor takes
    /// theirs.
    @ObservationIgnored private var dropped: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Reads begun and the latest one taken, so reads finishing out of
    /// order keep the newest.
    @ObservationIgnored private var loadsStarted = 0
    @ObservationIgnored private var loadLanded = 0
    /// The last save started, which the next one waits for.
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private weak var vault: (any NoteSyncVault)?
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let saveDelay: Duration
    /// Whether a draft from an earlier document has been looked for.
    @ObservationIgnored private var draftChecked = false

    public init(path: String, storage: Storage = .coordinated, saveDelay: Duration = .seconds(1)) {
        self.path = path
        self.storage = storage
        self.saveDelay = saveDelay
    }

    /// Whether typing is waiting to be written.
    public var hasUnsavedText: Bool { pending != nil }

    public func load(in vault: any NoteSyncVault) async {
        self.vault = vault
        // Unsaved typing wins until it is saved; a rescan arriving meanwhile
        // must not put the old text back under the caret.
        guard pending == nil else { return }
        guard let url = vault.noteURL(at: path) else {
            failure = "The note is no longer in the vault."
            return
        }
        if !draftChecked {
            draftChecked = true
            await recoverDraft(beside: url)
        }
        loadsStarted += 1
        let load = loadsStarted
        do {
            let text = try await storage.read(url)
            // Asked again after the read, which can wait on iCloud for
            // seconds: typing that began meanwhile is based on the old text,
            // and taking this as the base would let its save replace the
            // newer file unasked. Nor does a read that a later one overtook
            // put its older text back.
            guard pending == nil, load > loadLanded else { return }
            loadLanded = load
            onDisk = text
            failure = nil
            if text != source {
                replaced = dropped ?? source
                source = text
                revision += 1
            }
            dropped = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// `revision` is the one the editor last took, when it says.
    public func edited(_ text: String, at revision: Int? = nil) {
        defer { saveSoon() }
        // The editor takes a new text on its next update, and a keystroke
        // can come first, typed into the text that was replaced. Taken as
        // it is, it put that text back, and its save dropped what the
        // reload or merge brought in. Only the keystroke is carried over.
        guard let revision, revision != self.revision, let replaced, let source else {
            pending = text
            return
        }
        self.revision += 1
        self.replaced = text
        if let carried = NoteMerge.merge(base: replaced, mine: text, theirs: source) {
            self.source = carried
            pending = carried
        } else {
            // The keystroke is on lines the new text changed: the typing
            // stays on screen and the reader decides.
            self.source = text
            pending = text
            shown = onDisk
            conflict = true
        }
    }

    public func saveSoon(immediately: Bool = false) {
        guard pending != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [saveDelay] in
            if !immediately {
                try? await Task.sleep(for: saveDelay)
                guard !Task.isCancelled else { return }
            }
            await save()
        }
    }

    /// Whatever was typed, written before the file is renamed or moved.
    public func saveNow() async {
        saveTask?.cancel()
        await save()
    }

    /// Typing that will never be written: the note is being deleted.
    public func abandon() {
        saveTask?.cancel()
        pending = nil
        discardDraft()
    }

    /// One write at a time. A second started while the first is on disk
    /// still holds the first's base, finds the first's text in the file and
    /// calls that a change from elsewhere: leaving the app asks for a save
    /// on inactive and again on background, two saves that can overlap.
    private func save() async {
        let previous = writing
        let current = Task { await previous?.value; await write() }
        writing = current
        await current.value
    }

    private func write() async {
        guard let vault, let text = pending, let base = onDisk,
              let url = vault.noteURL(at: path)
        else { return }
        // Saving waits for the reader; the draft keeps up with the typing.
        guard !conflict else { return recordDraft() }
        var written = text
        var original = base
        do {
            var attempts = 0
            while true {
                do {
                    try await storage.write(written, url, original)
                    break
                } catch NoteWriteError.changedElsewhere {
                    // Changed since it was read, which is usually a capture
                    // filed into the note being typed in. Changes on other
                    // lines are merged and written, compared against what
                    // the merge read, so one landing meanwhile merges again;
                    // only the same lines changed on both sides ask.
                    attempts += 1
                    let theirs = try? await storage.read(url)
                    guard attempts < 4, let theirs,
                          let merged = NoteMerge.merge(base: base, mine: text, theirs: theirs)
                    else {
                        shown = theirs
                        throw NoteWriteError.changedElsewhere
                    }
                    written = merged
                    original = theirs
                }
            }
            // A read begun before this write holds what it replaced.
            loadLanded = loadsStarted
            onDisk = written
            if written == text {
                source = text
                if pending == text { pending = nil } else { saveSoon() }
            } else {
                takeMerge(written, mergedFrom: text)
            }
            discardDraft()
            vault.noteWritten()
        } catch NoteWriteError.changedElsewhere {
            conflict = true
            recordDraft()
        } catch {
            saveError = error.localizedDescription
            recordDraft()
        }
    }

    /// Hands a merged save to the editor, which takes it as it takes a
    /// reload. Typing during the write is on top of `buffer`, the text that
    /// was merged, so the merge is carried into it in turn and saved next.
    private func takeMerge(_ merged: String, mergedFrom buffer: String) {
        guard let typed = pending, typed != buffer else {
            replaced = buffer
            pending = nil
            source = merged
            revision += 1
            return
        }
        guard let carried = NoteMerge.merge(base: buffer, mine: typed, theirs: merged) else {
            // The typing reached the lines the capture changed meanwhile.
            shown = merged
            conflict = true
            recordDraft()
            return
        }
        replaced = typed
        pending = carried
        source = carried
        revision += 1
        saveSoon()
    }

    /// Writes what was typed over the version that arrived meanwhile.
    /// In the queue with the saves, and like them it keeps typing that came
    /// in during the write for the next save.
    ///
    /// Over that version only: the file can change again while the reader
    /// decides, and with captures it often has. So the save takes the shown
    /// version as its base and merges a later change as any save does, or
    /// asks again when the later change touches the same lines.
    public func keepMine() async {
        let previous = writing
        let current = Task { await previous?.value; await overwrite() }
        writing = current
        await current.value
    }

    private func overwrite() async {
        guard let vault, let text = pending, let url = vault.noteURL(at: path) else { return }
        if let decided = shown {
            onDisk = decided
            shown = nil
            conflict = false
            return await write()
        }
        do {
            try await storage.overwrite(text, url)
            loadLanded = loadsStarted
            onDisk = text
            source = text
            conflict = false
            if pending == text { pending = nil } else { saveSoon() }
            discardDraft()
            vault.noteWritten()
        } catch {
            saveError = error.localizedDescription
            recordDraft()
        }
    }

    /// Drops what was typed for the version that arrived meanwhile.
    public func useTheirs() async {
        guard let vault else { return }
        dropped = pending
        pending = nil
        conflict = false
        shown = nil
        discardDraft()
        await load(in: vault)
    }

    /// Where a caret at `offset` in `old` belongs in `new`, both in UTF-16
    /// units: where it was while the text before it is unchanged, else as
    /// far from the end while the text after it is, which is a capture
    /// filed above the line being typed. Otherwise clamped.
    public static func caret(_ offset: Int, from old: String, to new: String) -> Int {
        let old = old as NSString, new = new as NSString
        let offset = min(max(0, offset), old.length)
        if offset <= new.length, old.substring(to: offset) == new.substring(to: offset) {
            return offset
        }
        let tail = old.length - offset
        if tail <= new.length, old.substring(from: offset) == new.substring(from: new.length - tail) {
            return new.length - tail
        }
        return min(offset, new.length)
    }

    // MARK: Drafts

    private func recordDraft() {
        guard let root = vault?.root, let pending else { return }
        DraftStore.write(pending, vault: root, relativePath: path)
    }

    private func discardDraft() {
        guard let root = vault?.root else { return }
        DraftStore.discard(vault: root, relativePath: path)
    }

    /// A draft that outlived the document that wrote it, written into the
    /// vault beside the note unless it says what the note says. Kept when
    /// that write fails, for the next time the note opens.
    private func recoverDraft(beside url: URL) async {
        guard let vault, let root = vault.root,
              let draft = DraftStore.draft(vault: root, relativePath: path)
        else { return }
        // nil when the write failed, false when there was nothing to write.
        let wrote = await Task.detached { () -> Bool? in
            if let current = try? NoteFile.read(url), current == draft { return false }
            guard !draft.isEmpty else { return false }
            let name = DraftStore.recoveryName(for: url.deletingPathExtension().lastPathComponent)
            let folder = url.deletingLastPathComponent()
            let file = VaultOperations.uniqueName(base: name, extension: "md") {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            return (try? NoteFile.create(draft, at: folder.appendingPathComponent(file))) != nil ? true : nil
        }.value
        guard let wrote else { return }
        DraftStore.discard(vault: root, relativePath: path)
        if wrote { vault.noteWritten() }
    }
}

/// A save refused because the file no longer holds what the edit was based on.
public enum NoteWriteError: LocalizedError {
    case changedElsewhere

    public var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This note changed on another device while you were editing. Heft kept that version; your edit is still in the editor."
        }
    }
}

/// A note's file read and written through a file coordinator, which is also
/// what makes iCloud fetch a note that is not on the device yet.
public enum NoteFile {
    public static func read(_ url: URL) throws -> String {
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
    public static func write(_ text: String, to url: URL, replacing original: String) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging,
                                       error: &coordinationError) { coordinated in
            result = Result {
                // Renamed or deleted elsewhere is a change too, which Keep
                // Mine can write back; as a failed read it was reported on
                // every pause in typing.
                guard FileManager.default.fileExists(atPath: coordinated.path) else {
                    throw NoteWriteError.changedElsewhere
                }
                let current = try String(contentsOf: coordinated, encoding: .utf8)
                guard current == original else { throw NoteWriteError.changedElsewhere }
                try text.write(to: coordinated, atomically: true, encoding: .utf8)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Writes a new file, refusing one that is already there.
    public static func create(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) {
            coordinated in
            result = Result { try Data(text.utf8).write(to: coordinated, options: .withoutOverwriting) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Writes `text` whatever the file holds now: what the reader chose when
    /// told the note had changed on another device.
    public static func overwrite(_ text: String, at url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { coordinated in
            result = Result { try text.write(to: coordinated, atomically: true, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}
