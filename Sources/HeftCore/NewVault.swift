import Foundation

/// Making a vault, as opposed to opening one that already exists.
///
/// A vault is a folder of Markdown files and nothing else, so this is a very
/// short feature: make the folder, put one note in it, hand back the URL. It
/// is here rather than in the app because the only interesting parts are the
/// refusals and the note, and neither needs a window to decide.
///
/// The starter note is not a template and nothing reads it back. It exists
/// because a brand new vault is an empty sidebar and a blank editor, which
/// says nothing about what the app does, and because the first thing anyone
/// should learn is that deleting it costs nothing.
public enum NewVault {

    /// The one note a new vault starts with.
    public static let starterNoteName = "Start Here.md"

    /// Where a vault named `entered` would go inside `parent`.
    ///
    /// Pure, and takes the existence test as a closure, for the same reason
    /// `VaultOperations` does: the refusals are the part worth testing and
    /// they should not need a temporary directory to reach. Reuses that type's
    /// refusals so the sentence the reader gets is written once.
    public static func plan(
        named entered: String, in parent: URL, exists: (URL) -> Bool
    ) -> Result<URL, VaultOperations.Refusal> {
        let cleaned = VaultOperations.sanitise(entered)
        guard !cleaned.isEmpty else { return .failure(.emptyName) }
        let target = parent.appendingPathComponent(cleaned, isDirectory: true)
        guard !exists(target) else { return .failure(.alreadyExists(name: cleaned)) }
        return .success(target)
    }

    /// Makes the folder and writes the starter note into it.
    ///
    /// `withIntermediateDirectories: false` on purpose: the parent was chosen
    /// in a panel and so is known to exist, and building a path that was not
    /// asked for is how a typo becomes a folder tree.
    @discardableResult
    public static func create(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let note = root.appendingPathComponent(starterNoteName)
        try starterNote(for: root.lastPathComponent).write(
            to: note, atomically: true, encoding: .utf8
        )
        return note
    }

    /// The note's first words.
    ///
    /// "Welcome to Notes." reads as the name of a product, because a bare
    /// name in that position is a product's name in nearly every app that
    /// says it. Naming the thing puts it back: this is a vault, and that one
    /// is called Notes. A vault already named after itself is left alone
    /// rather than welcomed to the Vault vault.
    public static func welcome(to vaultName: String) -> String {
        vaultName.lowercased().hasSuffix("vault")
            ? "Welcome to \(vaultName)."
            : "Welcome to the \(vaultName) vault."
    }

    /// The note's text. Deliberately short, and deliberately made of things
    /// the reader can do on the note itself rather than a description of them.
    public static func starterNote(for vaultName: String) -> String {
        """
        # Start here
        \(welcome(to: vaultName)) It is an ordinary folder, and every note in \
        it is a plain Markdown file. Open them in anything, sync them with \
        anything, move them out whenever you like. There is no database and no \
        format of Heft's own.

        ## Writing
        Markup hides as the caret leaves it and comes back as it returns, so \
        the note reads as a document while still being exactly the text you \
        typed. Click into this **bold** word to watch it happen.

        - [ ] Press Cmd-L on this line to tick it off
        - [ ] Type `[[` anywhere to link to another note
        - [ ] Press Cmd-P for the command palette, which lists everything else

        ## Getting around
        | To do this | Press |
        | --- | --- |
        | Quick open | Cmd-O |
        | Search the vault | Shift-Cmd-F |
        | Today's daily note | Shift-Cmd-T |
        | Show the sidebar | Shift-Cmd-S |

        ## Your coding agent
        Heft has no agent of its own. You bring the one you already use: \
        open a terminal in this folder and start it there, the way you would \
        in a code repository.

        File > Set Up Agent Access writes the guide that teaches it the rest. \
        From then on it has a `heft` command that reads your notes and \
        resolves links, headings and tags, and its edits arrive as proposals \
        that wait for you to accept or reject them, all at once or change by \
        change.

        Delete this note whenever you like. Nothing depends on it.

        """
    }
}
