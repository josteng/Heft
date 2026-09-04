import Foundation

/// Where a new note is written.
///
/// It was always beside the note you were reading, which is right when you are
/// working through a folder and wrong for the other common case: a thought
/// that has nowhere to go yet and should land in one known place rather than
/// wherever you happened to be.
public enum NewNoteLocation: Codable, Equatable, Sendable, Hashable {
    /// Beside the open note, falling back to the focused folder and then the
    /// vault root. What Heft has always done.
    case besideTheOpenNote
    /// The folder this window is focused on, or the vault root when it is not
    /// focused on one. Different from the case above whenever the open note is
    /// in a subfolder of the focus.
    case focusedFolder
    case vaultRoot
    /// One folder, vault-relative. Created on demand: naming a folder is
    /// asking for notes to go there, unlike a startup path, which is a request
    /// to *open* something.
    case folder(String)

    /// The vault-relative folder a new note goes in.
    ///
    /// Pure, and takes every fallback as an argument, so the rule can be shown
    /// in a settings pane and asked for in a test without a window.
    ///
    /// - Parameters:
    ///   - openNoteFolder: folder of the note on screen, vault-relative, or nil.
    ///   - focus: the window's focused folder, vault-relative, or nil.
    public func directory(openNoteFolder: String?, focus: String?) -> String {
        switch self {
        case .besideTheOpenNote:
            openNoteFolder ?? focus ?? ""
        case .focusedFolder:
            focus ?? ""
        case .vaultRoot:
            ""
        case .folder(let path):
            Self.normalised(path).isEmpty ? (focus ?? "") : Self.normalised(path)
        }
    }

    /// A folder as the settings field should store it: no leading or trailing
    /// slashes, no `.` or `..`, so it cannot name anything outside the vault.
    public static func normalised(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    /// Only a named folder may be made on demand; every other case names
    /// somewhere that already exists.
    public var mayCreate: Bool {
        if case .folder = self { return true }
        return false
    }

    // MARK: - Storage

    /// Hand-written so the stored form is one readable string rather than a
    /// tagged union, and so a value written by a later version decodes to the
    /// default instead of failing the whole settings file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(stored: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }

    public init(stored raw: String) {
        switch raw {
        case "beside": self = .besideTheOpenNote
        case "focus": self = .focusedFolder
        case "root": self = .vaultRoot
        default:
            let path = raw.hasPrefix("folder:") ? String(raw.dropFirst(7)) : ""
            self = path.isEmpty ? .besideTheOpenNote : .folder(path)
        }
    }

    public var stored: String {
        switch self {
        case .besideTheOpenNote: "beside"
        case .focusedFolder: "focus"
        case .vaultRoot: "root"
        case .folder(let path): "folder:\(path)"
        }
    }
}

/// When a window opens its calendar.
///
/// The default is the behaviour Heft has always had, and it is scope-aware on
/// purpose: a window focused on `Projects/` has no business showing a calendar
/// for daily notes kept in `Journal/`, while the same vault unfocused does.
/// The two explicit answers are not scope-aware, because someone who says
/// "always" has answered that question themselves.
public enum CalendarVisibility: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Today's behaviour: open when this window can actually reach the daily
    /// notes, and remember what the window was last left showing.
    case whenDailyNotesAreInScope
    case always
    case never

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whenDailyNotesAreInScope: "When daily notes are in this window"
        case .always: "Always"
        case .never: "Never"
        }
    }

    /// Whether a window should open with the calendar showing.
    ///
    /// - Parameter remembered: what this window was last left showing, from a
    ///   restored workspace. Honoured only by the default, because the other
    ///   two are a standing instruction and a restored window that disagreed
    ///   would keep overruling it.
    public func isVisible(dailyNotesAreInScope: Bool, remembered: Bool?) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .whenDailyNotesAreInScope: remembered ?? dailyNotesAreInScope
        }
    }
}

/// How consecutive lines of source are read.
///
/// CommonMark says a single newline is a space, so two lines are one
/// paragraph; Obsidian says it is a line break, and matching the vault the
/// notes were written in matters more than matching the spec. A vault answers
/// through `strictLineBreaks` in `.obsidian/app.json` — but a plain folder of
/// Markdown has no `.obsidian` at all, and was stuck with whichever default
/// Heft happened to carry.
public enum LineBreakStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whatever `.obsidian/app.json` says, and Obsidian's own default when it
    /// says nothing. The default here, so an upgrade cannot change how anyone's
    /// vault reads.
    case followTheVault
    /// A newline is a line break: each source line renders where it is.
    case aLineEach
    /// A newline is a space: consecutive lines are one paragraph, as
    /// CommonMark says.
    case oneParagraph

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followTheVault: "Follow the vault"
        case .aLineEach: "A line each"
        case .oneParagraph: "One paragraph"
        }
    }

    /// The effective `strictLineBreaks`, given what the vault asked for.
    public func strictLineBreaks(vaultSetting: Bool) -> Bool {
        switch self {
        case .followTheVault: vaultSetting
        case .aLineEach: false
        case .oneParagraph: true
        }
    }
}
