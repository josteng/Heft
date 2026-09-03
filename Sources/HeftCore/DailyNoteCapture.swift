import Foundation

public enum DailyNoteCaptureError: LocalizedError, Sendable {
    case emptyCapture
    case vaultUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyCapture:
            return "Enter something to add to today's note."
        case .vaultUnavailable:
            return "The capture vault is no longer available. Open it in Heft and try again."
        }
    }
}

/// Appends a chronological, timestamped bullet to the configured daily note.
/// The coordinated read-modify-write keeps simultaneous Spotlight captures
/// from replacing one another.
public struct DailyNoteCapture: Sendable {
    /// Put this marker on its own line in a daily-note template. Captures are
    /// inserted immediately above it, so the marker remains the insertion
    /// cursor for the next chronological item.
    public static let insertionMarker = "<!-- heft:daily-log -->"

    public let dailyNotes: DailyNotes

    public init(vaultRoot: URL, settings: ObsidianSettings) {
        dailyNotes = DailyNotes(vaultRoot: vaultRoot, settings: settings)
    }

    @discardableResult
    public func capture(
        _ rawText: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        var vaultIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: dailyNotes.vaultRoot.path,
            isDirectory: &vaultIsDirectory
        ), vaultIsDirectory.boolValue else {
            throw DailyNoteCaptureError.vaultUnavailable
        }

        let url = try dailyNotes.ensureNote(for: date)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let existing = try String(contentsOf: coordinatedURL, encoding: .utf8)
                let updated = try Self.contents(
                    byCapturing: rawText,
                    in: existing,
                    at: date,
                    calendar: calendar,
                    title: dailyNotes.stem(for: date)
                )
                try updated.write(to: coordinatedURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        VaultContentChangeNotification.post(for: dailyNotes.vaultRoot)
        return url
    }

    /// - Parameter title: the note's own name, used to give an empty note a
    ///   heading before its first captured item.
    public static func contents(
        byCapturing rawText: String,
        in existing: String,
        at date: Date,
        calendar: Calendar = .current,
        title: String? = nil
    ) throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DailyNoteCaptureError.emptyCapture }

        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)

        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let continuation = lines.dropFirst().map { "  \($0)" }.joined(separator: newline)
        let entry = continuation.isEmpty
            ? "- \(time) \(first)"
            : "- \(time) \(first)\(newline)\(continuation)"

        if let marker = markerLine(in: existing, newline: newline) {
            var result = existing
            result.insert(contentsOf: entry + newline, at: marker.lowerBound)
            return result
        }

        // An empty note gets a heading before its first item, the way
        // `Inbox.md` does. Without it, capturing into a note that happens to
        // be empty leaves a bare `- 14:32 …` as the whole file: the note has
        // no title, and the first thing in it is a bullet with nothing above
        // it to write under.
        //
        // Blank rather than strictly empty, because a note created and then
        // left alone usually holds a newline or two, and those should not be
        // the difference between a titled note and an untitled one.
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let title, !title.isEmpty else { return entry + newline }
            return "# \(title)\(newline)\(newline)\(entry)\(newline)"
        }

        return existing
            + (existing.hasSuffix(newline) ? "" : newline)
            + entry
            + newline
    }

    /// The marker captures are inserted above: the **last** one in the note.
    ///
    /// A note is not guaranteed to hold only one. A template contributes one,
    /// and another arrives whenever a whole body is pasted or accepted from an
    /// agent proposal that carried its own. Taking the first would then move
    /// the insertion point backwards the moment a second appeared above it,
    /// splitting a day's log in two and dropping new entries somewhere in the
    /// middle of the note. The last marker keeps them where the earlier ones
    /// already are — at the end of the log.
    private static func markerLine(
        in text: String,
        newline: String
    ) -> Range<String.Index>? {
        var start = text.startIndex
        var found: Range<String.Index>?
        while start < text.endIndex {
            let lineBreak = text.range(of: newline, range: start..<text.endIndex)
            let end = lineBreak?.lowerBound ?? text.endIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if line == insertionMarker { found = start..<end }
            guard let lineBreak else { break }
            start = lineBreak.upperBound
        }
        return found
    }
}
