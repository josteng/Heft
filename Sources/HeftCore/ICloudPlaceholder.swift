import Foundation

/// A file iCloud has evicted from this device: only `.Name.icloud` is on
/// disk beside where it belongs. Coordinating a write does not fetch it
/// first, so code that takes a missing file for a new one would write a
/// fresh note at the path iCloud holds the real one at.
public enum ICloudPlaceholder {
    public struct NotDownloaded: LocalizedError, Sendable {
        public let name: String
        public var errorDescription: String? {
            "\(name) is still downloading from iCloud. Try again in a moment."
        }
    }

    /// Where iCloud leaves the placeholder for `url`.
    public static func url(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// True when `url` itself is missing and its placeholder is there.
    public static func isEvicted(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path)
            && FileManager.default.fileExists(atPath: Self.url(for: url).path)
    }

    /// Throws, and asks for the download, when `url` is only a placeholder.
    public static func requireDownloaded(_ url: URL) throws {
        guard isEvicted(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw NotDownloaded(name: (url.lastPathComponent as NSString).deletingPathExtension)
    }
}
