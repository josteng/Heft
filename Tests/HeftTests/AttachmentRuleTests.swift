import Foundation
import HeftCore
import Testing

/// Where a pasted file goes. The rules are ordered and the first that answers
/// wins, so most of what matters is which ones decline.
@Suite("Attachment rules")
struct AttachmentRuleTests {

    private func context(
        noteFolder: String = "Daily Notes",
        obsidian: String = "",
        learned: String? = nil,
        folders: Set<String> = []
    ) -> AttachmentRules.Context {
        AttachmentRules.Context(
            noteFolder: noteFolder, obsidianSetting: obsidian, learned: learned,
            folderExists: { folders.contains($0) }
        )
    }

    @Test("The vault root always answers, so a list ending in it cannot fail")
    func rootAlwaysAnswers() {
        let rules = AttachmentRules(rules: [.named("Attachments"), .vaultRoot])
        #expect(rules.destination(in: context()).folder == "")
    }

    /// The default order with nothing configured is what Obsidian would have
    /// done: its own setting, then the vault root, with the learned answer in
    /// between because it costs nothing when there is nothing to learn.
    @Test("Nothing configured behaves as Obsidian does")
    func standardOrderMatchesObsidian() {
        #expect(AttachmentRules.standard.destination(in: context()).folder == "")
        #expect(
            AttachmentRules.standard.destination(in: context(obsidian: "Files")).folder == "Files"
        )
    }

    @Test("A learned answer is used, and passed over when there is none")
    func learnedAnswers() {
        let rules = AttachmentRules(rules: [.learned, .vaultRoot])
        #expect(rules.destination(in: context(learned: "Books/Covers")).folder
            == "Books/Covers")
        #expect(rules.destination(in: context()).rule == .vaultRoot)
    }

    /// The rule that lets one setting cover three differently named folders is
    /// not the named one; it is the order. An explicit name in front of the
    /// learned rule is how a reader overrules the vault's own habit.
    @Test("An explicit name outranks what the folder does")
    func explicitNameWinsWhenFirst() {
        let folders: Set<String> = ["Attachments", "Thesis/Thesis_Figures"]
        let here = context(
            noteFolder: "Thesis/Meetings",
            learned: "Thesis/Thesis_Figures",
            folders: folders
        )
        #expect(AttachmentRules(rules: [.named("Attachments"), .learned, .vaultRoot])
            .destination(in: here).folder == "Attachments")
        #expect(AttachmentRules(rules: [.learned, .named("Attachments"), .vaultRoot])
            .destination(in: here).folder == "Thesis/Thesis_Figures")
    }

    /// Nearest walking *up*, so a vault with one assets folder for a project
    /// keeps using it from every note under that project rather than growing a
    /// second one beside each.
    @Test("A named folder is found walking up from the note")
    func namedWalksUp() {
        let rules = AttachmentRules(rules: [.named("assets"), .vaultRoot])
        let deep = context(
            noteFolder: "Projects/Heft/Notes", folders: ["Projects/Heft/assets"]
        )
        #expect(rules.destination(in: deep).folder == "Projects/Heft/assets")
        // The closer one wins when there is one.
        let closer = context(
            noteFolder: "Projects/Heft/Notes",
            folders: ["Projects/Heft/assets", "Projects/Heft/Notes/assets"]
        )
        #expect(rules.destination(in: closer).folder == "Projects/Heft/Notes/assets")
        // And nothing is invented when none exists.
        #expect(rules.destination(in: context(noteFolder: "Projects/Heft/Notes")).rule == .vaultRoot)
    }

    /// Obsidian's own `./Name` means "subfolder under current folder", and its
    /// reading makes one beside every note. Preferring an existing one above it
    /// is the difference between one assets folder and a dozen.
    @Test("Obsidian's ./Name prefers an existing folder above the note")
    func obsidianRelativePrefersExisting() {
        let rules = AttachmentRules(rules: [.obsidianSetting, .vaultRoot])
        let existing = context(
            noteFolder: "Projects/Heft/Notes", obsidian: "./assets",
            folders: ["Projects/Heft/assets"]
        )
        #expect(rules.destination(in: existing).folder == "Projects/Heft/assets")
        // With none anywhere above, it falls back to Obsidian's own reading.
        let fresh = context(noteFolder: "Projects/Heft/Notes", obsidian: "./assets")
        #expect(rules.destination(in: fresh).folder == "Projects/Heft/Notes/assets")
    }

    /// Nothing appears in a vault the reader did not make, except where they
    /// named one folder and meant it.
    @Test("Only a fixed folder may be created")
    func onlyFixedCreates() {
        #expect(AttachmentRules.Rule.fixed("Files").mayCreate)
        for rule in [
            AttachmentRules.Rule.obsidianSetting, .learned, .named("x"),
            .besideTheNote, .vaultRoot,
        ] {
            #expect(!rule.mayCreate, "\(rule.id) must not create a folder")
        }
        let rules = AttachmentRules(rules: [.fixed("Files")])
        let chosen = rules.destination(in: context())
        #expect(chosen.folder == "Files")
        #expect(chosen.needsCreating)
    }

    @Test("A path is the same folder however it is spelled")
    func pathsAreNormalised() {
        let rules = AttachmentRules(rules: [.fixed("/Attachments/")])
        #expect(rules.destination(in: context()).folder == "Attachments")
    }

    /// A settings file is a format, and one written before a rule existed still
    /// has to open.
    @Test("Rules survive a round trip")
    func rulesRoundTrip() throws {
        let rules = AttachmentRules(rules: [
            .obsidianSetting, .learned, .named("Attachemnts"),
            .besideTheNote, .fixed("Media"), .vaultRoot,
        ])
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(AttachmentRules.self, from: data) == rules)
    }
}
