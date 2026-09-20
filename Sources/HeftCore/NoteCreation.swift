import Foundation

/// Making a note from a name and a body, for a caller with no window.
///
/// The app makes notes through `AppModel`, which needs a sidebar, a selection
/// and somewhere to put the caret. Siri and the capture extension have none of
/// those, so the part that touches the disk lives here.
///
/// It only ever adds. A name already taken gets a numbered sibling rather than
/// being overwritten, which is the same rule the sidebar's New Note follows
/// and the reason this can run unattended: every other write in Heft that
/// changes a line already on disk is a proposal.
public enum NoteCreation {

    public enum Failure: LocalizedError, Sendable {
        case vaultUnavailable
        case unusableName(String)
        case folderUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .vaultUnavailable:
                "Heft has no vault to write to. Open one, or choose a capture vault in Settings."
            case let .unusableName(name):
                "\(name) is not a name a note can have."
            case let .folderUnavailable(folder):
                "There is no folder called \(folder) in the vault."
            }
        }
    }

    /// Writes a new note and answers where it landed.
    ///
    /// `folder` is vault-relative and must already exist: creating one on the
    /// way would let a misheard word scatter folders through somebody's vault,
    /// and the failure is easy to correct while a stray folder is not.
    @discardableResult
    public static func create(
        named rawName: String,
        body: String? = nil,
        in vaultRoot: URL,
        folder rawFolder: String? = nil,
        location: NewNoteLocation = .current,
        captureFolder: String? = CaptureNoteFolderPreference.folder
    ) throws -> URL {
        // A title arriving from speech is exactly where "../.zshrc" would, and
        // "it only adds" is a property of adding to a note rather than to
        // whatever a path happens to reach. A name is one segment: anything
        // holding a separator is a path, and a path is not a name.
        var stem = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.hasSuffix(".md") { stem = String(stem.dropLast(3)) }
        guard !stem.isEmpty, !stem.contains("/"), stem != ".", stem != ".." else {
            throw Failure.unusableName(rawName)
        }

        // Two kinds of folder, and they get different treatment on purpose.
        //
        // One somebody just said has to exist already: a misheard word should
        // fail rather than scatter folders through a vault. The one configured
        // in Settings ▸ General is created on demand, because naming a folder
        // there is asking for notes to go there, and that is the rule the
        // sidebar's New Note already follows.
        var directory = vaultRoot
        if let rawFolder, !rawFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let cleaned = folderPath(rawFolder) else {
                throw Failure.folderUnavailable(rawFolder)
            }
            directory = vaultRoot.appendingPathComponent(cleaned)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { throw Failure.folderUnavailable(cleaned) }
        } else {
            // The windowless setting first, then the sidebar's. With no open
            // note and no focused folder, two of that one's cases collapse to
            // the vault root, which is why there is a setting for this at all.
            let configured = location.directory(openNoteFolder: nil, focus: nil)
            let chosen = captureFolder ?? configured
            if !chosen.isEmpty {
                directory = vaultRoot.appendingPathComponent(chosen)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
        }

        let name = VaultOperations.uniqueName(base: stem, extension: "md") { candidate in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(candidate).path
            )
        }
        let url = directory.appendingPathComponent(name)

        // A trailing newline, so the next thing appended starts on its own
        // line rather than running into the last word of the body.
        var text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        VaultContentChangeNotification.post(for: vaultRoot)
        // So it can be found again. A note made by voice is the one note whose
        // name you are least likely to remember, and without this it is
        // nowhere in Quick Open's ordering until you have opened it by hand.
        if let made = NoteRef(url: url, vaultRoot: vaultRoot) {
            FrecencyStore.notes(forVaultAt: vaultRoot.path).record(made.relativePath)
        }
        return url
    }

    /// A vault-relative folder, or nil when it names anywhere else.
    ///
    /// Unlike the note-path normaliser this borrows its rules from, it adds no
    /// extension: a folder is not a file.
    private static func folderPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return parts.joined(separator: "/")
    }
}

/// Where a note made without a window is written.
///
/// Its own setting rather than `NewNoteLocation`, which answers the same
/// question for the sidebar. Two of that one's four cases are "beside the open
/// note" and "the focused folder", and Siri has neither, so both collapse to
/// the vault root: not a decision, a fallback. A line arriving from Siri or a
/// shortcut should land somewhere the reader chose once, the way a captured
/// line lands in the inbox note.
///
/// Empty means the vault root. Vault-relative, and created on first use, since
/// naming a folder here is a promise about where things go.
public enum CaptureNoteFolderPreference {
    public static let defaultsKey = "dev.stenglein.Heft.captureNoteFolder"

    public static var folder: String? { folder(in: HeftDefaults.shared) }

    public static func folder(in defaults: UserDefaults) -> String? {
        let raw = defaults.string(forKey: defaultsKey) ?? ""
        let cleaned = NewNoteLocation.normalised(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func set(_ raw: String, in defaults: UserDefaults = HeftDefaults.shared) {
        let cleaned = NewNoteLocation.normalised(raw)
        if cleaned.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(cleaned, forKey: defaultsKey)
        }
    }
}
