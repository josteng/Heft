import AppKit
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

struct HeftApp: App {
    @StateObject private var registry = VaultRegistry()

    var body: some Scene {
        WindowGroup("Heft", for: WorkspaceDescriptor.self) { $descriptor in
            WorkspaceSceneRoot(descriptor: $descriptor)
                .environmentObject(registry)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1500, height: 950)
        .commands { HeftCommands(registry: registry) }

        Window("Presentation", id: "presentation") {
            if let model = registry.presentationModel {
                PresentationView().environmentObject(model)
            } else {
                ContentUnavailableView("No Presentation", systemImage: "play.rectangle")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
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
    @StateObject private var model: AppModel
    @Binding private var descriptor: WorkspaceDescriptor?

    init(registry: VaultRegistry, descriptor: Binding<WorkspaceDescriptor?>) {
        _descriptor = descriptor
        _model = StateObject(wrappedValue: AppModel(
            registry: registry, descriptor: descriptor.wrappedValue
        ))
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedSceneValue(\.workspaceModel, model)
            .onAppear { descriptor = model.restorationDescriptor }
            .onChange(of: model.restorationDescriptor) { _, value in descriptor = value }
            .onDisappear { model.closeWorkspace() }
    }
}

struct HeftCommands: Commands {
    let registry: VaultRegistry
    @FocusedValue(\.workspaceModel) private var model
    @Environment(\.openWindow) private var openWindow

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
            if model?.dailyNotesAreInScope != false {
                Button("Today's Daily Note") { model?.openDailyNote(for: Date()) }
                    .keyboardShortcut(
                        AppCommandShortcut.openToday.key,
                        modifiers: AppCommandShortcut.openToday.modifiers
                    )
                    .disabled(model == nil)
            }
            Divider()
            Button("Open Vault in New Window…") { openVaultInNewWindow() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
        CommandGroup(after: .toolbar) {
            Button(model?.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Toggle("Show Calendar", isOn: binding(\.isCalendarVisible))
                .keyboardShortcut(
                    AppCommandShortcut.toggleCalendar.key,
                    modifiers: AppCommandShortcut.toggleCalendar.modifiers
                )
            Toggle("Colorful Formatting", isOn: binding(\.isColorfulFormattingEnabled))
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

    private func openVaultInNewWindow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        panel.message = "Choose the root folder of a markdown vault."
        panel.directoryURL = model?.vaultRoot?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let containing = registry.activeSession(containing: url) {
            let root = containing.root.path
            let chosen = url.standardizedFileURL.path
            let scope = chosen == root ? nil : String(chosen.dropFirst(root.count + 1))
            openWindow(value: WorkspaceDescriptor(vaultPath: root, scopePath: scope))
            return
        }
        if let nested = registry.activeSession(nestedInside: url) {
            let alert = NSAlert()
            alert.messageText = "That folder contains an open vault"
            alert.informativeText = "Close \(nested.root.lastPathComponent) before opening its parent as a separate vault. Overlapping vaults can race while indexing and editing."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        openWindow(value: WorkspaceDescriptor(vaultPath: url.path))
    }
}
