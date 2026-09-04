import Foundation

/// Every attachment rule, in the reader's order, each switched on or off.
///
/// A fixed set rather than a list things are added to. The first design let
/// rules be added freely and it broke in two ways at once: two copies of a rule
/// were indistinguishable, so the list scrambled its own row order, and a
/// menu of things to add asked the reader to understand every rule before
/// choosing one. Here each rule exists exactly once, always, and the question
/// is only whether it is on and where it sits.
public struct AttachmentPlan: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var choice: AttachmentRules.Choice
        /// The folder name for the two rules that take one. Kept even while the
        /// rule is switched off, so turning it back on does not lose what was
        /// typed.
        public var folder: String
        public var isEnabled: Bool

        /// The rule's kind, never its text. Identity that changed as a folder
        /// name was typed would rebuild the row on every keystroke and take the
        /// keyboard focus with it.
        public var id: String { choice.rawValue }

        public init(choice: AttachmentRules.Choice, folder: String = "", isEnabled: Bool = false) {
            self.choice = choice
            self.folder = folder
            self.isEnabled = isEnabled
        }
    }

    public var entries: [Entry]

    /// What a vault does with nothing configured: honour Obsidian's setting if
    /// it has one, otherwise learn from the vault, otherwise the vault root —
    /// which is what Obsidian would have done anyway.
    public static let standard = AttachmentPlan(entries: [
        Entry(choice: .obsidian, isEnabled: true),
        Entry(choice: .learned, isEnabled: true),
        Entry(choice: .named, folder: "Attachments", isEnabled: true),
        Entry(choice: .fixed, folder: "Attachments"),
        Entry(choice: .besideTheNote),
    ])

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Where the reader's plan is kept, and how to read it back.
    ///
    /// Here rather than only in the settings object, so the command line can
    /// answer with the same rules the editor pastes with: `heft attachment`
    /// would otherwise be reporting a different vault's behaviour than the one
    /// the reader sees. Under `swift run` that is the standard plan, because a
    /// development build has its own defaults domain — the same caveat
    /// `files --by-use` carries.
    public static let defaultsKey = "dev.stenglein.Heft.attachmentPlan"

    public static func stored(in defaults: UserDefaults) -> AttachmentPlan {
        // An unreadable or absent setting means the standard plan, not an
        // empty one: a plan with no rules would send every attachment to the
        // vault root and look like a decision somebody made.
        guard let data = defaults.data(forKey: defaultsKey),
              let plan = try? JSONDecoder().decode(AttachmentPlan.self, from: data),
              !plan.entries.isEmpty
        else { return .standard }
        return plan
    }

    /// A stored plan is merged with the full set rather than trusted whole, so
    /// a rule added in a later version arrives switched off at the end instead
    /// of being missing from every plan written before it existed. Same lesson
    /// as `TypingSettings`: a settings file is a format, and it has to tolerate
    /// being older than the code reading it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        // Nothing stored means the standard plan, not the whole set switched
        // off. Merging into an empty list gives every rule, all disabled, which
        // resolves to the vault root for everything and looks like a decision
        // somebody made.
        guard !stored.isEmpty else {
            entries = Self.standard.entries
            return
        }
        var merged = stored.filter { entry in
            AttachmentRules.Choice.allCases.contains(entry.choice)
        }
        for standard in Self.standard.entries where !merged.contains(where: { $0.id == standard.id }) {
            merged.append(Entry(choice: standard.choice, folder: standard.folder))
        }
        entries = merged.isEmpty ? Self.standard.entries : merged
    }

    /// The rules to actually resolve with: the switched-on ones, in order.
    ///
    /// The vault root is not among them and is not a row. `destination(in:)`
    /// falls back to it on its own, so it is a fact to state once rather than a
    /// rule to place, which is what made rows below it read as broken.
    public var rules: AttachmentRules {
        AttachmentRules(rules: entries.filter(\.isEnabled).flatMap(rules(for:)))
    }

    private func rules(for entry: Entry) -> [AttachmentRules.Rule] {
        switch entry.choice {
        case .learned: [.learned]
        case .besideTheNote: [.besideTheNote]
        case .obsidian: [.obsidianSetting]
        case .fixed: Self.folders(in: entry.folder).first.map { [.fixed($0)] } ?? []
        // Several names, tried in the order they were written, because one
        // vault spells the same idea `Attachments`, `Attachemnts` and
        // `Assets` in different corners.
        case .named: Self.folders(in: entry.folder).map { .named($0) }
        case .vaultRoot: []
        }
    }

    /// `Attachments, Assets` as two folder names, blanks discarded.
    public static func folders(in text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether the entry at `index` can ever be reached.
    ///
    /// Some rules cannot decline — one fixed folder, or the note's own — so
    /// anything under an enabled one is dead. Saying so beats leaving a row
    /// that quietly does nothing.
    public func isReachable(_ index: Int) -> Bool {
        for earlier in entries.prefix(index) where earlier.isEnabled && alwaysAnswers(earlier) {
            return false
        }
        return true
    }

    private func alwaysAnswers(_ entry: Entry) -> Bool {
        switch entry.choice {
        case .besideTheNote: true
        case .fixed: !Self.folders(in: entry.folder).isEmpty
        default: false
        }
    }
}
