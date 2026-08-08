import AppKit
import Foundation
import HeftCore
@testable import Heft

/// End-to-end checks over the mutable app shell.
///
/// Every run owns a UUID-named temporary vault and removes it afterwards. This
/// deliberately exercises AppModel rather than duplicating its file operations
/// in test-only helpers, while remaining incapable of touching a real vault.
@MainActor
enum AppIntegrationCheck {
    struct Result {
        var passed = 0
        var failures: [String] = []
        var ok: Bool { failures.isEmpty }
    }

    static func run() async -> Result {
        var result = Result()
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() { result.passed += 1 }
            else { result.failures.append(label) }
        }
        func expectEqual(_ actual: String?, _ expected: String, _ label: String) {
            if actual == expected { result.passed += 1 }
            else { result.failures.append("\(label): got \(actual ?? "<missing>")") }
        }
        func contents(_ url: URL) -> String? {
            try? String(contentsOf: url, encoding: .utf8)
        }
        func liveFontSize(_ source: String) -> CGFloat? {
            let storage = NSTextStorage(string: source)
            let reveal = Reveal(
                selection: NSRange(location: storage.length, length: 0),
                in: source as NSString
            )
            _ = LiveStyler.apply(
                to: storage,
                reveal: reveal,
                context: RenderContext(index: .empty, current: nil, vaultRoot: nil)
            )
            guard storage.length > 0 else { return nil }
            return (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }

        expect(
            liveFontSize("#") == LiveStyler.headingSize(1),
            "a lone hash receives H1 metrics immediately"
        )
        expect(
            liveFontSize("##") == LiveStyler.headingSize(2),
            "two hashes receive H2 metrics immediately"
        )

        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("heft-integration-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults.standard
        let lastVaultKey = "dev.stenglein.Heft.vaultPath"
        let previousLastVault = defaults.object(forKey: lastVaultKey)
        defer {
            try? manager.removeItem(at: root)
            if let previousLastVault {
                defaults.set(previousLastVault, forKey: lastVaultKey)
            } else {
                defaults.removeObject(forKey: lastVaultKey)
            }
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.createDirectory(
                at: root.appendingPathComponent("Thesis"), withIntermediateDirectories: true
            )
            try manager.createDirectory(
                at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true
            )
            try "initial".write(
                to: root.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8
            )
            try "shared".write(
                to: root.appendingPathComponent("Shared.md"), atomically: true, encoding: .utf8
            )
            try "See [[Thesis/Chapter]] and [[Chapter]].".write(
                to: root.appendingPathComponent("Index.md"), atomically: true, encoding: .utf8
            )
            try "# Chapter".write(
                to: root.appendingPathComponent("Thesis/Chapter.md"),
                atomically: true, encoding: .utf8
            )
            try "Internal [[Thesis/Chapter]].".write(
                to: root.appendingPathComponent("Thesis/Internal.md"),
                atomically: true, encoding: .utf8
            )
        } catch {
            result.failures.append("could not create disposable vault: \(error)")
            return result
        }

        let registry = VaultRegistry()
        let draftURL = root.appendingPathComponent("Draft.md")
        let first = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Draft.md")
        )
        expect(first.current?.relativePath == "Draft.md", "integration opens a requested note")

        first.text = "autosaved"
        try? await Task.sleep(for: .milliseconds(850))
        expect(contents(draftURL) == "autosaved", "autosave writes the open note atomically")

        let competingOwner = UUID()
        expect(
            !registry.claim(draftURL, for: competingOwner),
            "another workspace cannot claim the open note"
        )
        first.text = "saved while closing"
        first.closeWorkspace()
        expect(contents(draftURL) == "saved while closing", "closing flushes pending edits")
        expect(
            registry.claim(draftURL, for: competingOwner),
            "closing releases the workspace's editor lease"
        )
        registry.release(draftURL, for: competingOwner)

        let conflictModel = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Draft.md")
        )
        conflictModel.text = "local version"
        try? "external version".write(to: draftURL, atomically: true, encoding: .utf8)
        conflictModel.save()
        expect(conflictModel.saveConflict != nil, "external edits produce a save conflict")
        expect(contents(draftURL) == "external version", "a conflict never overwrites disk")
        if let shared = NoteRef(
            url: root.appendingPathComponent("Shared.md"), vaultRoot: root
        ) {
            conflictModel.open(shared)
            expect(
                conflictModel.current?.relativePath == "Draft.md",
                "an unresolved conflict blocks switching notes"
            )
        }
        conflictModel.resolveSaveConflict(.useDisk)
        expect(conflictModel.text == "external version", "the disk conflict version can be loaded")
        expect(!conflictModel.isDirty, "loading the disk version clears the dirty state")

        conflictModel.text = "explicit local version"
        try? "second external version".write(to: draftURL, atomically: true, encoding: .utf8)
        conflictModel.save()
        conflictModel.resolveSaveConflict(.keepMine)
        expect(
            contents(draftURL) == "explicit local version",
            "keeping local changes overwrites only after explicit confirmation"
        )

        conflictModel.text = "recover me"
        try? "newer external version".write(to: draftURL, atomically: true, encoding: .utf8)
        conflictModel.closeWorkspace()
        let recovery = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ))?.first { $0.lastPathComponent.hasPrefix("Draft (Heft Recovery ") }
        expect(recovery.flatMap(contents) == "recover me", "closing a conflict preserves a recovery note")
        expect(contents(draftURL) == "newer external version", "recovery leaves the disk version intact")

        let files = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path)
        )
        let indexed = await waitUntil { files.tree != nil && files.index.notes.count >= 5 }
        expect(indexed, "the disposable vault finishes indexing")

        let beforeCapture = files.current?.relativePath
        let firstCapture = "Remember the useful thing"
        expect(files.captureToInbox(firstCapture), "the app captures to Inbox.md")
        let inboxURL = root.appendingPathComponent("Inbox.md")
        expect(
            contents(inboxURL)?.contains(firstCapture) == true,
            "an inbox capture is written as plain markdown"
        )
        expect(
            files.current?.relativePath == beforeCapture,
            "capturing does not disturb the current note"
        )
        let secondCapture = "This should be newer"
        expect(files.captureToInbox(secondCapture), "a second inbox capture succeeds")
        if let inboxText = contents(inboxURL),
           let firstRange = inboxText.range(of: firstCapture),
           let secondRange = inboxText.range(of: secondCapture) {
            expect(secondRange.lowerBound < firstRange.lowerBound, "newer inbox captures come first")
        } else {
            result.failures.append("inbox captures were unavailable for ordering")
        }

        if let inboxRef = NoteRef(url: inboxURL, vaultRoot: root) {
            files.open(inboxRef)
            files.text += "\nManual inbox edit\n"
            expect(
                files.captureToInbox("Captured while Inbox was open"),
                "capturing safely saves and reloads an open Inbox"
            )
            expect(
                files.text.contains("Manual inbox edit")
                    && files.text.contains("Captured while Inbox was open"),
                "an open Inbox keeps both editor changes and the capture"
            )

            let intentStyleCapture = "Captured outside the editor model"
            _ = try? InboxCapture(vaultRoot: root).capture(intentStyleCapture)
            let openInboxRefreshed = await waitUntil {
                files.text.contains(intentStyleCapture)
            }
            expect(
                openInboxRefreshed,
                "an open Inbox refreshes after an App Intent-style capture"
            )

            let directDiskEdit = files.text + "\nExternal writer\n"
            try? directDiskEdit.write(to: inboxURL, atomically: true, encoding: .utf8)
            let genericExternalEditRefreshed = await waitUntil {
                files.text.contains("External writer")
            }
            expect(
                genericExternalEditRefreshed,
                "an open clean note refreshes after a same-process disk edit"
            )
        } else {
            result.failures.append("Inbox.md could not be represented as a note")
        }

        let created = files.createUntitledNote(in: root)
        expect(created?.path == "Untitled.md", "inline creation writes an untitled note")
        let createdAppeared = await waitUntil {
            files.tree?.flattened().contains { $0.relativePath == "Untitled.md" } == true
        }
        expect(createdAppeared, "created notes appear in the shared tree")
        if let item = files.tree?.flattened().first(where: { $0.relativePath == "Untitled.md" }) {
            expect(files.rename(item, to: "Created"), "a created note can be renamed")
        } else {
            result.failures.append("created note was unavailable for rename")
        }
        let renameAppeared = await waitUntil {
            files.tree?.flattened().contains { $0.relativePath == "Created.md" } == true
        }
        expect(renameAppeared, "renamed notes appear at their new path")
        files.move(
            [root.appendingPathComponent("Created.md")],
            into: root.appendingPathComponent("Archive")
        )
        expect(
            manager.fileExists(atPath: root.appendingPathComponent("Archive/Created.md").path),
            "moving a note changes its filesystem location"
        )

        guard await waitUntil({
            files.tree?.flattened().contains { $0.relativePath == "Thesis" } == true
        }), let thesis = files.tree?.flattened().first(where: { $0.relativePath == "Thesis" })
        else {
            result.failures.append("folder was unavailable for rename")
            files.closeWorkspace()
            return result
        }
        expect(
            files.index.backlinks(to: "Thesis/Chapter.md").count == 3,
            "the pre-rename index contains all folder-target backlinks"
        )
        expect(files.rename(thesis, to: "Research"), "a folder can be renamed")
        expectEqual(
            contents(root.appendingPathComponent("Index.md")),
            "See [[Research/Chapter]] and [[Chapter]].",
            "folder rename repoints an external path-qualified link; \(files.status)"
        )
        expectEqual(
            contents(root.appendingPathComponent("Research/Internal.md")),
            "Internal [[Research/Chapter]].",
            "folder rename repoints links in notes moved with the folder; \(files.status)"
        )
        expect(
            contents(root.appendingPathComponent("Index.md"))?.contains("[[Chapter]]") == true,
            "folder rename preserves a resolvable bare link"
        )

        let folderRenameAppeared = await waitUntil {
            files.tree?.flattened().contains { $0.relativePath == "Research" } == true
        }
        expect(folderRenameAppeared, "renamed folders appear in the shared tree")
        files.move(
            [root.appendingPathComponent("Research")],
            into: root.appendingPathComponent("Archive")
        )
        expect(
            contents(root.appendingPathComponent("Index.md"))?
                .contains("[[Archive/Research/Chapter]]") == true,
            "folder move repoints external path-qualified links"
        )
        expect(
            contents(root.appendingPathComponent("Archive/Research/Internal.md"))?
                .contains("[[Archive/Research/Chapter]]") == true,
            "folder move repoints links inside the moved folder"
        )

        files.closeWorkspace()
        return result
    }

    private static func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
