import Foundation
import HeftCore
import Testing

/// The keys were declared in three places: inline in the menu, named in
/// `AppCommandShortcut`, and typed out again in the README. These are the
/// checks that keep it to one, and they are the same two `CommandLineSpec`
/// carries for verbs, for the same reason: a hand-maintained second copy
/// drifts the first time somebody changes something.
@Suite("Keyboard shortcuts")
struct KeyboardShortcutTests {

    private func source(named name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let found = FileManager.default
            .enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == name } ?? []
        guard found.count == 1 else {
            Issue.record("expected one \(name) under Sources/, found \(found.count)")
            return ""
        }
        return try String(contentsOf: found[0], encoding: .utf8)
    }

    /// macOS writes modifiers control, option, shift, command, in that order,
    /// whatever order they were declared in.
    @Test("A shortcut spells itself the way macOS does")
    func displayOrder() {
        #expect(KeyboardShortcuts.shortcut("openToday").display == "⇧⌘T")
        #expect(KeyboardShortcuts.shortcut("toggleBacklinks").display == "⌥⌘B")
        #expect(KeyboardShortcuts.shortcut("newNote").display == "⌘N")
        // Declared [.command, .shift]; must not print as ⌘⇧.
        #expect(KeyboardShortcuts.shortcut("searchVault").display == "⇧⌘F")
    }

    /// The bug this whole table exists to prevent: two commands quietly
    /// claiming one chord, where only one of them ever fires.
    @Test("No two commands claim the same chord")
    func noCollisions() {
        var seen: [String: String] = [:]
        for shortcut in KeyboardShortcuts.all {
            let chord = shortcut.display
            if let other = seen[chord] {
                Issue.record("\(chord) is claimed by both \(other) and \(shortcut.id)")
            }
            seen[chord] = shortcut.id
        }
    }

    @Test("Every shortcut has a unique id")
    func uniqueIDs() {
        let ids = KeyboardShortcuts.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// A shortcut in the table that no menu item uses is a promise `heft keys`
    /// makes and the app does not keep.
    @Test("Every declared shortcut is actually wired to a menu item")
    func everyShortcutIsUsed() throws {
        let menu = try source(named: "HeftApp.swift")
            + (try source(named: "AppCommands.swift"))
        for shortcut in KeyboardShortcuts.all {
            #expect(
                menu.contains(".\(shortcut.id))") || menu.contains("\"\(shortcut.id)\""),
                "\(shortcut.id) is in the table but nothing uses it"
            )
        }
    }

    /// And the reverse: nothing may declare a chord inline any more, or the
    /// table stops being the answer to "what are the shortcuts".
    @Test("No menu item declares a chord of its own")
    func noInlineShortcuts() throws {
        let menu = try source(named: "HeftApp.swift")
        #expect(
            !menu.contains("keyboardShortcut(\""),
            "a shortcut is declared inline; it belongs in KeyboardShortcuts.all"
        )
    }

    /// The README's table is generated from the same list, so the page cannot
    /// promise a key the app does not have.
    @Test("The README's table matches the app")
    func readmeMatches() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8
        )
        for shortcut in KeyboardShortcuts.all where shortcut.isNotable {
            #expect(
                readme.contains("| \(shortcut.display) | \(shortcut.title) |"),
                "README is missing \(shortcut.display) \(shortcut.title)"
            )
        }
        // And it carries only those, so the table stays the length a person
        // will actually read rather than growing every time a key is added.
        let rows = readme.components(separatedBy: "\n")
            .filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Shortcut") }
        #expect(rows.count == KeyboardShortcuts.all.filter(\.isNotable).count)
    }
}
