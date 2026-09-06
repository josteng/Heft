import Foundation

/// What `heft config` prints: the vault's settings and the fixtures an agent
/// otherwise has to work out for itself, such as where today's note is.
///
/// In the pure target, as a dictionary, so a test can ask for it without
/// running the command and reading its output back.
public enum VaultConfigReport {
    public static func make(
        vaultRoot root: URL, noteCount: Int, on date: Date = Date()
    ) -> [String: Any] {
        let settings = ObsidianSettings.load(vaultRoot: root)
        let daily = DailyNotes(vaultRoot: root, settings: settings)
        return [
            "vault": root.path,
            "notes": noteCount,
            "dailyNotesFolder": daily.folder,
            "dailyNotesFolderIsConfigured": settings.dailyNotesFolderIsConfigured,
            "dailyNoteFormat": settings.dailyNoteFormat,
            "dailyNoteTemplate": settings.dailyNoteTemplate as Any,
            // Today's note by the vault's own rule, so an agent asked to add
            // to it does not have to apply the date format itself, and
            // whether it is there yet, since `heft daily` would create it.
            "todayNote": daily.relativePath(for: date),
            "todayNoteExists": daily.exists(for: date),
            "attachmentFolderPath": settings.attachmentFolderPath,
            "inboxNote": InboxNotePreference.path(for: root),
            "templatesFolder": settings.templatesFolder as Any,
            "useWikilinks": settings.useWikilinks,
            "strictLineBreaks": settings.strictLineBreaks,
        ]
    }
}
