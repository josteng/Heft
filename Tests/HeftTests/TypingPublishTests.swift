import AppKit
import Combine
import Foundation
import HeftCore
import Testing
@testable import Heft

/// A keystroke must not redraw the window.
///
/// Every view observes the model, so each thing the model publishes per
/// keystroke is a redraw of the sidebar, calendar, status bar and toolbar. The
/// text is therefore published on a timer, not per character, and the dirty
/// flag only when it changes.
@MainActor
@Suite("Typing and the window")
struct TypingPublishTests {

    @Test("Fifty keystrokes reach the window once, then the text does")
    func keystrokesArePublishedOnATimer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-typing-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        defer { model.closeWorkspace() }
        // Let the session's first index land, which is published.
        await model.session?.awaitReload()

        var published = 0
        var statsPublished = 0
        let subscription = model.objectWillChange.sink { _ in published += 1 }
        let statsSubscription = model.stats.objectWillChange.sink { _ in statsPublished += 1 }
        defer {
            subscription.cancel()
            statsSubscription.cancel()
        }

        for _ in 0..<50 { model.text += " d" }
        #expect(published == 1, "only the dirty flag, once")
        #expect(statsPublished == 0, "the count waits for the interval")
        #expect(model.isDirty)

        // Save now, so the autosave cannot land inside the wait below.
        model.flushPendingSave()
        #expect(!model.isDirty)
        published = 0

        // Then the word count, once the interval has passed. Polled rather
        // than slept for, since other suites can hold the main thread.
        // Generous: the window harnesses hold the main thread for seconds at
        // a time, and this timer fires only once they let go.
        let deadline = Date(timeIntervalSinceNow: 20)
        while statsPublished < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(statsPublished == 1, "the count is published once")
        #expect(model.stats.wordCount == 51, "Start and fifty more words")
        #expect(model.stats.characterCount == 105, "five, plus fifty times two")
        #expect(published == 0, "and the window itself hears nothing")
    }

    /// The window's edited marker, the dot in the close button, means the
    /// note cannot be written: a failed write or a paused save. Not the
    /// ordinary moment between a keystroke and its autosave, which needs
    /// nothing from the reader and would flicker with every pause.
    @Test("The window's edited marker shows a blocked save, not an edit")
    func editedMarkerShowsBlockedSaves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-edited-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writable = [FileAttributeKey.posixPermissions: 0o755]
        defer {
            try? FileManager.default.setAttributes(writable, ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let note = root.appendingPathComponent("Note.md")
        try "Start".write(to: note, atomically: true, encoding: .utf8)

        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        defer { model.closeWorkspace() }
        func makeWindow() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
        }
        let window = makeWindow()
        registry.register(model: model) { _ in }
        registry.register(window: window, for: model.workspaceID)

        // An ordinary edit, and its save, show nothing.
        model.text += " typed"
        #expect(model.isDirty)
        #expect(!window.isDocumentEdited, "an edit on its way to disk is not a warning")
        model.flushPendingSave()
        #expect(!model.isDirty)
        #expect(!window.isDocumentEdited)

        // A write that fails is.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: root.path
        )
        model.text += " again"
        model.flushPendingSave()
        #expect(model.isDirty, "the buffer stays dirty to retry")
        #expect(model.writeFailed)
        #expect(window.isDocumentEdited, "a failed write marks the window")
        // A window that arrives while the save is blocked starts out marked.
        // It replaces the first as the workspace's window from here on.
        let late = makeWindow()
        registry.register(window: late, for: model.workspaceID)
        #expect(late.isDocumentEdited)

        try FileManager.default.setAttributes(writable, ofItemAtPath: root.path)
        model.flushPendingSave()
        #expect(!model.isDirty)
        #expect(!late.isDocumentEdited, "and the write that succeeds clears it")
        // Including for the next edit: a failure that outlived its recovery
        // would mark every note from then on.
        model.text += " once more"
        #expect(!late.isDocumentEdited, "an edit after the recovery is an ordinary edit")
        model.flushPendingSave()

        // So is a conflict, until it is resolved.
        try "Changed elsewhere".write(to: note, atomically: true, encoding: .utf8)
        model.text += " mine"
        model.flushPendingSave()
        #expect(model.saveConflict != nil, "the note changed on disk under the edit")
        #expect(late.isDocumentEdited, "a paused save marks the window")
        model.resolveSaveConflict(.keepMine)
        #expect(model.saveConflict == nil)
        #expect(!model.isDirty)
        #expect(!late.isDocumentEdited, "and resolving it clears the marker")
    }
}
