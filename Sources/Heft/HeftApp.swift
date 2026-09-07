import AppKit
import AppIntents
import HeftCore
import SwiftUI

private struct WorkspaceModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var workspaceModel: AppModel? {
        get { self[WorkspaceModelKey.self] }
        set { self[WorkspaceModelKey.self] = newValue }
    }
}

/// Receives `heft://` URLs from LaunchServices.
///
/// A delegate rather than `onOpenURL`: the URL that *launches* Heft arrives
/// before any scene exists, and `IntentNavigation` already knows how to hold a
/// request until a workspace registers itself.
final class HeftAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let path = HeftURL.openedPath(in: url) else { continue }
            MainActor.assumeIsolated { IntentNavigation.shared.openPath(path) }
        }
    }
}

struct HeftApp: App {
    @StateObject private var registry = VaultRegistry()
    @NSApplicationDelegateAdaptor(HeftAppDelegate.self) private var appDelegate

    init() {
        HeftAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup("Heft", for: WorkspaceDescriptor.self) { $descriptor in
            WorkspaceSceneRoot(descriptor: $descriptor)
                .environmentObject(registry)
                .appAccentTint()
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1500, height: 950)
        .commands { HeftCommands(registry: registry) }

        Window("Presentation", id: "presentation") {
            if let model = registry.presentationModel {
                PresentationView().environmentObject(model).appAccentTint()
            } else {
                ContentUnavailableView("No Presentation", systemImage: "play.rectangle")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        // No `Settings { }` scene: it sizes its window to the tallest tab and
        // never shrinks back. `SettingsWindowController` is an ordinary Mac
        // settings window, where resizing to the pane on show is the tab
        // controller's own job.
    }
}

private struct WorkspaceSceneRoot: View {
    @EnvironmentObject private var registry: VaultRegistry
    @Binding var descriptor: WorkspaceDescriptor?

    var body: some View {
        WorkspaceWindow(registry: registry, descriptor: $descriptor)
    }
}

private struct WorkspaceWindow: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: AppModel
    private let registry: VaultRegistry
    @Binding private var descriptor: WorkspaceDescriptor?

    init(registry: VaultRegistry, descriptor: Binding<WorkspaceDescriptor?>) {
        self.registry = registry
        _descriptor = descriptor
        _model = StateObject(wrappedValue: AppModel(
            registry: registry, descriptor: descriptor.wrappedValue
        ))
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedSceneValue(\.workspaceModel, model)
            .focusedSceneObject(model.sidebarKeys)
            .onAppear {
                descriptor = model.restorationDescriptor
                registry.register(model: model) { descriptor in
                    openWindow(value: descriptor)
                }
                IntentNavigation.shared.attach(registry)
            }
            .onChange(of: model.restorationDescriptor) { _, value in descriptor = value }
            .onDisappear { model.closeWorkspace() }
    }
}

struct HeftCommands: Commands {
    // Observed, not merely held: Open Recent has to reorder as vaults are
    // opened, and a plain `let` would leave the menu showing whatever the
    // list was when the scene was built.
    @ObservedObject var registry: VaultRegistry
    @FocusedValue(\.workspaceModel) private var model
    /// Watched, not merely read: see `AppModel.sidebarKeys`. Without this the
    /// Trash item below keeps the enabled state it was built with.
    @FocusedObject private var sidebarKeys: SidebarKeyTarget?

    /// Named after what it would put back, so the menu says whether ⌘Z is
    /// about to touch the tree or the text.
    private var undoTitle: String {
        guard sidebarKeys?.url != nil, let name = model?.sidebarUndoName else { return "Undo" }
        return "Undo \(name)"
    }
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some Commands {
        // Ours rather than the one a `Settings` scene installs, since there is
        // no such scene: the window is an ordinary AppKit settings window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show(registry) }
                .keyboardShortcut(.settings)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Note…") { model?.createNote() }
                .keyboardShortcut(.newNote)
                .disabled(model == nil)
            Button("New Window") {
                openWindow(value: model?.descriptor(scopePath: model?.scopePath) ?? WorkspaceDescriptor())
            }
            .keyboardShortcut(.newWindow)
            Divider()
            Button("Open Inbox") { model?.openInbox() }
                .disabled(model?.vaultRoot == nil)
            if model?.dailyNotesAreInScope != false {
                Button("Today's Daily Note") { model?.openDailyNote(for: Date()) }
                    .keyboardShortcut(.openToday)
                    .disabled(model == nil)
            }
            Button("Daily Note Settings…") {
                model?.presentDailyNotesSettings()
            }
            .disabled(model?.vaultRoot == nil)
            Divider()
            Button("New Vault…") { model?.createVault() }
                .disabled(model == nil)
            Button("Open Vault in New Window…") { openVaultInNewWindow() }
                .keyboardShortcut(.openVaultInNewWindow)
            Menu("Open Recent") {
                ForEach(registry.recentVaults, id: \.url) { recent in
                    // Switches this window rather than opening another: the
                    // point of the menu is moving between a test vault and the
                    // real one, not accumulating windows.
                    Button(recent.label) { openRecentVault(recent.url) }
                }
                if !registry.recentVaults.isEmpty { Divider() }
                Button("Clear Menu") { registry.clearRecentVaults() }
                    .disabled(registry.recentVaults.isEmpty)
            }
            .disabled(registry.recentVaults.isEmpty)
            // No ⇧⌘G: that is Find Previous. The system's Go to Folder sheet
            // cannot be given a shell-escaped path, which is the form one is
            // almost always copied in, so this is Heft's own way in.
            Button("Go to Path…") { model?.promptToGoToPath() }
            // The proposal verbs are only reachable if something tells an
            // agent they exist, and a vault of markdown says nothing. This
            // writes that into the vault's CLAUDE.md and AGENTS.md, where a
            // session started in the folder will read it, whichever agent it
            // is.
            Button(
                model?.hasAgentGuide == true
                    ? "Update Agent Access…"
                    : "Set Up Agent Access…"
            ) { model?.setUpAgentAccess() }
                .disabled(model?.vaultRoot == nil)
        }
        // `.importExport`, not `.saveItem`.
        //
        // This is the anchor macOS reserves for exactly this item, and it is
        // the one anchor here that nothing else touches. Attaching it `after:
        // .saveItem` looked right and silently did not work: `HeftCommands`
        // also *replaces* the `.saveItem` group further down, and replacing a
        // group removes the anchor an `after:` on the same group hangs from.
        // The item then lands nowhere, and a menu item that is not in a menu
        // has no working key equivalent — which reads as "the shortcut is
        // reserved by the system" and is nothing of the kind.
        CommandGroup(after: .importExport) {
            // ⌘⌫ lives here rather than in the text view, and the menu is what
            // makes it work at all: a menu item's key equivalent is offered
            // before any view sees the event, and clicking a row in the tree
            // takes the keyboard off the editor, so the editor could not
            // answer for it there. Disabled while nothing is clicked in the
            // tree, which lets the key through to the text, where it deletes
            // to the start of the line.
            Button("Move to Trash") { model?.deleteFromKeyboard() }
                .keyboardShortcut(.delete, modifiers: .command)
                // Both halves are read here so the menu depends on both: it
                // settles this when it is built, and a selection made without
                // a row clicked last would otherwise leave the item stale.
                .disabled(
                    (sidebarKeys?.url == nil && sidebarKeys?.selection.isEmpty != false)
                        || model?.canDeleteFromSidebar != true
                )
            Divider()
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut(.exportPDF)
                // On the model, not on the open note: `exportPDF` already says
                // "No note to export", and a shortcut that reports why it did
                // nothing beats one that silently does nothing.
                .disabled(model == nil)
        }
        // One Undo, replacing the system pair rather than sitting beside it.
        //
        // Two items cannot share ⌘Z. A disabled menu item swallows its own
        // key equivalent, so a second Undo that was disabled most of the time
        // took the key away from the editor's and undoing text stopped
        // working at all. This one is always enabled and decides where the
        // key goes; when it goes to the text it is forwarded down the
        // responder chain, which is where the text view's own undo lives.
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                switch UndoRouting.target(
                    sidebarOwnsKeys: sidebarKeys?.url != nil,
                    sidebarHasStep: model?.sidebarUndoName != nil
                ) {
                case .sidebar: model?.undoSidebarOperation()
                case .text: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut(.undo)
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut(.redo)
        }
        CommandGroup(after: .textEditing) {
            Menu("Format") {
                Button("Bold") { NSApp.sendAction(#selector(HeftTextKit2View.formatBold), to: nil, from: nil) }
                    .keyboardShortcut(.bold)
                Button("Italic") { NSApp.sendAction(#selector(HeftTextKit2View.formatItalic), to: nil, from: nil) }
                    .keyboardShortcut(.italic)
                Button("Strikethrough") { NSApp.sendAction(#selector(HeftTextKit2View.formatStrikethrough), to: nil, from: nil) }
                    .keyboardShortcut(.strikethrough)
                Button("Highlight") { NSApp.sendAction(#selector(HeftTextKit2View.formatHighlight), to: nil, from: nil) }
                    .keyboardShortcut(.highlight)
                Button("Code") { NSApp.sendAction(#selector(HeftTextKit2View.formatCode), to: nil, from: nil) }
                    .keyboardShortcut(.code)
                Divider()
                Button("Link") { NSApp.sendAction(#selector(HeftTextKit2View.formatLink), to: nil, from: nil) }
                    .keyboardShortcut(.link)
                Button("Toggle Checkbox") { model?.toggleChecklist() }
                    .keyboardShortcut(.toggleCheckbox)
                    .disabled(model?.current == nil)
            }
            Divider()
            Menu("Find") {
                Button("Find…") { model?.showFind() }
                    .keyboardShortcut(.find)
                Button("Find Next") { model?.findNext() }
                    .keyboardShortcut(.findNext)
                Button("Find Previous") { model?.findPrevious() }
                    .keyboardShortcut(.findPrevious)
                Divider()
                Button("Search Workspace…") { model?.isVaultSearchPresented = true }
                    .keyboardShortcut(.searchVault)
            }
            Divider()
            Button("Quick Open…") { model?.isQuickOpenPresented = true }
                .keyboardShortcut(.quickOpen)
            Button("Command Palette…") { model?.isCommandPalettePresented = true }
                .keyboardShortcut(.commandPalette)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.flushPendingSave() }
                .keyboardShortcut(.save)
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(model?.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model?.toggleSidebar()
            }
            .keyboardShortcut(.toggleSidebar)
            Toggle("Show Calendar", isOn: binding(\.isCalendarVisible))
                .keyboardShortcut(.toggleCalendar)
            // Quick Open and a wikilink both open a note without touching the
            // tree, so after either the sidebar is showing somewhere else and
            // where the note actually lives is a guess.
            Button("Reveal in Sidebar") { model?.revealCurrentInSidebar() }
                .keyboardShortcut(.revealInSidebar)
                .disabled(model?.current == nil)
            Toggle("Colorful Formatting", isOn: $appearance.colorfulFormattingEnabled)
            Toggle("Show Backlinks", isOn: binding(\.isInspectorVisible))
                .keyboardShortcut(.toggleBacklinks)
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { model?[keyPath: keyPath] ?? false },
            set: { model?[keyPath: keyPath] = $0 }
        )
    }

    /// Switches the focused window to a vault from Open Recent.
    ///
    /// `AppModel.openVault` is what the picker uses too, so a switch flushes
    /// a pending save and refuses a vault nested inside an open one, exactly
    /// as choosing it by hand would. With no window focused there is nothing
    /// to switch, so the vault gets one of its own.
    private func openRecentVault(_ url: URL) {
        if let model {
            model.openVault(at: url)
        } else {
            openWindow(value: WorkspaceDescriptor(vaultPath: url.path))
        }
    }

    private func openVaultInNewWindow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        panel.message = "Choose the root folder of a markdown vault."
        panel.directoryURL = model?.vaultRoot?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch registry.resolveOpen(for: url) {
        case .open(let descriptor):
            openWindow(value: descriptor)
        case .overlapping(let vaultName):
            let alert = NSAlert()
            alert.messageText = "That folder contains an open vault"
            alert.informativeText = "Close \(vaultName) before opening its parent as a separate vault. Overlapping vaults can race while indexing and editing."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
