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
    ///
    /// The resolving itself is `AttachmentDestination` in HeftCore, so the
    /// command line answers the same question with the same rules.
    struct Destination {
        let rules: AttachmentRules
        let index: VaultIndex
        let settings: ObsidianSettings

        /// Where a file pasted into `noteURL` should go, and the rule that
        /// said so.
        func resolve(vaultRoot: URL, noteURL: URL?) -> AttachmentRules.Destination {
            let folder = AttachmentDestination.folder(of: noteURL, in: vaultRoot)
            return AttachmentDestination(
                rules: rules, vaultRoot: vaultRoot, settings: settings
            ).resolve(noteURL: noteURL, learned: index.attachmentDestination(near: folder))
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
        AttachmentDestination.link(
            to: target, from: noteURL, vaultRoot: vaultRoot, settings: settings
        )
    }
}
