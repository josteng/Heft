import Foundation

/// Resolves and creates daily notes using the vault's own configuration, so a
/// note Heft creates lands exactly where Obsidian would have put it.
public struct DailyNotes: Sendable {
    public let vaultRoot: URL
    public let settings: ObsidianSettings

    public init(vaultRoot: URL, settings: ObsidianSettings) {
        self.vaultRoot = vaultRoot
        self.settings = settings
    }

    /// Filename stem for a date, e.g. `2026-08-07`. The configured format may
    /// itself contain `/`, which Obsidian treats as nested folders.
    public func stem(for date: Date) -> String {
        MomentFormat.format(date, pattern: settings.dailyNoteFormat)
    }

    /// Vault-relative path including the `.md` extension.
    public func relativePath(for date: Date) -> String {
        let stem = stem(for: date)
        let folder = settings.dailyNotesFolder.trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? "\(stem).md" : "\(folder)/\(stem).md"
    }

    public func url(for date: Date) -> URL {
        vaultRoot.appendingPathComponent(relativePath(for: date))
    }

    public func exists(for date: Date) -> Bool {
        FileManager.default.fileExists(atPath: url(for: date).path)
    }

    /// Reads the configured template, tolerating a path written with or
    /// without the `.md` extension (Obsidian stores it without).
    public func templateBody() -> String? {
        guard let template = settings.dailyNoteTemplate, !template.isEmpty else { return nil }
        let candidates = template.hasSuffix(".md") ? [template] : ["\(template).md", template]
        for candidate in candidates {
            let url = vaultRoot.appendingPathComponent(candidate)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Returns the note for `date`, creating it from the template if absent.
    /// Never overwrites: an existing note is returned untouched.
    @discardableResult
    public func ensureNote(for date: Date) throws -> URL {
        let target = url(for: date)
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let title = stem(for: date)
        let body = templateBody().map {
            MomentFormat.expandTemplate(
                $0, date: date, title: title, dateFormat: settings.dailyNoteFormat
            )
        } ?? "# \(title)\n\n"

        try body.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
