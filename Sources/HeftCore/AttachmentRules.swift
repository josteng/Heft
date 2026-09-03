import Foundation

/// Where a pasted or dropped file should be written, as an ordered list of
/// rules tried until one answers.
///
/// A single configured folder name cannot describe a real vault. One vault
/// measured here keeps attachments in `Thesis_Figures`, `Covers`
/// and `Attachemnts` — three names, one of them a misspelling — so a setting
/// naming *the* attachment folder would be wrong in two places out of three,
/// and a built-in list of accepted spellings would be guessing at the reader's
/// vocabulary forever.
///
/// So the default rule names no folder at all: it asks where the notes in this
/// part of the vault already put theirs. Everything else is there to be put in
/// front of it when the answer should not be learned.
public struct AttachmentRules: Codable, Equatable, Sendable {

    public enum Rule: Codable, Equatable, Sendable, Identifiable {
        /// Whatever `.obsidian/app.json` says, so a vault configured in
        /// Obsidian keeps behaving as it does there.
        case obsidianSetting
        /// Where the notes in this folder already keep their attachments.
        case learned
        /// The nearest existing folder of this name, walking up from the note.
        case named(String)
        /// The note's own folder.
        case besideTheNote
        /// One fixed folder, relative to the vault root.
        case fixed(String)
        /// The vault root, which is Obsidian's own default and always answers.
        case vaultRoot

        public var id: String {
            switch self {
            case .obsidianSetting: "obsidian"
            case .learned: "learned"
            case .named(let name): "named:\(name)"
            case .besideTheNote: "beside"
            case .fixed(let path): "fixed:\(path)"
            case .vaultRoot: "root"
            }
        }

        /// Only a fixed folder may be created. Every other rule reuses a folder
        /// that is already there or passes, so nothing appears in a vault that
        /// the reader did not make themselves.
        public var mayCreate: Bool {
            if case .fixed = self { return true }
            return false
        }

        public var isEditable: Bool {
            switch self {
            case .named, .fixed: true
            default: false
            }
        }
    }

    public var rules: [Rule]

    /// What a vault does with nothing configured: honour Obsidian's setting if
    /// there is one, otherwise learn, otherwise the vault root — which is what
    /// Obsidian would have done anyway.
    public static let standard = AttachmentRules(rules: [
        .obsidianSetting, .learned, .vaultRoot,
    ])

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// The one question a reader is actually asked: where should attachments
    /// go? Each answer is a short rule list, so the engine above stays as it is
    /// and nothing has to be ordered, numbered or reasoned about on screen.
    ///
    /// The list was the first design and it was wrong. It put the mechanism in
    /// front of the question: which end is first, what "no answer" means, why a
    /// row is never reached, what happens when the same rule is added twice.
    /// None of that is a thing to think about before pasting a screenshot.
    public enum Choice: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Where the notes nearby already keep theirs.
        case learned
        /// The nearest folder of a given name, searching up from the note.
        case named
        /// One folder for the whole vault.
        case fixed
        /// The note's own folder.
        case besideTheNote
        /// The top of the vault, which is Obsidian's default.
        case vaultRoot
        /// Whatever this vault's Obsidian settings say.
        case obsidian

        public var id: String { rawValue }
        /// Whether the choice needs a folder name written next to it.
        public var needsName: Bool { self == .named || self == .fixed }
    }

    /// The rules a choice stands for.
    ///
    /// Everything except a fixed folder ends at the vault root, so a stored
    /// list reads as what it does. That trailing rule is explicitness rather
    /// than behaviour — `destination(in:)` falls back to the root by itself,
    /// and removing these passes every test — but a settings file is read by
    /// people, and one saying only `named` invites the question this answers.
    public static func rules(for choice: Choice, folder: String) -> AttachmentRules {
        switch choice {
        case .learned: AttachmentRules(rules: [.learned, .vaultRoot])
        case .named: AttachmentRules(rules: [.named(folder), .vaultRoot])
        case .fixed: AttachmentRules(rules: [.fixed(folder)])
        case .besideTheNote: AttachmentRules(rules: [.besideTheNote])
        case .vaultRoot: AttachmentRules(rules: [.vaultRoot])
        case .obsidian: AttachmentRules(rules: [.obsidianSetting, .vaultRoot])
        }
    }

    /// The choice a stored list stands for, so the pane can show what is set.
    /// Only the first rule is consulted: the rest are the fallback the choice
    /// itself implies.
    public var choice: Choice {
        switch rules.first {
        case .learned: .learned
        case .named: .named
        case .fixed: .fixed
        case .besideTheNote: .besideTheNote
        case .obsidianSetting: .obsidian
        default: .vaultRoot
        }
    }

    /// The folder name written beside a choice that needs one.
    public var folderName: String {
        switch rules.first {
        case .named(let name): name
        case .fixed(let path): path
        default: ""
        }
    }

    /// Everything the resolver needs to know about the vault, so that resolving
    /// stays pure and can be shown in a settings pane before anything is written.
    public struct Context {
        /// Folder of the note being pasted into, relative to the vault root.
        public let noteFolder: String
        /// `attachmentFolderPath` from `.obsidian/app.json`.
        public let obsidianSetting: String
        /// Where notes near `noteFolder` already keep attachments.
        public let learned: String?
        /// Whether a folder exists at this vault-relative path.
        public let folderExists: (String) -> Bool

        public init(
            noteFolder: String, obsidianSetting: String, learned: String?,
            folderExists: @escaping (String) -> Bool
        ) {
            self.noteFolder = noteFolder
            self.obsidianSetting = obsidianSetting
            self.learned = learned
            self.folderExists = folderExists
        }
    }

    /// A folder, vault-relative, and the rule that chose it.
    public struct Destination: Equatable {
        public let folder: String
        public let rule: Rule
        /// Whether the folder has to be made first.
        public var needsCreating: Bool
    }

    /// The first rule that answers. The vault root always does, so a list that
    /// ends with it can never fail; one that does not may, and the caller falls
    /// back to the root itself.
    public func destination(in context: Context) -> Destination {
        for rule in rules {
            guard let folder = resolve(rule, in: context) else { continue }
            return Destination(
                folder: folder,
                rule: rule,
                needsCreating: !folder.isEmpty && !context.folderExists(folder)
            )
        }
        return Destination(folder: "", rule: .vaultRoot, needsCreating: false)
    }

    private func resolve(_ rule: Rule, in context: Context) -> String? {
        switch rule {
        case .obsidianSetting:
            let path = context.obsidianSetting.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            // `./Name` is Obsidian's "subfolder under current folder". Its own
            // reading makes one beside every note; preferring an existing one
            // above it means a vault with `Projects/Heft/assets` keeps using
            // that from `Projects/Heft/Notes` rather than growing a second.
            guard path.hasPrefix("./") else { return normalised(path) }
            let sub = String(path.dropFirst(2))
            guard !sub.isEmpty else { return context.noteFolder }
            return nearest(named: sub, in: context)
                ?? join(context.noteFolder, sub)

        case .learned:
            return context.learned

        case .named(let name):
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return nearest(named: name, in: context)

        case .besideTheNote:
            return context.noteFolder

        case .fixed(let path):
            let path = normalised(path)
            return path.isEmpty ? nil : path

        case .vaultRoot:
            return ""
        }
    }

    /// The closest existing folder of that name at or above the note, never
    /// leaving the vault.
    private func nearest(named name: String, in context: Context) -> String? {
        var level = context.noteFolder
        while true {
            let candidate = join(level, name)
            if context.folderExists(candidate) { return candidate }
            if level.isEmpty { return nil }
            guard let slash = level.lastIndex(of: "/") else { level = ""; continue }
            level = String(level[level.startIndex..<slash])
        }
    }

    private func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// A vault-relative path with no leading, trailing or doubled slashes, so
    /// `/Attachments/` and `Attachments` are the same folder.
    private func normalised(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}
