import Foundation

/// Adding a line to the end of a note, and nothing else.
///
/// Not `InboxCapture`, which is what the inbox and the daily note use: that
/// files a *capture*, under a dated heading and with the time in front of it.
/// That structure is the point of an inbox and wrong everywhere else. Asked to
/// add a sentence to a note about a roof, Heft should add the sentence.
///
/// It only ever appends, so it can run unattended for the same reason the
/// captures can: nothing already written is touched.
public enum NoteAppend {

    public enum Failure: LocalizedError, Sendable {
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case let .missing(path): "There is no note at \(path) to add to."
            }
        }
    }

    @discardableResult
    public static func append(
        _ rawText: String, to relativePath: String, in vaultRoot: URL
    ) throws -> URL {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missing(relativePath)
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return url }

        // Coordinated, because the vault is usually in iCloud Drive and the
        // app may have the same file open.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
            do {
                let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                // A blank line before, so a sentence added to a paragraph does
                // not join it, and exactly one newline after.
                var separator = ""
                if !existing.isEmpty {
                    separator = existing.hasSuffix("\n\n") ? ""
                        : existing.hasSuffix("\n") ? "\n" : "\n\n"
                }
                try (existing + separator + text + "\n").write(
                    to: target, atomically: true, encoding: .utf8
                )
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        VaultContentChangeNotification.post(for: vaultRoot)
        return url
    }
}
