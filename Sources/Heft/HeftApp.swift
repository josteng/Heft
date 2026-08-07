import AppKit
import HeftCore
import SwiftUI

struct HeftApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            // No `.frame(minWidth:)` here: a hard minimum on the view that
            // hosts the NavigationSplitView makes the split view resolve its
            // detail column wider than the window and push the sidebar off the
            // left edge. Window sizing is expressed through the scene instead.
            ContentView()
                .environmentObject(model)
        }
        // The toolbar shows the open note's name and folder, so the title has
        // to be visible; a hidden title bar suppresses it entirely.
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1500, height: 950)
        .commands { HeftCommands(model: model) }

        Window("Presentation", id: "presentation") {
            PresentationView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
    }
}

struct HeftCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note…") { model.createNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Today's Daily Note") { model.openDailyNote(for: Date()) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Open Vault…") { model.promptForVault() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { model.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { model.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { model.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Search Vault…") { model.isVaultSearchPresented = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            Divider()
            Button("Quick Open…") { model.isQuickOpenPresented = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Command Palette…") { model.isCommandPalettePresented = true }
                .keyboardShortcut("p", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            // NavigationSplitView contributes no sidebar command of its own,
            // and the toolbar button disappears with the sidebar, so without
            // this there is no menu-discoverable way back.
            Button(model.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Toggle("Show Calendar", isOn: $model.isCalendarVisible)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Toggle("Colorful Formatting", isOn: $model.isColorfulFormattingEnabled)
            Toggle("Show Backlinks", isOn: $model.isInspectorVisible)
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }

}
