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
    /// - Parameter suggestFrom: a note to suggest names from, under the
    ///   field, while renaming it.
    @MainActor
    static func name(
        title: String, message: String, initial: String, confirm: String, suggestFrom: URL? = nil
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        let suggesting = suggestFrom.flatMap { GeneralSettings.shared.suggestsNames ? $0 : nil }
            .flatMap { OnDeviceModel.unavailableReason == nil ? $0 : nil }
        if let suggesting {
            alert.accessoryView = SuggestedNamesPanel(field: field, note: suggesting, current: initial)
        } else {
            alert.accessoryView = field
        }
        // Without this the buttons take focus and the name has to be clicked
        // into before it can be typed. Focusing a text field also selects its
        // contents, so a suggested name can be replaced by typing or accepted
        // with Return.
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
struct AppKitHost: VaultHost, SuggestingNames {

    /// Nonisolated so it can be a default argument. `AppModel.init` is
    /// main-actor isolated but its default expressions are evaluated outside
    /// that isolation, and this type holds nothing to isolate.
    nonisolated init() {}

    func name(title: String, message: String, initial: String, confirm: String) -> String? {
        FilePrompt.name(title: title, message: message, initial: initial, confirm: confirm)
    }

    func suggestingName(title: String, message: String, initial: String, confirm: String, from note: URL?) -> String? {
        FilePrompt.name(title: title, message: message, initial: initial, confirm: confirm, suggestFrom: note)
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

    func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }

    func filesOnPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let read = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options)
        return (read as? [URL]) ?? []
    }
}

/// The rename prompt's field with names suggested under it, as buttons that
/// fill it in. Room for them is kept from the start, so the alert does not
/// change size when they arrive; until then it says it is suggesting.
private final class SuggestedNamesPanel: NSStackView {
    private let field: NSTextField
    private let list = NSStackView()
    private let waiting = NSTextField(labelWithString: "Suggesting names…")
    private var task: Task<Void, Never>?

    init(field: NSTextField, note: URL, current: String) {
        self.field = field
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 24 + 8 + 16 + 3 * 22))
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: "Suggested")
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        waiting.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        waiting.textColor = .tertiaryLabelColor
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.addArrangedSubview(waiting)
        addArrangedSubview(field)
        addArrangedSubview(heading)
        addArrangedSubview(list)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        // Runs while the alert is up: its modal loop still serves the main
        // queue, which is where the names arrive.
        task = Task { @MainActor [weak self] in
            let text = await Task.detached { (try? String(contentsOf: note, encoding: .utf8)) ?? "" }.value
            let names = await NameSuggester.suggestions(for: text, current: current)
            self?.show(names)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { task?.cancel() }

    private func show(_ names: [String]) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !names.isEmpty else {
            waiting.stringValue = "No names to suggest"
            list.addArrangedSubview(waiting)
            return
        }
        for name in names {
            let button = NSButton(title: name, target: self, action: #selector(choose(_:)))
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            list.addArrangedSubview(button)
        }
    }

    @objc private func choose(_ sender: NSButton) {
        field.stringValue = sender.title
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (sender.title as NSString).length, length: 0)
    }
}
