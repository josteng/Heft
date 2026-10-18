import HeftCore
import SwiftUI

/// What the menus act on in a window: the note being shown, and the
/// library's own actions where the iPad's sidebar offers them.
extension FocusedValues {
    @Entry var heftNote: NoteDocument?
    @Entry var heftLibrary: LibraryActions?
}

extension EnvironmentValues {
    /// The window's actions, for the search's commands.
    @Entry var mobileLibrary: LibraryActions?
}

/// The iPad sidebar's actions, for the menu bar.
struct LibraryActions {
    var newNote: () -> Void
    var newFolder: () -> Void
    var capture: () -> Void
    var today: () -> Void
    var search: () -> Void
    var show: (PadSidebarMode) -> Void
    var toggleCalendar: () -> Void
    var calendarShown: Bool
    var settings: () -> Void
    var refresh: () -> Void
}

/// The iPadOS menu bar, with the Mac's menus and the Mac's shortcuts, so a
/// key means the same on both. Everything here is also somewhere in the
/// window: the menu bar is hidden until it is asked for.
struct HeftMenuCommands: Commands {
    @FocusedValue(\.heftNote) private var note
    @FocusedValue(\.heftLibrary) private var library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { library?.newNote() }
                .keyboardShortcut("n")
                .disabled(library == nil)
            Button("New Folder") { library?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(library == nil)
            Button("Capture…") { library?.capture() }
                .disabled(library == nil)
            Divider()
            Button("Today's Daily Note") { library?.today() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(library == nil)
        }
        CommandGroup(replacing: .textFormatting) {
            Group {
                Button("Bold") { note?.format(.bold) }.keyboardShortcut("b")
                Button("Italic") { note?.format(.italic) }.keyboardShortcut("i")
                Button("Strikethrough") { note?.format(.strikethrough) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") { note?.format(.highlight) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Code") { note?.format(.code) }.keyboardShortcut("e")
                Divider()
                Button("Link") { note?.format(.link) }.keyboardShortcut("k")
                Button("Toggle Checkbox") { note?.format(.task) }.keyboardShortcut("l")
                Divider()
                Button("Title") { note?.format(.title) }
                Button("Heading") { note?.format(.heading) }
                Button("Subheading") { note?.format(.subheading) }
                Button("Body") { note?.format(.body) }
                Divider()
                Button("Bulleted List") { note?.format(.bullets) }
                Button("Numbered List") { note?.format(.numbers) }
                Button("Quote") { note?.format(.quote) }
                Button("Callout") { note?.format(.callout) }
                Divider()
                Button("Indent") { note?.format(.indent) }
                Button("Outdent") { note?.format(.outdent) }
            }
            .disabled(note == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Files") { library?.show(.files) }.keyboardShortcut("1")
            Button("Recent") { library?.show(.recent) }.keyboardShortcut("2")
            Button("Tags") { library?.show(.tags) }.keyboardShortcut("3")
            Divider()
            Button("Search") { library?.search() }.keyboardShortcut("t")
            Button(library?.calendarShown == false ? "Show Calendar" : "Hide Calendar") {
                library?.toggleCalendar()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
