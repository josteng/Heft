import Foundation

/// Watches the vault subtree and reports coalesced change notifications.
///
/// FSEvents rather than a `DispatchSource` per file: the vault is hundreds of
/// files across nested folders, and iCloud materialising a file counts as a
/// change we want to hear about without holding a descriptor for each one.
public final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "dev.stenglein.Heft.watcher")

    public init?(root: URL, latency: TimeInterval = 0.6, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes` makes this a CFArray of
            // CFString rather than a C string array.
            let changed = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            guard changed.contains(where: VaultWatcher.isInteresting) else { return }
            DispatchQueue.main.async { watcher.onChange() }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Whether a changed path is worth rebuilding the vault index for.
    ///
    /// An iCloud-backed vault is never quiet: the daemon writes and removes
    /// `.icloud` placeholders, updates extended attributes, and Obsidian
    /// rewrites `workspace.json` on every pane change. Every one of those used
    /// to trigger a full rescan, which re-reads every note in the vault to
    /// rebuild the link and tag index — so the app burned CPU while sitting
    /// apparently idle.
    public static func isInteresting(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return false }
        // A placeholder appearing means the real file is on its way; the real
        // file's own event is the one worth acting on.
        if name.hasPrefix("."), name.hasSuffix(".icloud") { return false }
        for hidden in ["/.obsidian/", "/.git/", "/.trash/", "/.stversions/"]
        where path.contains(hidden) {
            return false
        }
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
