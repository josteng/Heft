import AppKit

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
}
