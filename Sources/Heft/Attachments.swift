import AppKit
import CryptoKit
import HeftCore
import UniformTypeIdentifiers

/// Writes pasted or dropped images into the vault's attachment folder and
/// hands back the markdown to insert.
enum Attachments {

    /// Everything the destination depends on, gathered at the call site so the
    /// rules can be resolved anywhere — including a settings pane showing what
    /// a paste *would* do, before one has happened.
    struct Destination {
        let rules: AttachmentRules
        let index: VaultIndex
        let settings: ObsidianSettings

        /// Where a file pasted into `noteURL` should go, and the rule that
        /// said so.
        func resolve(vaultRoot: URL, noteURL: URL?) -> AttachmentRules.Destination {
            let folder = noteURL.map { url -> String in
                let note = url.standardizedFileURL.path
                let root = vaultRoot.standardizedFileURL.path
                guard note.hasPrefix(root + "/") else { return "" }
                let relative = String(note.dropFirst(root.count + 1))
                let parts = relative.split(separator: "/")
                return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
            } ?? ""

            return rules.destination(in: AttachmentRules.Context(
                noteFolder: folder,
                obsidianSetting: settings.attachmentFolderPath,
                learned: index.attachmentDestination(near: folder),
                folderExists: { candidate in
                    guard !candidate.isEmpty else { return true }
                    var isFolder: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: vaultRoot.appendingPathComponent(candidate).path,
                        isDirectory: &isFolder
                    )
                    return exists && isFolder.boolValue
                }
            ))
        }

        /// The folder to write into, made first only if the rule that chose it
        /// is allowed to. Every other rule names somewhere that already exists,
        /// so nothing appears in a vault that the reader did not make.
        func directory(vaultRoot: URL, noteURL: URL?) throws -> URL {
            let chosen = resolve(vaultRoot: vaultRoot, noteURL: noteURL)
            guard !chosen.folder.isEmpty else { return vaultRoot }
            let url = vaultRoot.appendingPathComponent(chosen.folder, isDirectory: true)
            if chosen.needsCreating {
                guard chosen.rule.mayCreate else { return vaultRoot }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
    }

    /// Saves image data, reusing an existing file when the identical bytes are
    /// already in the vault. Pasting the same screenshot twice should not
    /// leave two copies for iCloud to sync.
    static func save(
        imageData: Data,
        preferredName: String?,
        vaultRoot: URL,
        noteURL: URL?,
        settings: ObsidianSettings,
        destination: Destination
    ) throws -> String {
        let directory = try destination.directory(vaultRoot: vaultRoot, noteURL: noteURL)

        let (data, ext) = normalise(imageData)
        let digest = SHA256.hash(data: data).prefix(6)
            .map { String(format: "%02x", $0) }.joined()

        let stem: String
        if let preferredName, !preferredName.isEmpty {
            stem = (preferredName as NSString).deletingPathExtension
        } else {
            stem = "Pasted image " + MomentFormat.format(Date(), pattern: "YYYYMMDDHHmmss")
        }

        // Content hash in the name makes duplicate detection a file-exists check.
        let filename = "\(stem) \(digest).\(ext)"
        let target = directory.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }

        return linkMarkdown(for: target, vaultRoot: vaultRoot, noteURL: noteURL, settings: settings)
    }

    /// Copies a file already on disk (a drag from Finder) into the vault.
    static func importFile(
        at source: URL,
        vaultRoot: URL,
        noteURL: URL?,
        settings: ObsidianSettings,
        destination: Destination
    ) throws -> String {
        // Files already inside the vault are linked in place, not duplicated.
        if source.path.hasPrefix(vaultRoot.path) {
            return linkMarkdown(for: source, vaultRoot: vaultRoot, noteURL: noteURL, settings: settings)
        }
        let data = try Data(contentsOf: source)
        if VaultScanner.imageExtensions.contains(source.pathExtension.lowercased()) {
            return try save(
                imageData: data, preferredName: source.lastPathComponent,
                vaultRoot: vaultRoot, noteURL: noteURL, settings: settings,
                destination: destination
            )
        }

        let directory = try destination.directory(vaultRoot: vaultRoot, noteURL: noteURL)
        var target = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let stem = (source.lastPathComponent as NSString).deletingPathExtension
            target = directory.appendingPathComponent("\(stem) \(counter).\(source.pathExtension)")
            counter += 1
        }
        try data.write(to: target, options: .atomic)
        return linkMarkdown(for: target, vaultRoot: vaultRoot, noteURL: noteURL, settings: settings)
    }

    /// Pulls image data out of a pasteboard, preferring a real file over a
    /// rendered bitmap so an original PNG is not re-encoded on the way in.
    static func imagePayload(from pasteboard: NSPasteboard) -> (data: Data, name: String?)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { VaultScanner.imageExtensions.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: url) {
            return (data, url.lastPathComponent)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return (data, nil) }
        }
        return nil
    }

    // MARK: - Helpers

    /// TIFF from the clipboard is huge; convert it to PNG. Anything already in
    /// a compressed format is passed through untouched.
    private static func normalise(_ data: Data) -> (Data, String) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "jpg") }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return (data, "png")
    }

    private static func linkMarkdown(
        for target: URL, vaultRoot: URL, noteURL: URL?, settings: ObsidianSettings
    ) -> String {
        guard settings.useWikilinks else {
            let path = relativePath(from: noteURL?.deletingLastPathComponent() ?? vaultRoot, to: target)
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "![](\(encoded))"
        }
        // Obsidian wikilinks address attachments by filename alone.
        return "![[\(target.lastPathComponent)]]"
    }

    private static func relativePath(from base: URL, to target: URL) -> String {
        let baseParts = base.standardizedFileURL.pathComponents
        let targetParts = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < baseParts.count, shared < targetParts.count, baseParts[shared] == targetParts[shared] {
            shared += 1
        }
        let up = Array(repeating: "..", count: baseParts.count - shared)
        return (up + targetParts[shared...]).joined(separator: "/")
    }
}
