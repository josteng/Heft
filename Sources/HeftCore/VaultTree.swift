import Foundation

/// What a file looked like when it was scanned: enough to tell, without
/// opening it, whether its contents can have changed since.
///
/// The index keeps what it parsed out of each note against this, so a vault
/// reload re-reads only the notes whose file actually changed. On an
/// iCloud-backed vault that is the difference between a rescan costing a few
/// milliseconds and one that reads every note, because the daemon touches
/// files it has not changed all the time.
public struct FileFingerprint: Hashable, Sendable {
    public let size: Int
    /// Modification time in whole nanoseconds. Kept as an integer rather than
    /// a `Date`: two `Date`s made from one unchanged timestamp have been seen
    /// to compare unequal while printing identically, and a fingerprint that
    /// never matched would put the full re-read straight back.
    public let modifiedNanoseconds: Int64

    public init(size: Int, modified: Date) {
        self.size = size
        modifiedNanoseconds = Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}

/// One node in the vault's file tree.
public struct VaultItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case folder, markdown, image, pdf, canvas, other }

    public let url: URL
    /// Path relative to the vault root, using `/` separators. Stable identity.
    public let relativePath: String
    public let kind: Kind
    /// Display name: markdown loses its extension, everything else keeps it.
    public let name: String
    /// True when iCloud has evicted the file's contents and only a placeholder
    /// is on disk. Reading it needs a download first.
    public let needsDownload: Bool
    /// Size and modification time at scan time; nil for folders and for items
    /// built by hand rather than scanned, which the index then always reads.
    public let fingerprint: FileFingerprint?
    public var children: [VaultItem]

    public var id: String { relativePath }
    public var isFolder: Bool { kind == .folder }
    public var isMarkdown: Bool { kind == .markdown }

    /// Equality is the tree as the sidebar sees it, so it leaves the
    /// fingerprint out. That is bookkeeping for the index, which compares it
    /// itself, and keeping it out of `==` is what lets a save that moved one
    /// file's date leave the published tree equal, and the windows unbothered.
    public static func == (lhs: VaultItem, rhs: VaultItem) -> Bool {
        lhs.relativePath == rhs.relativePath && lhs.url == rhs.url && lhs.kind == rhs.kind
            && lhs.name == rhs.name && lhs.needsDownload == rhs.needsDownload
            && lhs.children == rhs.children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(relativePath)
        hasher.combine(kind)
        hasher.combine(name)
        hasher.combine(needsDownload)
        hasher.combine(children)
    }

    public init(
        url: URL, relativePath: String, kind: Kind, name: String,
        needsDownload: Bool = false, fingerprint: FileFingerprint? = nil,
        children: [VaultItem] = []
    ) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.name = name
        self.needsDownload = needsDownload
        self.fingerprint = fingerprint
        self.children = children
    }

    /// Depth-first walk over this node and all descendants.
    public func flattened() -> [VaultItem] {
        [self] + children.flatMap { $0.flattened() }
    }
}

public enum VaultScanner {

    /// Directories that are machinery rather than content. Anything else
    /// beginning with `.` is skipped too, this list is for the ones worth
    /// naming explicitly.
    public static let ignoredDirectories: Set<String> = [
        ".obsidian", ".trash", ".git", ".makemd", ".space", ".smart-env",
        "node_modules", ".DS_Store",
    ]

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg",
    ]

    /// Builds the tree rooted at `root`. Returns the root folder item.
    public static func scan(root: URL) -> VaultItem {
        let name = root.lastPathComponent
        return VaultItem(
            url: root,
            relativePath: "",
            kind: .folder,
            name: name,
            children: scanChildren(of: root, prefix: "")
        )
    }

    private static func scanChildren(of directory: URL, prefix: String) -> [VaultItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: []
        ) else { return [] }

        var items: [VaultItem] = []

        for entry in entries {
            let raw = entry.lastPathComponent
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                if raw.hasPrefix(".") || ignoredDirectories.contains(raw) { continue }
                let rel = prefix.isEmpty ? raw : "\(prefix)/\(raw)"
                let children = scanChildren(of: entry, prefix: rel)
                items.append(VaultItem(
                    url: entry, relativePath: rel, kind: .folder, name: raw, children: children
                ))
                continue
            }

            // iCloud evicts file contents and leaves `.Name.md.icloud` behind.
            // Present it under its real name so the tree does not visibly
            // change shape depending on what happens to be downloaded.
            let (displayFilename, needsDownload) = resolvePlaceholder(raw)
            let presentedURL = needsDownload
                ? entry.deletingLastPathComponent().appendingPathComponent(displayFilename)
                : entry
            if displayFilename.hasPrefix(".") { continue }

            if displayFilename == ".DS_Store" { continue }

            // Every non-hidden file is kept, not just markdown and images:
            // Obsidian lets a wikilink point at any file in the vault, and
            // dropping unknown types here makes those links fail to resolve.
            let ext = (displayFilename as NSString).pathExtension.lowercased()
            let kind = classify(extension: ext)

            let rel = prefix.isEmpty ? displayFilename : "\(prefix)/\(displayFilename)"
            let name = kind == .markdown
                ? (displayFilename as NSString).deletingPathExtension
                : displayFilename

            // Read from the entry as listed, so a placeholder is fingerprinted
            // as the placeholder: when the real file arrives it has a
            // different size and date, which is exactly a change.
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let fingerprint = values?.contentModificationDate.map {
                FileFingerprint(size: values?.fileSize ?? 0, modified: $0)
            }

            items.append(VaultItem(
                url: presentedURL, relativePath: rel, kind: kind, name: name,
                needsDownload: needsDownload, fingerprint: fingerprint
            ))
        }

        // Folders first, then files, each alphabetically and case-insensitively.
        return items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `.Note.md.icloud` -> (`Note.md`, true); anything else passes through.
    static func resolvePlaceholder(_ filename: String) -> (String, Bool) {
        guard filename.hasPrefix("."), filename.hasSuffix(".icloud") else { return (filename, false) }
        let inner = filename.dropFirst().dropLast(".icloud".count)
        return (String(inner), true)
    }

    static func classify(extension ext: String) -> VaultItem.Kind {
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "canvas" { return .canvas }
        return .other
    }
}
