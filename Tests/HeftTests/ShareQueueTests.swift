import Foundation
import Testing
@testable import HeftCore
@testable import HeftiOSVault

/// Shares the iOS share extension could not file itself, queued in the App
/// Group and filed by the app on its next scan.
@Suite("Share queue")
struct ShareQueueTests {

    private func folders(_ files: [String: String] = [:]) throws -> (queue: URL, vault: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-queue-\(UUID().uuidString)")
        let queue = base.appendingPathComponent("Pending", isDirectory: true)
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for (path, text) in files {
            try text.write(to: vault.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return (queue, vault)
    }

    private func queued(_ queue: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
    }

    /// Every rescan drains first, and rescans overlap.
    @Test("Drains running at once file each share once")
    func concurrentDrains() throws {
        let (queue, vault) = try folders(["Roof.md": "the roof\n"])
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<20 {
            try SharedVault.enqueue(.init(text: "line \(n)", destination: .note("Roof.md"),
                                          date: start.addingTimeInterval(Double(n))), in: queue)
        }

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            SharedVault.drainQueue(from: queue, into: vault)
        }

        let text = try String(contentsOf: vault.appendingPathComponent("Roof.md"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("line ") }
        #expect(lines.count == 20, "a share was filed more than once")
        #expect(queued(queue).isEmpty)
    }
}
