import AppKit
import Foundation
import HeftCore
import SwiftUI
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
        func foregroundColor(
            _ source: String, at location: Int, context: RenderContext
        ) -> NSColor? {
            let storage = NSTextStorage(string: source)
            _ = LiveStyler.apply(to: storage, reveal: .none, context: context)
            return storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        }

        // Regression check for the collision where an unresolved wikilink and
        // colourful-italic text were both plain `.systemOrange`: overriding
        // orange with identical orange looked exactly like no override at
        // all. Unresolved should stay the same hue as resolved, just dimmed.
        let defaultContext = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let unresolvedLink = foregroundColor("[[Nowhere]]", at: 2, context: defaultContext)
        expect(
            unresolvedLink == defaultContext.linkColor.withAlphaComponent(0.55),
            "an unresolved wikilink is the link colour, dimmed, not an unrelated hue"
        )

        let customContext = RenderContext(
            index: .empty, current: nil, vaultRoot: nil, colorfulFormatting: true,
            accentColor: .systemBlue, linkColor: .systemIndigo, tagColor: .systemTeal,
            codeColor: .systemBrown,
            boldColor: .systemGreen, italicColor: .systemPurple,
            headingColors: [.black, .darkGray, .gray, .lightGray, .white, .clear]
        )
        expect(
            foregroundColor("**bold**", at: 2, context: customContext) == NSColor.systemGreen,
            "a custom bold colour from Appearance settings reaches the live surface"
        )
        expect(
            foregroundColor("*italic*", at: 1, context: customContext) == NSColor.systemPurple,
            "a custom italic colour from Appearance settings reaches the live surface"
        )
        expect(
            foregroundColor("`code`", at: 1, context: customContext) == NSColor.systemBrown,
            "a custom code colour from Appearance settings reaches the live surface"
        )
        expect(
            foregroundColor("[[Nowhere]]", at: 2, context: customContext)
                == NSColor.systemIndigo.withAlphaComponent(0.55),
            "link colour dims correctly for an unresolved link, independent of accent colour"
        )

        expect(
            foregroundColor("#project", at: 3, context: customContext) == NSColor.systemTeal,
            "a custom tag colour from Appearance settings reaches the live surface"
        )

        // The pill behind a tag is drawn by the layout fragment rather than
        // set as a background attribute, so it is the layout that has to
        // carry it, and in the tag's own colour.
        func tagPill(_ source: String, context: RenderContext) -> (NSRange, NSColor, NSFont, CGRect)? {
            let storage = NSTextStorage(string: source)
            let layout = LiveStyler.apply(to: storage, reveal: .none, context: context)
            return layout.inlineTags.values.first?.first
        }
        let pill = tagPill("see #project here", context: customContext)
        expect(pill?.1 == NSColor.systemTeal, "a tag pill is drawn in the tag colour")
        expect(
            pill.map { NSMaxRange($0.0) <= 12 && $0.0.location == 4 } ?? false,
            "the tag pill covers the tag itself, not the words around it"
        )
        expect(
            tagPill("nothing to see here", context: customContext) == nil,
            "no tag pill is drawn for a line without a tag"
        )

        func headingAccentColor(_ source: String, context: RenderContext) -> NSColor? {
            let storage = NSTextStorage(string: source)
            let layout = LiveStyler.apply(to: storage, reveal: .none, context: context)
            for widget in layout.blocks.values {
                if case .headingAccent(_, let color) = widget { return color }
            }
            return nil
        }
        expect(
            headingAccentColor("# Heading", context: customContext) == NSColor.black,
            "a custom h1 colour from Appearance settings reaches the heading accent bar"
        )
        expect(
            headingAccentColor("# Heading", context: defaultContext) == nil,
            "no heading accent bar is drawn with colourful formatting off"
        )

        expect(
            liveFontSize("#") == LiveStyler.headingSize(1),
            "a lone hash receives H1 metrics immediately"
        )
        expect(
            liveFontSize("##") == LiveStyler.headingSize(2),
            "two hashes receive H2 metrics immediately"
        )

        func paragraphStyle(_ source: String, at location: Int) -> NSParagraphStyle? {
            let storage = NSTextStorage(string: source)
            _ = LiveStyler.apply(
                to: storage,
                reveal: Reveal.none,
                context: RenderContext(index: .empty, current: nil, vaultRoot: nil)
            )
            return storage.attribute(
                .paragraphStyle, at: location, effectiveRange: nil
            ) as? NSParagraphStyle
        }

        let softLine = paragraphStyle("first\nsecond", at: 0)
        expect(
            softLine?.paragraphSpacing == 0 && softLine?.lineSpacing == Theme.lineSpacing,
            "a soft Markdown newline uses line spacing without a paragraph gap"
        )
        let blankSeparator = paragraphStyle("first\n\nsecond", at: 6)
        expect(
            blankSeparator?.lineSpacing == 0
                && blankSeparator?.paragraphSpacing == Theme.lineSpacing,
            "one empty source line supplies one compact paragraph separator"
        )
        let headingSpacing = paragraphStyle("# Heading", at: 0)
        expect(
            (headingSpacing?.paragraphSpacingBefore ?? 0) > 0
                && (headingSpacing?.paragraphSpacing ?? 0) > 0,
            "heading-specific breathing room remains intact"
        )

        func listMinimumHeight(_ source: String) -> CGFloat {
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
            return (storage.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil
            ) as? NSParagraphStyle)?.minimumLineHeight ?? 0
        }

        expect(listMinimumHeight("- ") > 10, "an empty bullet reserves a clickable body line")
        expect(listMinimumHeight("1. ") > 10, "an empty number reserves a clickable body line")
        expect(listMinimumHeight("- [ ] ") > 10, "an empty task reserves a clickable body line")
        expect(
            HeftTextKit2View.nextListMarker(after: "\t9. ") == "\t10. ",
            "ordered-list continuation increments and retains its formatting"
        )
        expect(
            HeftTextKit2View.nextListMarker(after: "- [x] ") == "- [x] ",
            "task-list continuation does not alter its marker"
        )

        let orderedEditor = HeftTextKit2View(usingTextLayoutManager: true)
        orderedEditor.string = "9. first"
        orderedEditor.setSelectedRange(NSRange(location: orderedEditor.string.utf16.count, length: 0))
        orderedEditor.insertNewline(nil)
        expect(
            orderedEditor.string == "9. first\n10. ",
            "pressing Return inserts the incremented ordered marker"
        )

        // Return on an empty nested item steps out one level rather than
        // abandoning the list, so the levels above it survive.
        func returnOnEmptyItem(_ source: String) -> String {
            let editor = HeftTextKit2View(usingTextLayoutManager: true)
            editor.string = source
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            return editor.string
        }
        expectEqual(
            returnOnEmptyItem("- one\n\t\t- "), "- one\n\t- ",
            "Return on an empty item two levels in steps out to one"
        )
        expectEqual(
            returnOnEmptyItem("- one\n\t- "), "- one\n- ",
            "Return on an empty item one level in steps out to the top"
        )
        // Only once it has run out of levels does the list end, which is the
        // behaviour that was there before.
        expectEqual(
            returnOnEmptyItem("- one\n- "), "- one\n\n",
            "Return on an empty top-level item still ends the list"
        )
        expectEqual(
            returnOnEmptyItem("\t- [ ] "), "- [ ] ",
            "an empty nested task steps out rather than ending"
        )
        // An item with content is unaffected: it continues, as it always did.
        expectEqual(
            returnOnEmptyItem("\t- typed"), "\t- typed\n\t- ",
            "a nested item with content still continues at its own level"
        )

        let completionEditor = HeftTextKit2View(usingTextLayoutManager: true)
        completionEditor.string = "["
        completionEditor.setSelectedRange(NSRange(location: 1, length: 0))
        completionEditor.insertText("[", replacementRange: completionEditor.selectedRange())
        expect(completionEditor.string == "[[]]", "typing [[ adds closing brackets")
        expect(completionEditor.selectedRange().location == 2,
               "auto-paired wikilink leaves the caret inside")

        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("heft-integration-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults.standard
        let lastVaultKey = "dev.stenglein.Heft.vaultPath"
        let previousLastVault = defaults.object(forKey: lastVaultKey)
        // Recents are app-wide and persist, so a test run must put the real
        // list back rather than leave its disposable vaults in someone's
        // Open Recent menu.
        let previousRecents = defaults.object(forKey: VaultRegistry.recentVaultsKey)
        defer {
            try? manager.removeItem(at: root)
            if let previousLastVault {
                defaults.set(previousLastVault, forKey: lastVaultKey)
            } else {
                defaults.removeObject(forKey: lastVaultKey)
            }
            if let previousRecents {
                defaults.set(previousRecents, forKey: VaultRegistry.recentVaultsKey)
            } else {
                defaults.removeObject(forKey: VaultRegistry.recentVaultsKey)
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
        let autosaved = await waitUntil {
            (try? String(contentsOf: draftURL, encoding: .utf8)) == "autosaved"
        }
        expect(autosaved, "autosave writes the open note atomically")

        // The window subtitle shares its row with the toolbar's centred scope
        // picker, so anything that changes width while typing slides that
        // picker back and forth. Autosave toggles `isDirty` on a 700ms cycle,
        // which is exactly the shape of state that must not reach it.
        let subtitleWhenClean = first.windowSubtitle
        expect(!first.isDirty, "the note is saved before the subtitle is compared")
        first.text = "typing changes the buffer"
        expect(first.isDirty, "typing marks the note dirty")
        expectEqual(
            first.windowSubtitle, subtitleWhenClean,
            "the window subtitle does not change while typing"
        )

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

        let popupEditor = HeftTextKit2View(usingTextLayoutManager: true)
        popupEditor.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        popupEditor.textContainerInset = NSSize(width: 28, height: 28)
        popupEditor.completionIndex = files.index
        let popupScroll = NSScrollView(frame: popupEditor.frame)
        popupScroll.documentView = popupEditor
        popupEditor.string = "["
        popupEditor.setSelectedRange(NSRange(location: 1, length: 0))
        popupEditor.insertText("[", replacementRange: popupEditor.selectedRange())
        expect(
            popupEditor.subviews.contains { $0 is WikiCompletionPanel && !$0.isHidden },
            "typing [[ presents its completion panel"
        )

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

        // Going to a path in the form one is actually copied in. Finder and a
        // terminal both escape spaces for the shell, and the system's own Go
        // to Folder sheet takes the escaped text literally and finds nothing.
        let spacedFolder = root.appendingPathComponent("MSc Thesis", isDirectory: true)
        try? manager.createDirectory(at: spacedFolder, withIntermediateDirectories: true)
        try? "# Meeting".write(
            to: spacedFolder.appendingPathComponent("Questions To Ask.md"),
            atomically: true, encoding: .utf8
        )
        let spacedAppeared = await waitUntil {
            files.tree?.flattened().contains { $0.relativePath == "MSc Thesis" } == true
        }
        expect(spacedAppeared, "a folder with a space appears in the tree")

        let escapedFolder = spacedFolder.path.replacingOccurrences(of: " ", with: "\\ ")
        expect(files.goToPath(escapedFolder), "an escaped folder path is accepted")
        expectEqual(files.scopePath, "MSc Thesis", "an escaped folder path focuses that folder")

        let escapedNote = spacedFolder
            .appendingPathComponent("Questions To Ask.md").path
            .replacingOccurrences(of: " ", with: "\\ ")
        let noteIndexed = await waitUntil {
            files.index.note(atRelativePath: "MSc Thesis/Questions To Ask.md") != nil
        }
        expect(noteIndexed, "a note in a spaced folder is indexed")
        expect(files.goToPath(escapedNote), "an escaped note path is accepted")
        expectEqual(
            files.current?.relativePath, "MSc Thesis/Questions To Ask.md",
            "an escaped note path opens that note"
        )

        expect(
            !files.goToPath("\(root.path)/Nowhere\\ At\\ All.md"),
            "a path that points at nothing is refused"
        )
        files.showEntireVault()

        // Dragging an item out of Heft. `.draggable(url)` exported a file
        // *promise*, so a terminal resolved it to a path inside
        // `~/Library/Caches/com.apple.SwiftUI.Drag-<uuid>/` rather than the
        // note's own. What the drop target reads is the payload, so that is
        // what this checks; the gesture itself belongs to AppKit.
        let dragged = root.appendingPathComponent("Archive/Research/Chapter.md")
        let dragBoard = NSPasteboard(name: NSPasteboard.Name("dev.stenglein.Heft.tests.drag"))
        dragBoard.clearContents()
        dragBoard.writeObjects([fileDragPasteboardWriter(for: dragged)])
        let draggedTypes = dragBoard.types ?? []
        expect(
            draggedTypes.contains(.fileURL),
            "a dragged item is written to the pasteboard as a file URL"
        )
        expect(
            !draggedTypes.contains { $0.rawValue.contains("promise") },
            "a dragged item is not promised, which is what resolved to a cache copy"
        )
        let deliveredPath = (dragBoard.readObjects(forClasses: [NSURL.self]) as? [URL])?
            .first?.path
        expectEqual(deliveredPath, dragged.path, "a dragged item delivers the vault's own path")

        // A calendar day drags its note out of Heft but must not be able to
        // rearrange the vault: a daily note is found again by its filename.
        expect(
            FileDragSource.operation(for: .outsideApplication, allowsInternalMove: false) == .copy,
            "a daily note can still be dragged to another app"
        )
        expect(
            FileDragSource.operation(for: .withinApplication, allowsInternalMove: false).isEmpty,
            "a daily note cannot be dropped into another folder of its own vault"
        )
        expect(
            FileDragSource.operation(for: .withinApplication, allowsInternalMove: true)
                .contains(.move),
            "an ordinary note can still be moved within the vault"
        )

        // Typing substitutions, through the text view rather than the engine:
        // that the rules are right is `SelfCheck`'s job, that the editor calls
        // them and that backspace reverts one is this one's.
        let typing = TypingSettings.shared
        let previousEnabled = typing.substitutionsEnabled
        let previousGroups = typing.enabledGroups
        let previousRules = typing.customRules
        typing.substitutionsEnabled = true
        typing.enabledGroups = Set(SmartTypographyGroup.allCases)
        typing.customRules = []
        defer {
            typing.substitutionsEnabled = previousEnabled
            typing.enabledGroups = previousGroups
            typing.customRules = previousRules
        }

        let editor = HeftTextKit2View(usingTextLayoutManager: true)
        editor.isEditable = true
        editor.isRichText = false
        func type(_ characters: String) {
            for character in characters {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
            }
        }

        type("a -> b")
        expectEqual(editor.string, "a \u{2192} b", "typing -> in the editor gives an arrow")

        editor.string = ""
        type("x ->")
        editor.deleteBackward(nil)
        expectEqual(editor.string, "x ->", "backspace puts back what was typed")
        editor.deleteBackward(nil)
        expectEqual(editor.string, "x -", "a second backspace deletes normally")

        editor.string = ""
        type("`a ->")
        expectEqual(editor.string, "`a ->", "the editor leaves inline code alone")

        editor.string = ""
        editor.insertText("a -> b", replacementRange: editor.selectedRange())
        expectEqual(editor.string, "a -> b", "pasted text is never substituted")

        editor.string = ""
        typing.substitutionsEnabled = false
        type("a ->")
        expectEqual(editor.string, "a ->", "the setting switches the editor's rules off")
        typing.substitutionsEnabled = true

        // Word-end firing and snippets, which only the editor can show off:
        // the built-ins are switched off so nothing else can claim a trigger.
        typing.enabledGroups = []
        typing.customRules = [
            CustomSubstitution(trigger: "omw", replacement: "On my way!", firing: .afterWord),
            CustomSubstitution(trigger: ";cb", replacement: "```\n{{caret}}\n```"),
        ]

        editor.string = ""
        type("omw")
        expectEqual(editor.string, "omw", "an after-a-space rule waits for the space")
        type(" ")
        expectEqual(editor.string, "On my way! ", "the space fires it and stays where it was typed")

        editor.string = ""
        type("omw")
        editor.insertNewline(nil)
        expectEqual(editor.string, "On my way!\n", "Return fires an after-a-space rule too")

        editor.string = ""
        type(";cb")
        expectEqual(editor.string, "```\n\n```", "a snippet expands its placeholders")
        expect(editor.selectedRange().location == 4, "the caret lands where {{caret}} was")

        typing.enabledGroups = Set(SmartTypographyGroup.allCases)

        // The settings pane, hosted rather than clicked: enough to catch a
        // pane that collapses to nothing or refuses to build its rule rows,
        // which is what a SwiftUI mistake here actually looks like.
        let pane = NSHostingView(rootView: TypingSettingsView())
        pane.layoutSubtreeIfNeeded()
        let paneSize = pane.fittingSize
        expect(paneSize.width >= 600, "the Typing pane is as wide as the Settings window")
        expect(paneSize.height > 300, "the Typing pane lays out its groups and rules")

        // Many rules must scroll inside the table rather than make the pane —
        // and with it the Settings window — grow without limit.
        func paneHeight(rules: Int) -> CGFloat {
            typing.customRules = (0..<rules).map {
                CustomSubstitution(trigger: ";t\($0)", replacement: "rule \($0)")
            }
            let view = NSHostingView(rootView: TypingSettingsView())
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        let forty = paneHeight(rules: 40)
        let hundred = paneHeight(rules: 100)
        expect(
            forty == hundred,
            "the pane stops growing and scrolls instead (\(forty)pt vs \(hundred)pt)"
        )
        expect(
            forty > paneSize.height,
            "the pane does grow with rules until it reaches that cap"
        )
        typing.customRules = []

        // Every group is on unless it was explicitly switched off — including
        // groups that did not exist when the settings were last written, which
        // is why the disabled set is what gets stored.
        expect(
            TypingSettings.groups(disabled: nil, legacyEnabled: nil)
                == Set(SmartTypographyGroup.allCases),
            "a fresh install has every group on"
        )
        expect(
            TypingSettings.groups(disabled: ["fractions"], legacyEnabled: nil)
                == Set(SmartTypographyGroup.allCases).subtracting([.fractions]),
            "a switched-off group stays off"
        )
        expect(
            TypingSettings.groups(disabled: [], legacyEnabled: nil)
                == Set(SmartTypographyGroup.allCases),
            "an empty disabled list is every group on"
        )
        expect(
            TypingSettings.groups(disabled: nil, legacyEnabled: ["arrows", "dashes"])
                .contains(.symbols),
            "a group added after the settings were written arrives switched on"
        )
        expect(
            !TypingSettings.groups(disabled: nil, legacyEnabled: ["arrows", "dashes"])
                .contains(.fractions),
            "upgrading keeps what the user had switched off"
        )

        // A rule stored before per-rule firing existed must still decode.
        let legacy = Data(
            #"[{"id":"\#(UUID().uuidString)","trigger":";x","replacement":"y","isEnabled":true}]"#
                .utf8
        )
        let decoded = try? JSONDecoder().decode([CustomSubstitution].self, from: legacy)
        expect(decoded?.first?.firing == .immediately, "an older stored rule still decodes")

        // Open Recent. Its own registry, so recording a throwaway vault cannot
        // disturb the sessions the checks above are still holding; the list
        // itself is app-wide and shared, which is what makes it worth writing.
        let recentsProbe = VaultRegistry()
        let ghostVault = manager.temporaryDirectory
            .appendingPathComponent("heft-ghost-\(UUID().uuidString)", isDirectory: true)
        try? manager.createDirectory(at: ghostVault, withIntermediateDirectories: true)
        let ghostPath = ghostVault.standardizedFileURL.path

        _ = recentsProbe.session(for: ghostVault)
        expectEqual(
            recentsProbe.recentVaultPaths.first, ghostPath,
            "opening a vault puts it at the front of the recents"
        )
        expect(
            recentsProbe.recentVaults.contains { $0.url.standardizedFileURL.path == ghostPath },
            "a vault that is still there is offered"
        )

        // A vault in iCloud Drive can move or be evicted between sessions. It
        // stops being offered, but is not forgotten: a volume that comes back
        // should bring its vault back with it.
        try? manager.removeItem(at: ghostVault)
        expect(
            !recentsProbe.recentVaults.contains { $0.url.standardizedFileURL.path == ghostPath },
            "a vault that has gone is not offered"
        )
        expect(
            recentsProbe.recentVaultPaths.contains(ghostPath),
            "a vault that has gone is still remembered"
        )

        recentsProbe.clearRecentVaults()
        expect(recentsProbe.recentVaults.isEmpty, "clearing empties the menu")

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
