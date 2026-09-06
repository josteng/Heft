import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// A note copied in the sidebar and pasted into the text is a link to that
/// note, not the embed a picture gets. Anything else already in the vault
/// still embeds, and a file from outside is still imported.
@Suite("Pasting a note from the sidebar")
struct PastedNoteLinkTests {

    private func withVault(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-paste-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func destination(for root: URL) -> Attachments.Destination {
        Attachments.Destination(
            rules: AttachmentRules(rules: [.vaultRoot]),
            index: VaultIndex.build(root: VaultScanner.scan(root: root)),
            settings: ObsidianSettings()
        )
    }

    @Test("A note inside the vault becomes a wikilink without its extension")
    func noteBecomesWikilink() throws {
        try withVault(["Index.md": "\n", "Ideas/Plan.md": "# Plan\n"]) { root in
            let markdown = try Attachments.importFile(
                at: root.appendingPathComponent("Ideas/Plan.md"), vaultRoot: root,
                noteURL: root.appendingPathComponent("Index.md"),
                settings: ObsidianSettings(), destination: destination(for: root)
            )
            #expect(markdown == "[[Plan]]")
            // Linked, not copied: still exactly one Plan.md in the vault.
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Plan.md").path))
        }
    }

    @Test("A vault set to Markdown links gets a link to the note's path")
    func noteBecomesMarkdownLink() throws {
        try withVault(["Index.md": "\n", "Ideas/Plan B.md": "# Plan\n"]) { root in
            var settings = ObsidianSettings()
            settings.useWikilinks = false
            let markdown = try Attachments.importFile(
                at: root.appendingPathComponent("Ideas/Plan B.md"), vaultRoot: root,
                noteURL: root.appendingPathComponent("Index.md"),
                settings: settings, destination: destination(for: root)
            )
            #expect(markdown == "[Plan B](Ideas/Plan%20B.md)")
        }
    }

    /// One wording for a name that is taken, whichever half of the app is
    /// carrying the file: the sidebar's paste said `Name copy` while a paste
    /// into the text counted `Name 1`.
    @Test("A copied-in file takes the same copy name the sidebar's paste gives")
    func oneCopyNaming() throws {
        try withVault(["Report.pdf": "one\n", "Report copy.pdf": "two\n"]) { root in
            #expect(Attachments.freeURL(in: root, named: "Report.pdf").lastPathComponent
                == "Report copy 1.pdf")
            #expect(Attachments.freeURL(in: root, named: "Fresh.pdf").lastPathComponent
                == "Fresh.pdf")
            // A folder name is whole; a dot in it is not an extension to keep
            // last, and this path never sees one, so the file rule is enough.
            #expect(Attachments.freeURL(in: root, named: "Report copy.pdf").lastPathComponent
                == "Report copy copy.pdf")
        }
    }

    /// The vault is reached through a symlink often enough to matter: the
    /// temporary folder is one, and `/var` is another. A prefix test on the
    /// raw path called a note in the vault an outsider and copied it in.
    @Test("A note reached through a symlink is still inside the vault")
    func symlinkedVaultIsStillTheVault() throws {
        try withVault(["Index.md": "\n", "Plan.md": "# Plan\n"]) { root in
            // A second spelling of the same folder, the way `/tmp` and
            // `/var` are symlinks to the folders they name.
            let alias = root.deletingLastPathComponent()
                .appendingPathComponent("heft-alias-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            defer { try? FileManager.default.removeItem(at: alias) }
            let viaSymlink = alias.appendingPathComponent("Plan.md")
            try #require(FileManager.default.fileExists(atPath: viaSymlink.path))

            let markdown = try Attachments.importFile(
                at: viaSymlink, vaultRoot: root,
                noteURL: root.appendingPathComponent("Index.md"),
                settings: ObsidianSettings(), destination: destination(for: root)
            )
            #expect(markdown == "[[Plan]]")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Plan copy.md").path))
        }
    }

    @Test("A note from outside is copied in beside the open note and linked")
    func outsideNoteComesInBesideTheNote() throws {
        try withVault(["Ideas/Index.md": "\n", "Ideas/Plan.md": "here\n"]) { root in
            let outside = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("heft-outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("elsewhere\n".utf8).write(to: outside.appendingPathComponent("Plan.md"))

            let markdown = try Attachments.importFile(
                at: outside.appendingPathComponent("Plan.md"), vaultRoot: root,
                noteURL: root.appendingPathComponent("Ideas/Index.md"),
                settings: ObsidianSettings(), destination: destination(for: root)
            )
            // Beside the note, not in the attachment folder, and not over
            // the Plan already there.
            #expect(markdown == "[[Plan copy]]")
            #expect(try String(contentsOf: root.appendingPathComponent("Ideas/Plan copy.md"), encoding: .utf8) == "elsewhere\n")
            #expect(try String(contentsOf: root.appendingPathComponent("Ideas/Plan.md"), encoding: .utf8) == "here\n")
        }
    }

    /// The Finder puts a file's icon on the pasteboard as an image beside
    /// the file. Asking for the image first turned a copied note into a
    /// `Pasted image … .png`.
    @Test("A file on the pasteboard wins over the icon image beside it")
    func fileBeatsIcon() throws {
        let board = NSPasteboard(name: .init("dev.stenglein.Heft.tests.\(UUID().uuidString)"))
        board.clearContents()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        )!
        let png = rep.representation(using: .png, properties: [:])!
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Plan.md")
        board.writeObjects([file as NSURL])
        board.setData(png, forType: .png)

        guard case .file(let found)? = Attachments.pasted(from: board) else {
            Issue.record("the file was not what came back")
            return
        }
        #expect(found.lastPathComponent == "Plan.md")

        // Image data alone is still an image.
        board.clearContents()
        board.setData(png, forType: .png)
        guard case .image(let data, let name)? = Attachments.pasted(from: board) else {
            Issue.record("the image was not what came back")
            return
        }
        #expect(data == png)
        #expect(name == nil)
    }

    @Test("A picture inside the vault still embeds")
    func pictureStillEmbeds() throws {
        try withVault(["Index.md": "\n", "shot.png": "PNG"]) { root in
            let markdown = try Attachments.importFile(
                at: root.appendingPathComponent("shot.png"), vaultRoot: root,
                noteURL: root.appendingPathComponent("Index.md"),
                settings: ObsidianSettings(), destination: destination(for: root)
            )
            #expect(markdown == "![[shot.png]]")
        }
    }
}

/// The other end: ⌘C in the editor with nothing selected asks the host to
/// copy the note as a file rather than copying no text.
@Suite("Copy in the editor with nothing selected")
@MainActor
struct EmptySelectionCopyTests {
    /// Only the empty-selection branch is driven here. The other branch is
    /// `NSTextView.copy`, which writes the general pasteboard, and a test
    /// must not touch the clipboard of the person running it.
    @Test("With no selection, copy is offered to the host and stops there")
    func emptySelectionAsksTheHost() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        var asked = 0
        view.onCopyFile = { asked += 1; return true }
        view.copy(nil)
        #expect(asked == 1)
    }

    /// The Edit menu disables Copy while nothing is selected, and a disabled
    /// item swallows its own key equivalent, so ⌘C beeped instead of reaching
    /// the view. Validation is what decides whether the key arrives at all.
    @Test("Copy stays enabled with no selection while there is a file to copy")
    func copyStaysEnabledForAFile() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        view.onCopyFile = { true }
        view.canCopyFile = { true }
        #expect(view.validateMenuItem(item))

        // Nothing clicked and no note open: the text view's own answer, which
        // for an empty selection is no.
        view.canCopyFile = { false }
        #expect(!view.validateMenuItem(item))

        // With text selected it was never this rule's business.
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.canCopyFile = { false }
        #expect(view.validateMenuItem(item))
    }

    /// The menu is not consulted at all. With nothing selected the Edit
    /// menu's Copy is disabled, a disabled item does not perform its key
    /// equivalent, and the key reached nothing: ⌘C beeped.
    @Test("⌘C is taken by the view itself when nothing is selected")
    func commandCIsTakenBeforeTheMenu() throws {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        var sidebarCopies = 0, noteCopies = 0
        view.onSidebarCopy = { sidebarCopies += 1; return false }
        view.onCopyFile = { noteCopies += 1; return true }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        #expect(view.performKeyEquivalent(with: event))
        // The tree was asked first and declined, so the open note answered.
        #expect(sidebarCopies == 1)
        #expect(noteCopies == 1)

        // With text selected the key is the menu's business again, and the
        // handlers are left alone.
        view.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(!view.performKeyEquivalent(with: event))
        #expect(sidebarCopies == 1)
        #expect(noteCopies == 1)
    }

    /// The handover back. A row clicked in the tree decides what ⌘C and ⌘V
    /// mean only until the reader touches the text; without this, ⌘V would go
    /// on pasting files into a folder while they were typing in the note.
    @Test("Typing in the text takes the keys back from the tree")
    func typingTakesTheKeysBack() throws {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var claimed = 0
        view.onEditorClaimed = { claimed += 1 }

        func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
        }

        view.keyDown(with: try key("a", keyCode: 0))
        #expect(claimed == 1)

        // A command keystroke is not typing: ⌘C and ⌘V themselves must not
        // take the row away before they have been acted on.
        view.keyDown(with: try key("c", keyCode: 8, modifiers: .command))
        #expect(claimed == 1)
    }

    @Test("The sidebar's row takes ⌘C and ⌘V before the note does")
    func sidebarRowTakesTheKeys() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        var copies = 0, pastes = 0, noteCopies = 0
        view.onSidebarCopy = { copies += 1; return true }
        view.onSidebarPaste = { pastes += 1; return true }
        view.onCopyFile = { noteCopies += 1; return true }
        // Both handled by the sidebar's row, so neither reaches the clipboard
        // or the text, which is what makes them safe to call.
        view.copy(nil)
        view.paste(nil)
        #expect(copies == 1)
        #expect(pastes == 1)
        // The row answered, so the open note was never asked.
        #expect(noteCopies == 0)
    }

    /// Selected text outranks the tree: ⌘A then ⌘C copies the text, whatever
    /// was clicked in the sidebar a moment earlier.
    @Test("Selected text is copied as text, whatever the sidebar clicked")
    func selectionOutranksTheSidebar() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 0, length: 4))
        var copies = 0
        view.onSidebarCopy = { copies += 1; return true }
        #expect(view.copiesFileInsteadOfText == false)
        #expect(copies == 0)
    }

    @Test("With text selected, the host is not consulted")
    func selectionIsText() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.string = "some text"
        view.setSelectedRange(NSRange(location: 0, length: 4))
        var asked = 0
        // Returning false would fall through to the clipboard, so this
        // closure must never run at all for the test to be safe.
        view.onCopyFile = { asked += 1; return true }
        // Asked through the responder-chain question rather than `copy`
        // itself: `copy` on a real selection writes the clipboard.
        #expect(view.copiesFileInsteadOfText == false)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.copiesFileInsteadOfText == true)
        #expect(asked == 0)
    }
}
