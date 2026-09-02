import Foundation

public enum ObsidianSettingsWriteError: LocalizedError {
    case invalidDailyNotesConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidDailyNotesConfiguration:
            return "The existing .obsidian/daily-notes.json is not valid JSON. Heft left it unchanged."
        }
    }
}

/// The subset of an existing vault's `.obsidian/` configuration that Heft
/// honours, so that opening a vault Obsidian already manages behaves the way
/// the user has it set up rather than the way Heft would guess.
///
/// Everything here degrades to an Obsidian-default when the file is missing,
/// which is also what a plain (non-Obsidian) folder of markdown gets.
public struct ObsidianSettings: Equatable, Sendable {
    /// Folder for daily notes, vault-relative. Empty means the vault root.
    public var dailyNotesFolder: String = ""
    /// Whether the vault actually says where daily notes go.
    ///
    /// Empty cannot answer this on its own: it is both "the vault root" and
    /// "nobody has said". Obsidian's own default is the root, so a vault that
    /// chose the root must keep it or the two apps look in different places —
    /// but a vault that never configured daily notes has no Obsidian setting
    /// to agree with, and gets Heft's default instead.
    public var dailyNotesFolderIsConfigured: Bool = false
    /// moment.js pattern for daily-note filenames.
    public var dailyNoteFormat: String = "YYYY-MM-DD"
    /// Vault-relative path to the daily template, without the `.md` extension.
    public var dailyNoteTemplate: String?
    /// `""` = vault root, `"Attachments"` = that folder, `"./x"` = beside the note.
    public var attachmentFolderPath: String = ""
    /// Folder used by the core Templates plugin.
    public var templatesFolder: String?
    /// Whether the vault writes `[[Wikilinks]]` (true) or `[md](links)` (false).
    public var useWikilinks: Bool = true
    /// Obsidian's editor vim mode; Heft mirrors it as the editor default.
    public var vimMode: Bool = false
    /// When false (Obsidian's default), a single newline renders as a line
    /// break rather than a space. CommonMark says space; Obsidian does not,
    /// and matching the vault's own setting matters more than matching the spec.
    public var strictLineBreaks: Bool = false

    public init() {}

    public static func load(vaultRoot: URL) -> ObsidianSettings {
        var settings = ObsidianSettings()
        let configDir = vaultRoot.appendingPathComponent(".obsidian", isDirectory: true)

        if let app = json(at: configDir.appendingPathComponent("app.json")) {
            // Obsidian stores `useMarkdownLinks: true` to mean "not wikilinks".
            if let markdownLinks = app["useMarkdownLinks"] as? Bool { settings.useWikilinks = !markdownLinks }
            if let path = app["attachmentFolderPath"] as? String { settings.attachmentFolderPath = path }
            if let vim = app["vimMode"] as? Bool { settings.vimMode = vim }
            if let strict = app["strictLineBreaks"] as? Bool { settings.strictLineBreaks = strict }
        }

        if let daily = json(at: configDir.appendingPathComponent("daily-notes.json")) {
            if let folder = daily["folder"] as? String {
                settings.dailyNotesFolder = folder
                settings.dailyNotesFolderIsConfigured = true
            }
            if let format = daily["format"] as? String, !format.isEmpty { settings.dailyNoteFormat = format }
            if let template = daily["template"] as? String, !template.isEmpty {
                settings.dailyNoteTemplate = template
            }
        }

        if let templates = json(at: configDir.appendingPathComponent("templates.json")) {
            if let folder = templates["folder"] as? String, !folder.isEmpty { settings.templatesFolder = folder }
        }

        return settings
    }

    /// Writes only the daily-notes configuration, preserving keys from
    /// Obsidian versions or plugins that Heft does not understand.
    ///
    /// The file is replaced atomically so an interrupted write cannot leave a
    /// production vault with half a JSON document.
    public func saveDailyNotesConfiguration(vaultRoot: URL) throws {
        let configDir = vaultRoot.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true
        )

        let url = configDir.appendingPathComponent("daily-notes.json")
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard !exists || Self.json(at: url) != nil else {
            throw ObsidianSettingsWriteError.invalidDailyNotesConfiguration
        }
        var daily = Self.json(at: url) ?? [:]
        daily["folder"] = dailyNotesFolder
        daily["format"] = dailyNoteFormat
        if let dailyNoteTemplate, !dailyNoteTemplate.isEmpty {
            daily["template"] = dailyNoteTemplate
        } else {
            daily.removeValue(forKey: "template")
        }

        var data = try JSONSerialization.data(
            withJSONObject: daily, options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Resolves where a pasted or dropped attachment should be written.
    /// `noteURL` matters only for the `./relative` form.
    public func attachmentDirectory(vaultRoot: URL, noteURL: URL?) -> URL {
        let path = attachmentFolderPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return vaultRoot }

        if path.hasPrefix("./") {
            let sub = String(path.dropFirst(2))
            let base = noteURL?.deletingLastPathComponent() ?? vaultRoot
            return sub.isEmpty ? base : base.appendingPathComponent(sub, isDirectory: true)
        }
        return vaultRoot.appendingPathComponent(path, isDirectory: true)
    }

    private static func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
