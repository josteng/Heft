import Foundation

/// The last vault opened in Heft is the capture destination used when no
/// window exists to supply one, as with Spotlight and Shortcuts.
public enum CaptureVaultPreference {
    public static let defaultsKey = "dev.stenglein.Heft.vaultPath"

    public static var url: URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum InboxCaptureError: LocalizedError, Sendable {
    case emptyCapture
    case vaultUnavailable
    case inboxIsDirectory

    public var errorDescription: String? {
        switch self {
        case .emptyCapture:
            return "Enter something to add to the inbox."
        case .vaultUnavailable:
            return "The capture vault is no longer available. Open it in Heft and try again."
        case .inboxIsDirectory:
            return "Inbox.md is a folder. Rename it before capturing a note."
        }
    }
}

/// Lets a running Heft process refresh after an App Intent writes into a vault.
/// A distributed notification also keeps this working if intent handling moves
/// into a separate extension process later.
public enum VaultContentChangeNotification {
    public static let name = Notification.Name("dev.stenglein.Heft.vaultContentDidChange")

    public static func post(for vaultRoot: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: vaultRoot.standardizedFileURL.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

/// Adds low-friction captures to one ordinary Markdown file at the vault root.
///
/// The newest day and newest item are kept first. The file stays intentionally
/// unsurprising so it can be edited, moved, or opened by any Markdown app.
public struct InboxCapture: Sendable {
    public static let filename = "Inbox.md"

    public let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot.standardizedFileURL
    }

    public var url: URL {
        vaultRoot.appendingPathComponent(Self.filename)
    }

    /// Returns Inbox.md, creating a titled empty file when needed.
    @discardableResult
    public func ensureFile() throws -> URL {
        var vaultIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: vaultRoot.path, isDirectory: &vaultIsDirectory
        ), vaultIsDirectory.boolValue else {
            throw InboxCaptureError.vaultUnavailable
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { throw InboxCaptureError.inboxIsDirectory }
            return url
        }

        try "# Inbox\n".write(to: url, atomically: true, encoding: .utf8)
        VaultContentChangeNotification.post(for: vaultRoot)
        return url
    }

    /// Coordinates the whole read–modify–write operation. That matters when a
    /// Spotlight shortcut and a running Heft window capture at nearly the same
    /// time, especially for an iCloud-backed vault.
    @discardableResult
    public func capture(
        _ rawText: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        var vaultIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: vaultRoot.path, isDirectory: &vaultIsDirectory
        ), vaultIsDirectory.boolValue else {
            throw InboxCaptureError.vaultUnavailable
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw InboxCaptureError.inboxIsDirectory
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let exists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                let existing = exists
                    ? try String(contentsOf: coordinatedURL, encoding: .utf8)
                    : ""
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
        VaultContentChangeNotification.post(for: vaultRoot)
        return url
    }

    /// Pure formatter used by the disk writer and deterministic tests.
    public static func contents(
        byCapturing rawText: String,
        in existing: String,
        at date: Date,
        calendar: Calendar = .current
    ) throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InboxCaptureError.emptyCapture }

        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let day = formatted(date, pattern: "yyyy-MM-dd", calendar: calendar)
        let time = formatted(date, pattern: "HH:mm", calendar: calendar)
        let entry = markdownEntry(text, time: time, newline: newline)
        let dayHeading = "## \(day)"

        guard !existing.isEmpty else {
            return "# Inbox\(newline)\(newline)\(dayHeading)\(newline)\(entry)\(newline)"
        }

        if let heading = lineRange(named: dayHeading, in: existing, newline: newline) {
            return prepending(entry, toBodyOf: heading, in: existing, newline: newline)
        }

        let section = "\(dayHeading)\(newline)\(entry)\(newline)\(newline)"
        if let title = firstLineRange(in: existing, newline: newline),
           lineText(title, in: existing) == "# Inbox" {
            let insertion = insertion(afterHeading: title, in: existing, newline: newline)
            return inserting(insertion.prefix + section, at: insertion.index, in: existing)
        }

        // An Inbox.md may predate this feature. Preserve it byte-for-byte and
        // add the new dated section ahead of its existing content.
        return section + existing
    }

    private static func formatted(
        _ date: Date, pattern: String, calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func markdownEntry(
        _ text: String, time: String, newline: String
    ) -> String {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let continuation = lines.dropFirst().map { "  \($0)" }.joined(separator: newline)
        return continuation.isEmpty
            ? "- \(time) \(first)"
            : "- \(time) \(first)\(newline)\(continuation)"
    }

    private static func lineRange(
        named name: String, in text: String, newline: String
    ) -> Range<String.Index>? {
        var start = text.startIndex
        while start < text.endIndex {
            let lineBreak = text.range(of: newline, range: start..<text.endIndex)
            let end = lineBreak?.lowerBound ?? text.endIndex
            let range = start..<end
            if lineText(range, in: text) == name { return range }
            guard let lineBreak else { break }
            start = lineBreak.upperBound
        }
        return nil
    }

    private static func firstLineRange(
        in text: String, newline: String
    ) -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let end = text.range(of: newline)?.lowerBound ?? text.endIndex
        return text.startIndex..<end
    }

    private static func lineText(_ range: Range<String.Index>, in text: String) -> String {
        String(text[range]).trimmingCharacters(in: .newlines)
    }

    /// Returns the start of the heading's body, preserving the blank line
    /// between sections or between the document title and the first section.
    private static func insertion(
        afterHeading heading: Range<String.Index>, in text: String, newline: String
    ) -> (index: String.Index, prefix: String) {
        var point = heading.upperBound
        var consumed = 0
        if text[point...].hasPrefix(newline) {
            point = text.index(point, offsetBy: newline.count)
            consumed += 1
        }
        if text[point...].hasPrefix(newline) {
            point = text.index(point, offsetBy: newline.count)
            consumed += 1
        }
        return (point, String(repeating: newline, count: 2 - consumed))
    }

    /// Prepends an entry directly below a dated heading. Older generated Inbox
    /// files had a blank line here; consume it while inserting so they migrate
    /// naturally on the next capture.
    private static func prepending(
        _ entry: String,
        toBodyOf heading: Range<String.Index>,
        in original: String,
        newline: String
    ) -> String {
        var body = heading.upperBound
        var consumed = 0
        while consumed < 2, original[body...].hasPrefix(newline) {
            body = original.index(body, offsetBy: newline.count)
            consumed += 1
        }

        var result = original
        result.replaceSubrange(
            heading.upperBound..<body,
            with: newline + entry + newline
        )
        return result
    }

    private static func inserting(
        _ addition: String, at index: String.Index, in original: String
    ) -> String {
        var result = original
        result.insert(contentsOf: addition, at: index)
        return result
    }
}
