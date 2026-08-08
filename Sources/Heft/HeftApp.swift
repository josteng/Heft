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
                .keyboardShortcut(
                    AppCommandShortcut.openToday.key,
                    modifiers: AppCommandShortcut.openToday.modifiers
                )
            Divider()
            Button("Open Vault…") { model.promptForVault() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Menu("Format") {
                // Routed through the responder chain rather than the model:
                // the edit belongs to whichever text view has focus, and has
                // to land on its undo stack.
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
                .keyboardShortcut(
                    AppCommandShortcut.toggleCalendar.key,
                    modifiers: AppCommandShortcut.toggleCalendar.modifiers
                )
            Toggle("Colorful Formatting", isOn: $model.isColorfulFormattingEnabled)
            Toggle("Show Backlinks", isOn: $model.isInspectorVisible)
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }

}
