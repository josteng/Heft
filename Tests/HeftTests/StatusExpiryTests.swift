import Foundation
import HeftCore
import Testing
@testable import Heft

/// A status message is feedback about the last action, not a state, and
/// nothing overwrites it any more now that saves are silent. It has to clear
/// itself, and a newer message has to get its own full lifetime.
///
/// Waits are polls with a deadline, not sleeps: under a busy main actor a
/// sleep resumes late, and which of two sleepers resumes first is not defined.
@MainActor
@Suite("Status messages expire")
struct StatusExpiryTests {

    private func makeModel(in root: URL) throws -> AppModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        return AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
    }

    /// How long the model's own expiry took to clear `status`.
    ///
    /// Awaits that task rather than polling against a deadline: the expiry
    /// resumes on the main actor, a loaded suite can hold that for tens of
    /// seconds, and no deadline a poll picks is both quick and reliable.
    private func timeToClear(_ model: AppModel) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        await model.statusExpiry?.value
        return clock.now - start
    }

    @Test("A message clears after its lifetime")
    func messageClears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(in: root)
        defer { model.closeWorkspace() }
        model.statusLifetime = .milliseconds(100)

        model.status = "Renamed to Other.md"
        #expect(model.status == "Renamed to Other.md")
        _ = await timeToClear(model)
        #expect(model.status.isEmpty, "the message should have expired")
    }

    @Test("A newer message restarts the clock")
    func newerMessageRestartsTheClock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(in: root)
        defer { model.closeWorkspace() }
        model.statusLifetime = .seconds(1)

        model.status = "First"
        let first = try #require(model.statusExpiry)
        try await Task.sleep(for: .milliseconds(500))
        model.status = "Second"

        // The claim is that the first expiry no longer governs, and that is
        // a fact about the tasks rather than about the clock: timing it
        // means racing a suite that can hold the main actor for seconds.
        #expect(first.isCancelled, "the first message's expiry still governs the second")
        #expect(model.statusExpiry?.isCancelled == false)

        let lived = await timeToClear(model)
        #expect(model.status.isEmpty)
        #expect(lived >= .milliseconds(900), "the second message lived only \(lived)")
    }
}
