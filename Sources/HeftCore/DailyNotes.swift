import Foundation

/// Resolves and creates daily notes using the vault's own configuration, so a
/// note Heft creates lands exactly where Obsidian would have put it.
public struct DailyNotes: Sendable {
    public let vaultRoot: URL
    public let settings: ObsidianSettings
    /// The folder daily notes actually go in.
    ///
    /// Decided once, here. The unconfigured case looks for existing daily
    /// notes in the root, sixty file checks, and that used to run on every
    /// path resolved: the calendar resolves one for each of its 42 cells on
    /// every redraw, which made a keystroke cost thousands of `stat` calls.
    public let folder: String

    public init(vaultRoot: URL, settings: ObsidianSettings) {
        self.vaultRoot = vaultRoot
        self.settings = settings
        if settings.dailyNotesFolderIsConfigured {
            folder = settings.dailyNotesFolder.trimmingCharacters(in: .whitespaces)
        } else {
            folder = Self.rootAlreadyHoldsDailyNotes(in: vaultRoot, format: settings.dailyNoteFormat)
                ? "" : Self.defaultFolder
        }
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

    /// Whether this vault is already keeping daily notes in its root.
    ///
    /// Changing the default must not split an existing habit in two, leaving
    /// yesterday in the root and today in `Daily/`. Checked against the vault's
    /// own filename format over the recent past, so it recognises the notes
    /// this vault would actually have written.
    private static func rootAlreadyHoldsDailyNotes(in vaultRoot: URL, format: String) -> Bool {
        let calendar = Calendar.current
        let today = Date()
        for offset in 0..<60 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let stem = MomentFormat.format(date, pattern: format)
            let candidate = vaultRoot.appendingPathComponent("\(stem).md")
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

    /// Whether this note is filed as a daily note, so that moving it out of
    /// `folder` is what stops the calendar and ⇧⌘T from finding it.
    ///
    /// Judged by where the note lives, not by reading its name: the date
    /// format has no parser, and scanning dates to recognise a stem only ever
    /// covers the window scanned. A vault that keeps its daily notes in the
    /// root has no folder to leave, so nothing there counts.
    public func isFiledAsDaily(_ relativePath: String) -> Bool {
        guard !folder.isEmpty, relativePath.hasSuffix(".md") else { return false }
        return (relativePath as NSString).deletingLastPathComponent == folder
    }

    /// Whether moving that note to `destination`, a vault-relative file path,
    /// takes it out of the folder the calendar looks in.
    public func leavesDailyFolder(_ relativePath: String, movingTo destination: String) -> Bool {
        isFiledAsDaily(relativePath)
            && (destination as NSString).deletingLastPathComponent != folder
    }

    /// What that costs, said once here so the window's question, the command
    /// line's note and the review sheet cannot drift apart.
    public func departureNote(count: Int) -> String {
        // Named rather than "it": the review sheet puts this under a page of
        // its own text, where a pronoun has nothing nearby to stand for.
        let subject = count == 1
            ? "This note stops being a daily note."
            : "These notes stop being daily notes."
        return "\(subject) \(calendarLooksHere)"
    }

    /// The same, for a place that has room to name the file.
    public func departureNote(for name: String) -> String {
        "\(name) stops being a daily note. \(calendarLooksHere)"
    }

    private var calendarLooksHere: String { "The calendar only looks in \(folder)." }

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
