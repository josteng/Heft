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

    /// Where Heft files daily notes when the vault has not said.
    ///
    /// Obsidian's default is the vault root, and a configured vault is still
    /// followed exactly. But an unconfigured vault has no setting to be
    /// compatible with, and clicking a date then drops a dated file among the
    /// user's own notes; the setup sheet has always proposed "Daily" for the
    /// same reason, so doing it only once that sheet has been visited made the
    /// app propose one thing and do another.
    public static let defaultFolder = "Daily"

    /// The folder daily notes actually go in.
    public var folder: String {
        if settings.dailyNotesFolderIsConfigured {
            return settings.dailyNotesFolder.trimmingCharacters(in: .whitespaces)
        }
        return rootAlreadyHoldsDailyNotes ? "" : Self.defaultFolder
    }

    /// Whether this vault is already keeping daily notes in its root.
    ///
    /// Changing the default must not split an existing habit in two, leaving
    /// yesterday in the root and today in `Daily/`. Checked against the vault's
    /// own filename format over the recent past, so it recognises the notes
    /// this vault would actually have written.
    private var rootAlreadyHoldsDailyNotes: Bool {
        let calendar = Calendar.current
        let today = Date()
        for offset in 0..<60 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let candidate = vaultRoot.appendingPathComponent("\(stem(for: date)).md")
            if FileManager.default.fileExists(atPath: candidate.path) { return true }
        }
        return false
    }

    /// Vault-relative path including the `.md` extension.
    public func relativePath(for date: Date) -> String {
        let stem = stem(for: date)
        let folder = folder
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
