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
                    calendar: calendar
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

    public static func contents(
        byCapturing rawText: String,
        in existing: String,
        at date: Date,
        calendar: Calendar = .current
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

        guard !existing.isEmpty else { return entry + newline }
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
