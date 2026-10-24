#if os(macOS)
import Darwin

/// Whether this process may download an iCloud file that is only a
/// placeholder on disk.
///
/// macOS launches app extensions with this off, though an ordinary process
/// has it on. A note iCloud has evicted, or replaced with a newer version
/// from another device and not yet brought down, then cannot be read at
/// all: the read fails with `EDEADLK`, which Foundation reports as "The file
/// couldn't be opened", and taking a file-coordination claim does not fetch
/// it first. So a capture into an inbox the phone had just written to failed
/// while the app and `heft` read the same file without trouble.
public enum DatalessFiles {
    /// Turns it on for the whole process. Each extension calls this before
    /// it reads anything.
    @discardableResult
    public static func allowDownloads() -> Bool {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0
    }

    public static var downloadsAllowed: Bool {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
            == IOPOL_MATERIALIZE_DATALESS_FILES_ON
    }
}
#endif
