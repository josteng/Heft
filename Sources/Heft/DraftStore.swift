import Foundation
import HeftCore

/// Keeps unsaved work on disk whenever it cannot reach its note.
///
/// Autosave writes the note 700ms after the last keystroke, so a crash or a
/// flat battery normally costs at most that. There are two states where it
/// costs everything instead, and both were reachable:
///
/// - **An unresolved save conflict.** Autosave is deliberately paused so the
///   file is never overwritten, and the buffer then accumulates edits in
///   memory with nothing writing them anywhere. A recovery copy was made when
///   the *window closed*, which covers quitting and not losing power.
/// - **A write that fails.** A full disk, a permissions change, an iCloud file
///   that cannot be materialised. `writeCurrentBuffer` reports it in the
///   status line and leaves the buffer dirty to retry, which is right, but the
///   only copy of the work is still in memory.
///
/// So a draft is written in both cases, to one stable file per note that is
/// overwritten rather than accumulated, and deleted the moment the buffer
/// reaches its note. If the app dies with a draft outstanding, opening that
/// note again promotes it into the vault as an ordinary "Heft Recovery" note —
/// the same naming the close path already uses, so there is one thing to look
/// for and it appears where notes appear rather than in a Library folder
/// nobody visits.
enum DraftStore {

    private static var directory: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return support.appendingPathComponent("Heft/Drafts", isDirectory: true)
    }

    /// One file per note, named from the vault and note path.
    ///
    /// Hashed rather than escaped: a note path can be any length and hold any
    /// character a filesystem allows, and a name built by substitution
    /// collides the moment two notes differ only by a character that had to be
    /// replaced.
    private static func url(vault: URL, relativePath: String) -> URL? {
        guard let directory else { return nil }
        let identity = "\(vault.standardizedFileURL.path)\u{0}\(relativePath)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(identity.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.md", hash))
    }

    /// Records the buffer as a draft. Overwrites any previous one.
    static func write(_ text: String, vault: URL, relativePath: String) {
        guard let directory, let url = url(vault: vault, relativePath: relativePath) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The note's own path goes in a sidecar rather than the filename,
        // which is a hash: without it a recovered draft cannot say what it is
        // a draft *of*.
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? relativePath.write(
            to: url.appendingPathExtension("path"), atomically: true, encoding: .utf8
        )
    }

    /// Forgets the draft, because the buffer reached its note.
    static func discard(vault: URL, relativePath: String) {
        guard let url = url(vault: vault, relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("path"))
    }

    /// The draft for a note, if one outlived the process that wrote it.
    static func draft(vault: URL, relativePath: String) -> String? {
        guard let url = url(vault: vault, relativePath: relativePath) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// A stable name for the recovery note a draft becomes.
    ///
    /// Deliberately not timestamped at recovery time: a note whose draft is
    /// promoted twice should give one file, not one per attempt.
    static func recoveryName(for noteName: String) -> String {
        "\(noteName) (Heft Recovery)"
    }
}
