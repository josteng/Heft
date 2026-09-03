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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Has to start watching now rather than when a capture arrives: what
        // it records is how the user left the app, which is already gone by
        // the time an intent brings the app forward and asks.
        MainActor.assumeIsolated { IntentPresentation.begin() }
    }

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

        Settings { SettingsWindow().appAccentTint() }
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
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note…") { model?.createNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model == nil)
            Button("New Window") {
                openWindow(value: model?.descriptor(scopePath: model?.scopePath) ?? WorkspaceDescriptor())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Capture to Inbox…") { model?.presentInboxCapture() }
                .keyboardShortcut(
                    AppCommandShortcut.captureInbox.key,
                    modifiers: AppCommandShortcut.captureInbox.modifiers
                )
                .disabled(model?.vaultRoot == nil)
            if model?.dailyNotesAreInScope != false {
                Button("Today's Daily Note") { model?.openDailyNote(for: Date()) }
                    .keyboardShortcut(
                        AppCommandShortcut.openToday.key,
                        modifiers: AppCommandShortcut.openToday.modifiers
                    )
                    .disabled(model == nil)
            }
            Button("Daily Note Settings…") {
                model?.presentDailyNotesSettings()
            }
            .disabled(model?.vaultRoot == nil)
            Divider()
            Button("Open Vault in New Window…") { openVaultInNewWindow() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
            // writes that into the vault's CLAUDE.md, where a session started
            // in the folder will read it.
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
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut(
                    AppCommandShortcut.exportPDF.key,
                    modifiers: AppCommandShortcut.exportPDF.modifiers
                )
                // On the model, not on the open note: `exportPDF` already says
                // "No note to export", and a shortcut that reports why it did
                // nothing beats one that silently does nothing.
                .disabled(model == nil)
        }
        CommandGroup(after: .textEditing) {
            Menu("Format") {
                Button("Bold") { NSApp.sendAction(#selector(HeftTextKit2View.formatBold), to: nil, from: nil) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { NSApp.sendAction(#selector(HeftTextKit2View.formatItalic), to: nil, from: nil) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Strikethrough") { NSApp.sendAction(#selector(HeftTextKit2View.formatStrikethrough), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") { NSApp.sendAction(#selector(HeftTextKit2View.formatHighlight), to: nil, from: nil) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Code") { NSApp.sendAction(#selector(HeftTextKit2View.formatCode), to: nil, from: nil) }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Link") { NSApp.sendAction(#selector(HeftTextKit2View.formatLink), to: nil, from: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            Divider()
            Menu("Find") {
                Button("Find…") { model?.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { model?.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { model?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Search Workspace…") { model?.isVaultSearchPresented = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            Divider()
            Button("Quick Open…") { model?.isQuickOpenPresented = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Command Palette…") { model?.isCommandPalettePresented = true }
                .keyboardShortcut("p", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.flushPendingSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(model?.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Toggle("Show Calendar", isOn: binding(\.isCalendarVisible))
                .keyboardShortcut(
                    AppCommandShortcut.toggleCalendar.key,
                    modifiers: AppCommandShortcut.toggleCalendar.modifiers
                )
            Toggle("Colorful Formatting", isOn: $appearance.colorfulFormattingEnabled)
            Toggle("Show Backlinks", isOn: binding(\.isInspectorVisible))
                .keyboardShortcut("b", modifiers: [.command, .option])
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
