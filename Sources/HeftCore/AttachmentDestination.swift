import Foundation

/// Where a file attached to a given note actually goes, and what to write in
/// the note to point at it.
///
/// `AttachmentRules` decides *which* rule answers; this is everything around
/// that — working the note's folder out of a URL, asking the filesystem what
/// exists, and turning a resolved folder into the wikilink or Markdown link a
/// vault prefers. It lived inside the app target, so nothing on the command
/// line could reach it: an agent handed a file had to guess where to put it,
/// and `heft config` only reported the raw Obsidian setting, which is one of
/// five rules and often not the one that answers.
public struct AttachmentDestination: Sendable {
    public let rules: AttachmentRules
    public let vaultRoot: URL
    public let settings: ObsidianSettings

    public init(rules: AttachmentRules, vaultRoot: URL, settings: ObsidianSettings) {
        self.rules = rules
        self.vaultRoot = vaultRoot
        self.settings = settings
    }

    /// The folder of a note, vault-relative, and empty for one at the root.
    public static func folder(of noteURL: URL?, in vaultRoot: URL) -> String {
        guard let noteURL else { return "" }
        let note = noteURL.standardizedFileURL.path
        let root = vaultRoot.standardizedFileURL.path
        guard note.hasPrefix(root + "/") else { return "" }
        let relative = String(note.dropFirst(root.count + 1))
        let parts = relative.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    /// Where a file attached to `noteURL` should go, and the rule that said so.
    public func resolve(noteURL: URL?, learned: String?) -> AttachmentRules.Destination {
        rules.destination(in: AttachmentRules.Context(
            noteFolder: Self.folder(of: noteURL, in: vaultRoot),
            obsidianSetting: settings.attachmentFolderPath,
            learned: learned,
            folderExists: { [vaultRoot] candidate in
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

    /// What to write in the note to point at a file, in the form this vault
    /// prefers. Obsidian's wikilinks address an attachment by filename alone;
    /// a Markdown link needs a path relative to the note.
    ///
    /// Static because it needs no rules: which folder the file went in is
    /// already settled by the time there is something to link to.
    public static func link(
        to target: URL, from noteURL: URL?, vaultRoot: URL, settings: ObsidianSettings
    ) -> String {
        guard settings.useWikilinks else {
            let base = noteURL?.deletingLastPathComponent() ?? vaultRoot
            let path = relativePath(from: base, to: target)
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "![](\(encoded))"
        }
        return "![[\(target.lastPathComponent)]]"
    }

    public func link(to target: URL, from noteURL: URL?) -> String {
        Self.link(to: target, from: noteURL, vaultRoot: vaultRoot, settings: settings)
    }

    public static func relativePath(from base: URL, to target: URL) -> String {
        let baseParts = base.standardizedFileURL.pathComponents
        let targetParts = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < baseParts.count, shared < targetParts.count,
              baseParts[shared] == targetParts[shared] {
            shared += 1
        }
        let up = Array(repeating: "..", count: baseParts.count - shared)
        return (up + targetParts[shared...]).joined(separator: "/")
    }
}
