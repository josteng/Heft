import AppKit
import HeftCore

/// Asking the agent, from the search bar or the right sidebar's Chats: both
/// start and continue the one chat a window has open, with the same context.
extension AppModel {
    /// A new chat with `question`, reading in `scope` (the vault when empty).
    func startChat(_ question: String, instruction: String? = nil, scope: String) {
        guard let vaultRoot else { return }
        agent.close()
        agent.ask(
            question, instruction: agentContext(instruction ?? question),
            files: AgentFiles.paths(in: question), vaultRoot: vaultRoot, scope: scope
        )
        if let id = agent.chat?.id { recordChatUse(id) }
    }

    /// `text` as the next turn of the open chat. False when nothing was
    /// sent: no vault, nothing written, or an answer still coming.
    @discardableResult
    func replyToChat(_ text: String, newChatScope: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let vaultRoot, !trimmed.isEmpty, !agent.isRunning else { return false }
        agent.ask(
            text, instruction: agentContext(text), files: AgentFiles.paths(in: text),
            vaultRoot: vaultRoot, scope: agent.chat?.scope ?? newChatScope
        )
        return true
    }

    /// The question with what the reader is looking at, so "what is this
    /// note about?" has an answer: the open note and any selection in it,
    /// as they are when the question is asked, since a reply can come from
    /// another note.
    func agentContext(_ text: String) -> String {
        var lines: [String] = []
        if let note = current {
            lines.append("The reader has \(note.relativePath) open.")
            if let selected = Self.editorSelection(), !selected.isEmpty {
                let shown = selected.count > 2000 ? String(selected.prefix(2000)) + "…" : selected
                lines.append("They have selected this text in it:\n\"\"\"\n\(shown)\n\"\"\"")
            }
        }
        // Today's note, so "today", "this week" and "add to my daily note"
        // need no search to find where the reader keeps it.
        if let vaultRoot {
            let daily = DailyNotes(vaultRoot: vaultRoot, settings: settings)
            let today = Date()
            let path = daily.relativePath(for: today)
            lines.append(daily.exists(for: today)
                ? "Today's daily note is \(path)."
                : "Today's daily note would be \(path); it does not exist yet.")
        }
        lines.append("Today is \(Date().formatted(.iso8601.year().month().day())).")
        return "(Context from Heft, not part of the question: " + lines.joined(separator: " ") + ")\n\n" + text
    }

    /// What is selected in the editor, which keeps its selection while the
    /// bar's sheet or the sidebar's field has the keyboard.
    private static func editorSelection() -> String? {
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        guard let content = window?.contentView, let editor = findEditor(in: content) else { return nil }
        let range = editor.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length else { return nil }
        return (editor.string as NSString).substring(with: range)
    }

    private static func findEditor(in view: NSView) -> HeftTextKit2View? {
        if let editor = view as? HeftTextKit2View { return editor }
        for child in view.subviews {
            if let found = findEditor(in: child) { return found }
        }
        return nil
    }
}
