import Foundation

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
    public var children: [VaultItem]

    public var id: String { relativePath }
    public var isFolder: Bool { kind == .folder }
    public var isMarkdown: Bool { kind == .markdown }

    public init(
        url: URL, relativePath: String, kind: Kind, name: String,
        needsDownload: Bool = false, children: [VaultItem] = []
    ) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.name = name
        self.needsDownload = needsDownload
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
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
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

            items.append(VaultItem(
                url: presentedURL, relativePath: rel, kind: kind, name: name,
                needsDownload: needsDownload
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
