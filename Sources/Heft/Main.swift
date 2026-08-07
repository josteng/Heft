import AppKit
import HeftCore
import SwiftUI

/// Custom entry point rather than `@main` on the `App` type, so the binary can
/// also run its self-check headlessly (`swift run Heft selftest`) without
/// spinning up a window server connection.
@main
enum HeftMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("selftest") {
            runSelfCheck()
            return
        }
        if arguments.first == "stats", arguments.count > 1 {
            runStats(vaultPath: arguments[1])
            return
        }
        // `daily <vault> [YYYY-MM-DD]` exercises template expansion and path
        // resolution without the GUI. Same code path the calendar uses.
        if arguments.first == "daily", arguments.count > 1 {
            let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            let settings = ObsidianSettings.load(vaultRoot: root)
            let daily = DailyNotes(vaultRoot: root, settings: settings)

            var date = Date()
            if arguments.count > 2 {
                let parser = DateFormatter()
                parser.dateFormat = "yyyy-MM-dd"
                parser.timeZone = .current
                date = parser.date(from: arguments[2]) ?? date
            }

            do {
                let existed = daily.exists(for: date)
                let url = try daily.ensureNote(for: date)
                print("path:    \(url.path)")
                print("existed: \(existed)")
                print("--- contents ---")
                print((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>")
                exit(0)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if arguments.first == "files", arguments.count > 1 {
            let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            for item in VaultScanner.scan(root: root).flattened() where !item.isFolder {
                print(item.relativePath)
            }
            exit(0)
        }
        HeftApp.main()
    }

    /// Read-only report over a vault. Exists so indexing and link resolution
    /// can be checked against a real vault without launching the editor, which
    /// autosaves and would risk writing to notes that matter.
    private static func runStats(vaultPath: String) {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("No such folder: \(root.path)")
            exit(1)
        }

        let settings = ObsidianSettings.load(vaultRoot: root)
        let scanStart = Date()
        let tree = VaultScanner.scan(root: root)
        let scanTime = Date().timeIntervalSince(scanStart)

        let indexStart = Date()
        let index = VaultIndex.build(root: tree)
        let indexTime = Date().timeIntervalSince(indexStart)

        let files = tree.flattened().filter { !$0.isFolder }
        print("Vault: \(root.path)")
        print("  scan   \(String(format: "%.0f", scanTime * 1000)) ms")
        print("  index  \(String(format: "%.0f", indexTime * 1000)) ms")
        print("  \(index.notes.count) notes, \(files.count - index.notes.count) attachments")
        print("")
        print("Daily notes")
        print("  folder    \(settings.dailyNotesFolder.isEmpty ? "(vault root)" : settings.dailyNotesFolder)")
        print("  format    \(settings.dailyNoteFormat)")
        print("  template  \(settings.dailyNoteTemplate ?? "(none)")")
        let daily = DailyNotes(vaultRoot: root, settings: settings)
        print("  today ->  \(daily.relativePath(for: Date())) [\(daily.exists(for: Date()) ? "exists" : "would be created")]")
        print("  template resolves: \(daily.templateBody() != nil)")
        print("")

        var total = 0
        var unresolved: [String: Int] = [:]
        for note in index.notes {
            for link in index.outgoingLinks(from: note.relativePath) {
                total += 1
                if index.resolve(link, from: note) == nil, !link.target.isEmpty {
                    unresolved[link.target, default: 0] += 1
                }
            }
        }
        let resolved = total - unresolved.values.reduce(0, +)
        let percent = total == 0 ? 100.0 : Double(resolved) / Double(total) * 100
        print("Links")
        print("  \(total) wikilinks, \(resolved) resolved (\(String(format: "%.1f", percent))%)")

        if !unresolved.isEmpty {
            print("  \(unresolved.count) distinct unresolved targets, most referenced:")
            for (target, count) in unresolved.sorted(by: { $0.value > $1.value }).prefix(12) {
                print("    \(count)x  \(target)")
            }
        }

        let mostLinked = index.notes
            .map { ($0.name, index.backlinks(to: $0.relativePath).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        print("")
        print("Most linked-to notes")
        for (name, count) in mostLinked.prefix(8) { print("  \(count)x  \(name)") }
        exit(0)
    }

    private static func runSelfCheck() {
        let result = SelfCheck.run()
        if result.ok {
            print("✓ \(result.passed) checks passed")
            exit(0)
        }
        print("✗ \(result.failures.count) failed, \(result.passed) passed\n")
        for failure in result.failures { print("  • \(failure)") }
        exit(1)
    }
}
