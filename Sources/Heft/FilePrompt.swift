import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Modal prompts for the file operations in the sidebar.
///
/// These are `NSAlert` rather than SwiftUI sheets on purpose. A sheet would
/// need presentation state threaded through every tree row and back up to the
/// window, for dialogs that are modal, momentary and native anyway.
enum FilePrompt {

    /// A single-field name prompt. Returns nil when cancelled.
    static func name(title: String, message: String, initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        // Without this the buttons take focus and the name has to be clicked
        // into before it can be typed. Focusing a text field also selects its
        // contents, so a suggested name can be replaced by typing or accepted
        // with Return.
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? nil : entered
    }

    /// A path prompt. Wider than the name field, because a path is long and
    /// being unable to see what was pasted is most of what makes one hard to
    /// correct. Returns nil when cancelled or left empty.
    static func path(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "/path/to/a/note or folder"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? nil : entered
    }

    /// Choose a folder. All three callers want the same panel with a
    /// different sentence on it.
    static func folder(prompt: String, message: String, startingAt: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let startingAt { panel.directoryURL = startingAt }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func confirm(
        title: String, message: String, confirm: String, destructive: Bool = false
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        let action = alert.addButton(withTitle: confirm)
        if destructive { action.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Where to write an exported PDF.
    ///
    /// The options ride inside the save panel rather than in a sheet of their
    /// own: where the file goes and what it looks like are one decision, and
    /// asking twice for one export is a step too many.
    static func exportDestination(suggestedName: String, startingAt: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export as PDF"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        // Wherever the last export went, if it is still there. Exports tend
        // to leave the vault — a Downloads folder, a shared drive — so
        // beside the note is a poor second guess, and it was the only one.
        panel.directoryURL = startingAt

        let accessory = NSHostingView(rootView: PDFExportAccessory())
        // Taller than it was: the colour row was added.
        accessory.frame = NSRect(x: 0, y: 0, width: 460, height: 226)
        panel.accessoryView = accessory
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// What ships: every question and every hand-off goes to AppKit.
@MainActor
struct AppKitHost: VaultHost {

    /// Nonisolated so it can be a default argument. `AppModel.init` is
    /// main-actor isolated but its default expressions are evaluated outside
    /// that isolation, and this type holds nothing to isolate.
    nonisolated init() {}

    func name(title: String, message: String, initial: String, confirm: String) -> String? {
        FilePrompt.name(title: title, message: message, initial: initial, confirm: confirm)
    }

    func path(title: String, message: String) -> String? {
        FilePrompt.path(title: title, message: message)
    }

    func confirm(title: String, message: String, confirm: String, destructive: Bool) -> Bool {
        FilePrompt.confirm(
            title: title, message: message, confirm: confirm, destructive: destructive
        )
    }

    func chooseFolder(prompt: String, message: String, startingAt: URL?) -> URL? {
        FilePrompt.folder(prompt: prompt, message: message, startingAt: startingAt)
    }

    func exportDestination(suggestedName: String, startingAt: URL?) -> URL? {
        FilePrompt.exportDestination(suggestedName: suggestedName, startingAt: startingAt)
    }

    func openExternally(_ url: URL) { NSWorkspace.shared.open(url) }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
