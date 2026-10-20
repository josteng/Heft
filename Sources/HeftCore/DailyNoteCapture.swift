import Foundation

public enum DailyNoteCaptureError: LocalizedError, Sendable {
    case emptyCapture
    case vaultUnavailable
    case outsideVault(String)

    public var errorDescription: String? {
        switch self {
        case let .outsideVault(path):
            return "The daily note would be \(path), outside the vault. "
                + "Check the folder and format in .obsidian/daily-notes.json."
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
        calendar: Calendar = .current,
        done: Bool = false,
        inTimeOrder: Bool = false
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
                    title: dailyNotes.stem(for: date),
                    timestamped: CaptureTimestampPreference.isOn,
                    done: done,
                    inTimeOrder: inTimeOrder
                )
                try updated.writeNote(to: coordinatedURL)
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
    /// - Parameter done: write the item as a ticked task, `- [x] …`.
    /// - Parameter inTimeOrder: file the item among the section's
    ///   timestamped lines by its time rather than at the end, for a
    ///   capture made at a moment that has already passed.
    public static func contents(
        byCapturing rawText: String,
        in existing: String,
        at date: Date,
        calendar: Calendar = .current,
        title: String? = nil,
        timestamped: Bool = true,
        done: Bool = false,
        inTimeOrder: Bool = false
    ) throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DailyNoteCaptureError.emptyCapture }

        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = timestamped ? formatter.string(from: date) : ""

        // The same line the inbox writes, so the two cannot drift apart.
        let entry = InboxCapture.markdownEntry(text, time: time, done: done, newline: newline)

        let marker = markerLine(in: existing, newline: newline)
        if inTimeOrder, let minute = minutes(time),
           let point = timeOrderedInsertion(
               of: minute, in: existing, before: marker?.lowerBound ?? existing.endIndex, newline: newline
           ) {
            var result = existing
            result.insert(contentsOf: entry + newline, at: point)
            return result
        }

        if let marker {
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

    /// Where an item at `minute` goes among the timestamped lines of the
    /// section it would otherwise end: before the first line later than
    /// it that follows the last line at or before it, so equal times keep
    /// the order they arrived in. Nil when no later line follows, and the
    /// item goes where any capture does.
    ///
    /// The section runs from the last heading before `limit`. Only
    /// top-level items read as timestamped (`- 09:15 …`, `- [x] 09:15 …`);
    /// anything else keeps its place, and an item's indented continuation
    /// lines stay with it because the insertion is always at the start of
    /// a top-level line.
    static func timeOrderedInsertion(
        of minute: Int, in text: String, before limit: String.Index, newline: String
    ) -> String.Index? {
        var stamped: [(start: String.Index, minute: Int)] = []
        for line in captureLines(in: text, before: limit, newline: newline) {
            if line.heading != nil {
                stamped.removeAll()
            } else if let value = line.minute {
                stamped.append((line.range.lowerBound, value))
            }
        }
        let lastAtOrBefore = stamped.lastIndex { $0.minute <= minute }
        let after = stamped[(lastAtOrBefore.map { $0 + 1 } ?? 0)...]
        return after.first { $0.minute > minute }?.start
    }

    /// One line as filing in time order reads it.
    struct CaptureLine {
        /// The line without its break.
        let range: Range<String.Index>
        /// Where the next line starts, or the end of the text.
        let next: String.Index
        let hasBreak: Bool
        /// The line, when it is a heading.
        let heading: Substring?
        /// Minutes past midnight, when it is a top-level timestamped item
        /// (`- 09:15 …`, `- [x] 09:15 …`).
        let minute: Int?
    }

    /// The lines that start before `limit`, read for headings and times.
    ///
    /// A code block's lines are neither: `# comment` in a shell snippet
    /// ended the section, and a list in one took the item inside it.
    /// Opened and closed the way `NoteText.headings` reads them.
    static func captureLines(
        in text: String, before limit: String.Index, newline: String
    ) -> [CaptureLine] {
        var lines: [CaptureLine] = []
        var start = text.startIndex
        var fence: String?
        while start < limit {
            let lineBreak = text.range(of: newline, range: start..<text.endIndex)
            let end = lineBreak?.lowerBound ?? text.endIndex
            let line = text[start..<end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var heading: Substring?
            var minute: Int?
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
            } else if line.range(of: #"^#{1,6}( |$)"#, options: .regularExpression) != nil {
                heading = line
            } else if let found = line.firstMatch(of: #/^- (?:\[[ xX]\] )?(\d{2}):(\d{2})(?: |$)/#) {
                minute = minutes("\(found.1):\(found.2)")
            }
            lines.append(CaptureLine(
                range: start..<end, next: lineBreak?.upperBound ?? text.endIndex,
                hasBreak: lineBreak != nil, heading: heading, minute: minute))
            guard let lineBreak else { break }
            start = lineBreak.upperBound
        }
        return lines
    }

    /// Minutes past midnight for `HH:mm`, or nil.
    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ..< 24).contains(hour), (0 ..< 60).contains(minute) else { return nil }
        return hour * 60 + minute
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
