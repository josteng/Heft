import Foundation

/// What Heft opens when it starts.
///
/// Four answers, and the default is none of them: a reader who has not asked
/// for this gets the note they had, which is what every editor does.
public struct StartupNote: Codable, Equatable, Sendable {

    public enum Choice: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Leave it alone. The default, and what happens today: macOS restores
        /// the window it had, and a cold start with nothing to restore opens
        /// on no note at all.
        case nothing
        /// The note this vault was last on. Not the same as leaving it alone:
        /// that relies on the window being restored, and a cold start where it
        /// is not comes up empty.
        case lastNote
        /// Today's daily note, by the vault's own daily-note settings.
        case dailyNote
        /// One note, always.
        case note
        /// A path worked out from the date, in the same tokens a daily-note
        /// template uses — `Journal/{{date:YYYY}}/{{date:GGGG-[W]WW}}.md` for a
        /// weekly note, say. Not the same thing as the daily note: that one is
        /// a single format the whole vault shares, and this can point anywhere.
        case pattern

        public var id: String { rawValue }
        /// Whether the choice needs something written next to it.
        public var needsText: Bool { self == .note || self == .pattern }
    }

    public var choice: Choice
    /// The note's path, or the pattern. Kept when the choice changes, so
    /// going back to it does not lose what was typed.
    public var text: String

    public static let standard = StartupNote(choice: .nothing, text: "")

    public init(choice: Choice = .nothing, text: String = "") {
        self.choice = choice
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choice = try container.decodeIfPresent(Choice.self, forKey: .choice) ?? .nothing
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    /// The note to open, vault-relative, or nil to leave things as they are.
    ///
    /// - Parameters:
    ///   - dailyPath: the vault's own daily-note path for a date, which only
    ///     the app can work out and only when daily notes are configured.
    ///   - lastNote: the note this vault was last on.
    public func relativePath(
        on date: Date,
        dailyPath: (Date) -> String? = { _ in nil },
        lastNote: () -> String? = { nil }
    ) -> String? {
        switch choice {
        case .nothing:
            return nil
        case .lastNote:
            return lastNote().flatMap(tidied)
        case .dailyNote:
            return dailyPath(date)
        case .note:
            return tidied(text)
        case .pattern:
            return tidied(MomentFormat.expandTemplate(text, date: date, title: ""))
        }
    }

    /// A vault-relative path with no leading slash and an `.md` on the end, so
    /// `/Journal/2026` and `Journal/2026.md` name the same note.
    private func tidied(_ path: String) -> String? {
        // Each part trimmed and the blanks dropped, so a field holding only
        // spaces is nothing rather than a note called "  ".
        let parts = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var joined = parts.joined(separator: "/")
        // Only markdown gets an extension added. A path that already names a
        // file — `Inbox.md`, or something else entirely — is left alone.
        if (joined as NSString).pathExtension.isEmpty { joined += ".md" }
        return joined
    }
}
