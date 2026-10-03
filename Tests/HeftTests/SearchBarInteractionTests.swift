import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The bar's keys, through the real view: what typing a trigger, Backspace,
/// Tab and Return on a heading do to the field.
///
/// The field is never made first responder. A text field focused in a
/// headless window starts the system's completion service, which has taken
/// the whole test process down before, so the window refuses focus and the
/// keys are delivered to the field's delegate exactly as AppKit would. The
/// placeholder says which scope the bar is in; the string is the query.
@MainActor
@Suite("Search bar keys", .serialized)
struct SearchBarInteractionTests {

    private final class UnfocusableWindow: NSWindow {
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
    }

    @MainActor
    private struct Harness {
        let window: NSWindow
        let field: NSTextView
        let model: AppModel

        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }

        func type(_ text: String) {
            field.string = text
            field.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: field))
            settle()
        }

        func press(_ selector: Selector) {
            _ = field.delegate?.textView?(field, doCommandBy: selector)
            settle()
        }

        var placeholder: String { field.accessibilityPlaceholderValue() ?? "" }
        var text: String { field.string }
    }

    private func harness(
        _ files: [String: String], scope: BarScope?, recent: [String] = []
    ) async throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-barkeys-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, scopePath: nil)
        )
        for _ in 0..<600 where model.index.notes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        for path in recent { model.session?.recordRecent(path) }
        GeneralSettings.shared.quickOpenOrder = QuickOpenOrder(lead: .recent, count: 2)

        let host = NSHostingView(rootView: SearchBarView(scope: scope).environmentObject(model))
        let window = UnfocusableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Choosing a note dismisses the bar, which outside a sheet closes this
        // window; released on close as well as by Swift, it was freed twice.
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let field = try #require(Self.textField(in: host), "the bar drew no field")
        return Harness(window: window, field: field, model: model)
    }

    private static func textField(in view: NSView) -> NSTextView? {
        if let field = view as? NSTextView, field.isEditable { return field }
        for child in view.subviews {
            if let found = textField(in: child) { return found }
        }
        return nil
    }

    @Test("A trigger typed alone becomes the chip, and Backspace takes it away")
    func triggerAndBackspace() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        #expect(bar.placeholder == BarScope.unscopedPlaceholder)

        bar.type(">")
        #expect(bar.placeholder == BarScope.commands.placeholder)
        #expect(bar.text.isEmpty, "the trigger is not left in the field")

        bar.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(bar.placeholder == BarScope.unscopedPlaceholder)
    }

    @Test("A pasted path stays a query")
    func pastedPath() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        bar.type("/Users/someone/Plan.md")
        #expect(bar.placeholder == BarScope.unscopedPlaceholder)
        #expect(bar.text == "/Users/someone/Plan.md")
    }

    /// Tab goes into the selected tag; Backspace comes back to the tags,
    /// not all the way out.
    @Test("Tab enters a tag, and Backspace returns to the tags")
    func tagChip() async throws {
        let bar = try await harness(["Plan.md": "#work", "Diary.md": "#work"], scope: .tags)
        defer { bar.model.closeWorkspace() }
        bar.press(#selector(NSResponder.insertTab(_:)))
        #expect(bar.placeholder == BarScope.tag("work").placeholder)

        bar.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(bar.placeholder == BarScope.tags.placeholder)
    }

    /// The list opens on the first note; one up is the heading, and Return
    /// on it enters that order as a scope.
    @Test("Return on a heading enters its scope")
    func headingEntersScope() async throws {
        let bar = try await harness(
            ["Alpha.md": "a", "Beta.md": "b"], scope: .notes, recent: ["Alpha.md"]
        )
        defer { bar.model.closeWorkspace() }
        bar.press(#selector(NSResponder.moveUp(_:)))
        bar.press(#selector(NSResponder.insertNewline(_:)))
        // The heading flashes first and the scope follows on the next turn of
        // the main queue, which a run loop spun from inside this test cannot
        // reach; awaiting yields to it.
        try await Task.sleep(for: .milliseconds(100))
        bar.settle()
        #expect(bar.placeholder == BarScope.recent.placeholder)
    }

    /// "rec" puts Recent first, and the space after it makes the chip, as
    /// Chrome's keyword mode does; a space after a note is a space.
    @Test("Space after a scope's name makes it the chip")
    func spaceEntersScope() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        bar.type("rec")
        let before = FrecencyStore.commands.score(BarScope.recent.useKey)
        bar.type("rec ")
        #expect(bar.placeholder == BarScope.recent.placeholder)
        #expect(bar.text.isEmpty)
        #expect(FrecencyStore.commands.score(BarScope.recent.useKey) > before, "entering is a use")

        // Frequent is first for "most", but only by a synonym: still typing.
        bar.press(#selector(NSResponder.deleteBackward(_:)))
        bar.type("most")
        bar.type("most ")
        #expect(bar.placeholder == BarScope.unscopedPlaceholder)
        #expect(bar.text == "most ")
        bar.type("")

        bar.press(#selector(NSResponder.deleteBackward(_:)))
        bar.type("plan")
        bar.type("plan ")
        #expect(bar.placeholder == BarScope.unscopedPlaceholder, "a note is first")
        #expect(bar.text == "plan ")
    }

    /// Moved to with the arrows, a row is chosen, and Space takes it whatever
    /// was typed: here the tag only contains the query.
    @Test("Space takes a scope row the arrows moved to")
    func spaceTakesChosenRow() async throws {
        let bar = try await harness(["Ningbo trip.md": "#planning"], scope: nil)
        defer { bar.model.closeWorkspace() }
        bar.type("ning")
        // First the note, whose name starts with it; then the tag.
        bar.press(#selector(NSResponder.moveDown(_:)))
        bar.type("ning ")
        #expect(bar.placeholder == BarScope.tag("planning").placeholder)
    }

    /// In a tag where only the text matches, the answer arrives with a
    /// heading on top; the selection must move onto the first line, or
    /// Return does nothing.
    @Test("When only text matches in a tag, Return opens the first line")
    func textOnlySelection() async throws {
        let bar = try await harness(["Bakery.md": "#shop\nmilk bread", "Other.md": "milk"], scope: .tag("shop"))
        defer { bar.model.closeWorkspace() }
        bar.type("milk")
        try await Task.sleep(for: .milliseconds(700))
        bar.settle()
        bar.press(#selector(NSResponder.insertNewline(_:)))
        #expect(bar.model.current?.name == "Bakery")
    }

    /// The field grows with what is typed, as Siri's prompt does, and stops
    /// at five lines, past which it scrolls; the list takes what is left.
    @Test("The field grows to five lines and no further")
    func growsToFiveLines() {
        let width: CGFloat = 480
        let one = BarField.height(for: "plan", width: width)
        let empty = BarField.height(for: "", width: width)
        let path = "/Users/someone/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Heft/v0.7.md"
        let two = BarField.height(for: path, width: width)
        let long = BarField.height(for: String(repeating: "a long query ", count: 200), width: width)
        #expect(empty == one, "an empty field is one line, not none")
        #expect(two > one * 1.5, "a long path wraps onto a second line")
        #expect(long < one * 6, "it stops growing")
        #expect(long > one * 4, "but not before about five lines")
    }

    /// In a query over several lines Up and Down move between them first,
    /// and reach the list only from the top or the bottom line; on one line
    /// they go straight to the list.
    @Test("Up and Down move within a long query before the list")
    func arrowsWithinLines() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        func handled(_ selector: Selector) -> Bool {
            bar.field.delegate?.textView?(bar.field, doCommandBy: selector) ?? false
        }
        bar.type("plan")
        bar.field.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(handled(#selector(NSResponder.moveUp(_:))), "one line: Up is the list's")
        #expect(handled(#selector(NSResponder.moveDown(_:))))

        bar.type(String(repeating: "a long query that wraps ", count: 12))
        bar.field.layoutManager?.ensureLayout(for: try #require(bar.field.textContainer))
        let end = (bar.text as NSString).length
        bar.field.setSelectedRange(NSRange(location: end, length: 0))
        #expect(!handled(#selector(NSResponder.moveUp(_:))), "the last line: Up moves in the text")
        #expect(handled(#selector(NSResponder.moveDown(_:))), "the last line: Down is the list's")
        bar.field.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(handled(#selector(NSResponder.moveUp(_:))), "the first line: Up is the list's")
        #expect(!handled(#selector(NSResponder.moveDown(_:))), "the first line: Down moves in the text")
    }

    /// A query is not prose to rewrite.
    @Test("The field offers no Writing Tools")
    func noWritingTools() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        #expect(bar.field.writingToolsBehavior == .none)
    }

    /// A query is one line of meaning, however it wraps.
    @Test("A pasted line break becomes a space")
    func pastedNewline() async throws {
        let bar = try await harness(["Plan.md": "x"], scope: nil)
        defer { bar.model.closeWorkspace() }
        let allowed = bar.field.delegate?.textView?(
            bar.field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "two\nlines"
        )
        #expect(allowed == false)
        #expect(bar.text == "two lines")
    }

    /// What was typed comes along when a shortcut switches the scope, so
    /// ⌘O then ⇧⌘F searches the text for the same words.
    @Test("A shortcut switching scope keeps what was typed")
    func shortcutKeepsQuery() async throws {
        let bar = try await harness(["Plan.md": "milk"], scope: .notes)
        defer { bar.model.closeWorkspace() }
        bar.model.openBar(.notes)
        bar.settle()
        bar.type("milk")
        bar.model.isVaultSearchPresented = true
        bar.settle()
        #expect(bar.placeholder == BarScope.contents.placeholder)
        #expect(bar.text == "milk")
    }

    /// With no name to match, the first row is the text search until the
    /// matches arrive; then Return must open the first match, not the Text
    /// heading that took the first row's place.
    @Test("When only text matches with no scope, Return opens the first match")
    func textOnlyNoScope() async throws {
        let bar = try await harness(["Bakery.md": "an odd ¡mark here"], scope: nil)
        defer { bar.model.closeWorkspace() }
        bar.type("¡mark")
        try await Task.sleep(for: .milliseconds(700))
        bar.settle()
        bar.press(#selector(NSResponder.insertNewline(_:)))
        #expect(bar.model.current?.name == "Bakery")
    }

    /// The last row of a name search carries the words into text search.
    @Test("Searching the text keeps what was typed")
    func searchTextCarriesQuery() async throws {
        let bar = try await harness(["Alpha.md": "milk"], scope: .notes)
        defer { bar.model.closeWorkspace() }
        bar.type("milk")
        // No note is named that, so the text search is the first row.
        bar.press(#selector(NSResponder.insertNewline(_:)))
        #expect(bar.placeholder == BarScope.contents.placeholder)
        #expect(bar.text == "milk")
    }
}
