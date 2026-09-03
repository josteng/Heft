import Foundation

/// Everything a vault operation needs from the application around it.
///
/// `AppModel` used to build an `NSAlert` or an `NSOpenPanel` in the middle of
/// renaming, creating and deleting, which made every one of those paths
/// unreachable without a running application: a modal panel has no answer to
/// give a test, and `runModal` blocks. So the checks around them — that a
/// folder is inside the vault, that a name does not collide, that the
/// destination is not the folder itself — were verified by reading them.
///
/// Behind this protocol they can be driven instead. `AppKitHost` is what
/// ships; `ScriptedHost` in the test target answers from a queue and
/// records what it was asked, which is how the operations are now tested
/// without a window.
///
/// It is deliberately small and deliberately about what the vault *needs*
/// rather than about panels. "Choose a folder" is one entry, not three, even
/// though the three call sites pass different prompts.
///
/// The last three are not questions, and they are here for the same reason:
/// `NSWorkspace.open` in a test does not block, it launches Preview.
@MainActor
protocol VaultHost {

    /// A single-field name prompt. Nil when cancelled or left empty.
    func name(title: String, message: String, initial: String, confirm: String) -> String?

    /// A path prompt, wider than a name field. Nil when cancelled or empty.
    func path(title: String, message: String) -> String?

    /// A yes/no. `destructive` marks the confirming button, which is what
    /// makes it red and what stops Return from being the safe answer.
    func confirm(title: String, message: String, confirm: String, destructive: Bool) -> Bool

    /// Choose a folder. Nil when cancelled.
    func chooseFolder(prompt: String, message: String, startingAt: URL?) -> URL?

    /// Where to write an exported PDF, with the export options shown inside
    /// the panel. Nil when cancelled.
    ///
    /// The options ride along rather than being asked for separately because
    /// where the file goes and what it looks like are one decision.
    func exportDestination(suggestedName: String, startingAt: URL?) -> URL?

    /// Hands a file to whichever application owns it. Heft opens markdown
    /// itself; a PDF or an image is the system's business.
    func openExternally(_ url: URL)

    /// Shows a file in the Finder.
    func revealInFinder(_ url: URL)

    /// Puts a string on the general pasteboard.
    func copyToPasteboard(_ string: String)
}

extension VaultHost {
    func confirm(title: String, message: String, confirm: String) -> Bool {
        self.confirm(title: title, message: message, confirm: confirm, destructive: false)
    }
}
