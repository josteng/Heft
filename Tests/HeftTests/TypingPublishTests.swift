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
        let subscription = model.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }

        for _ in 0..<50 { model.text += "d" }
        #expect(published == 1, "only the dirty flag, once")
        #expect(model.isDirty)

        // Save now, so the autosave cannot land inside the wait below and be
        // mistaken for the text arriving.
        model.flushPendingSave()
        #expect(!model.isDirty)
        published = 0

        // Then the text, once the interval has passed. Polled rather than
        // slept for, since other suites can hold the main thread.
        let deadline = Date(timeIntervalSinceNow: 3)
        while published < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(published == 1, "the text is published once")
    }
}
