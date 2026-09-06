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

    /// How long until `status` is empty, or nil if it was not by the deadline.
    private func timeUntilClear(_ model: AppModel, deadline: Duration) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        // Read after every wake, the last one included: another suite can
        // hold the main thread past the deadline, and the expiry's own
        // continuation may be queued right behind this one.
        repeat {
            if model.status.isEmpty { return clock.now - start }
            try? await Task.sleep(for: .milliseconds(20))
        } while clock.now - start < deadline
        return model.status.isEmpty ? clock.now - start : nil
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
        #expect(await timeUntilClear(model, deadline: .seconds(30)) != nil, "the message should have expired")
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
        try await Task.sleep(for: .milliseconds(500))
        model.status = "Second"
        // If the first message's expiry were still running it would clear
        // the second half a second in; its own expiry takes the full second.
        let lived = try #require(await timeUntilClear(model, deadline: .seconds(30)))
        #expect(lived >= .seconds(1), "the first message's expiry cleared the second after \(lived)")
    }
}
