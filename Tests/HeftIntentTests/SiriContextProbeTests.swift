import AppIntents
import AppIntentsTesting
import AppKit
import XCTest

/// Asks the system, through the same channel Siri uses, which entities a
/// running Heft is showing and whether an identifier resolves.
///
/// A measurement, not a check: it runs against whatever process carries
/// `HEFT_PROBE_BUNDLE`, which must be running already, and skips without
/// one. The system reports the frontmost app's views and nothing else, so
/// `HEFT_PROBE_ACTIVATE=1` brings that app forward for the question and
/// hands focus back. The report goes to the unified log, since a UI test
/// runner's stdout is shown nowhere and its sandbox cannot write a file:
///
///     TEST_RUNNER_HEFT_PROBE_BUNDLE=dev.stenglein.Heft TEST_RUNNER_HEFT_PROBE_ACTIVATE=1 \
///     xcodebuild test -scheme HeftIntentTests -destination platform=macOS ...
///     /usr/bin/log show --last 2m --predicate 'composedMessage CONTAINS "HeftIntentTests report"'
///
/// `HEFT_PROBE_RESOLVE` and `HEFT_PROBE_RESOLVE_FOLDER` add a note and a
/// folder to resolve by identifier the way Siri would.
@available(macOS 27.0, *)
final class SiriContextProbeTests: XCTestCase {
    func testWhatTheSystemSeesOnScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundle = env["HEFT_PROBE_BUNDLE"] else {
            throw XCTSkip("Set HEFT_PROBE_BUNDLE to the bundle identifier of a running Heft.")
        }
        let definitions = IntentDefinitions(bundleIdentifier: bundle)
        var report: [String] = ["bundle: \(bundle)"]
        // The system reports the frontmost app's views and nothing else, so
        // the app under test is brought forward for the question and whoever
        // was in front gets focus back. Opt in, because it steals focus.
        let previous = NSWorkspace.shared.frontmostApplication
        if env["HEFT_PROBE_ACTIVATE"] == "1",
           let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            target.activate()
            for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        report.append("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        for type in ["SiriNoteEntity", "SiriFolderEntity", "NoteEntity"] {
            do {
                let annotations = try await definitions.entities[type].viewAnnotations()
                report.append("\(type): \(annotations.count) annotation(s)")
                for annotation in annotations {
                    let id = annotation.entity.identifier
                    report.append("   selected=\(annotation.isSelected) \(id.entityType.persistentIdentifier):\(id.instanceIdentifier)")
                }
            } catch {
                report.append("\(type): viewAnnotations threw: \(error)")
            }
        }
        if env["HEFT_PROBE_ACTIVATE"] == "1" { previous?.activate() }
        if let path = env["HEFT_PROBE_RESOLVE"] {
            do {
                let found = try await definitions.entities["SiriNoteEntity"].entities(identifiers: [path])
                report.append("resolve \(path): \(found.count) -> \(found.map { "\($0.identifier)" })")
            } catch {
                report.append("resolve \(path): threw: \(error)")
            }
        }
        if let folder = env["HEFT_PROBE_RESOLVE_FOLDER"] {
            do {
                let found = try await definitions.entities["SiriFolderEntity"].entities(identifiers: [folder])
                report.append("resolve folder \(folder): \(found.count) -> \(found.map { "\($0.identifier)" })")
            } catch {
                report.append("resolve folder \(folder): threw: \(error)")
            }
        }
        // One line per entry: the unified log truncates a long message.
        for (index, line) in report.enumerated() {
            NSLog("HeftIntentTests report %02d %@", index, line)
        }

    }
}
