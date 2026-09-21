import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Styling is held while the system is proposing text. Nothing else is.
///
/// Restyling under a session makes AppKit abandon it, which is what made a
/// suggestion show up greyed at the caret and vanish at the next click. The
/// publish is *not* held: a session whose end never comes would otherwise
/// swallow every keystroke after it, and what somebody typed is worth more
/// than what the system offered and they ignored.
@MainActor
@Suite("A Writing Tools session")
struct WritingToolsSessionTests {

    /// The editor as the app builds it, with somewhere to see what reached
    /// the binding.
    private func editor(_ source: String) -> (HeftTextKit2View, LiveTextEditor.Coordinator, Box) {
        let box = Box(text: source)
        let editor = LiveTextEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            documentIdentity: "Note.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.string = source
        view.delegate = coordinator
        return (view, coordinator, box)
    }

    @MainActor final class Box { var text: String; init(text: String) { self.text = text } }

    private func changed(_ view: NSTextView) -> Notification {
        Notification(name: NSText.didChangeNotification, object: view)
    }

    @Test("What it proposes is published like any other change")
    func proposedTextIsStillPublished() {
        let (view, coordinator, box) = editor("A line already written.\n")

        coordinator.writingToolsIsActive = { _ in true }
        coordinator.textViewWritingToolsWillBegin(view)
        view.string = "A line already written. And one it suggests.\n"
        coordinator.textDidChange(changed(view))
        #expect(
            box.text == "A line already written. And one it suggests.\n",
            "a session that never ends would swallow every keystroke after it"
        )
    }

    @Test("What it proposes is not restyled under it")
    func proposedTextIsNotRestyled() {
        let (view, coordinator, box) = editor("# Heading\n")
        _ = box

        coordinator.writingToolsIsActive = { _ in true }
        coordinator.textViewWritingToolsWillBegin(view)
        let before = coordinator.completedRestyleCount
        coordinator.restyle(view)
        #expect(
            coordinator.completedRestyleCount == before,
            "restyling under a session makes AppKit abandon it"
        )

        // And the styling the session held back happens once it ends.
        coordinator.textViewWritingToolsDidEnd(view)
        #expect(coordinator.completedRestyleCount > before)
    }

    @Test("An ordinary edit is published and styled as before")
    func ordinaryEditingIsUntouched() {
        let (view, coordinator, box) = editor("A line.\n")

        let before = coordinator.completedRestyleCount
        view.string = "A line, longer.\n"
        coordinator.textDidChange(changed(view))
        #expect(box.text == "A line, longer.\n")
        coordinator.restyle(view)
        #expect(coordinator.completedRestyleCount > before)
    }

    @Test("Opening another note ends the session, reported or not")
    func anotherNoteEndsTheSession() {
        let (view, coordinator, _) = editor("The note it was asked about.\n")
        coordinator.lastIdentity = "Asked.md"

        // AppKit goes on claiming the session is live, which is what asking
        // Siri a question leaves behind.
        coordinator.writingToolsIsActive = { _ in true }
        coordinator.textViewWritingToolsWillBegin(view)
        try? #require(coordinator.isWritingToolsSession(view))

        // The same note is still held.
        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Asked.md", in: view)
        #expect(coordinator.isWritingToolsSession(view))

        // Another note is not: the editor has to be able to show it.
        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Other.md", in: view)
        #expect(
            !coordinator.isWritingToolsSession(view),
            "the hold outlived the note, so no note could be opened again"
        )
    }

    @Test("A session that outlived its note cannot write into the next one")
    func aSessionCannotCrossNotes() {
        let (view, coordinator, box) = editor("The note it was asked to rewrite.\n")
        coordinator.lastIdentity = "Asked.md"
        coordinator.writingToolsIsActive = { _ in true }
        coordinator.textViewWritingToolsWillBegin(view)

        // The reader opens another note, which ends the hold but not the
        // session: AppKit goes on against the same text view.
        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Other.md", in: view)
        coordinator.lastIdentity = "Other.md"
        box.text = "A different note entirely.\n"
        coordinator.load(box.text, into: view)

        // The rewrite of the note that has gone arrives as an edit to this one.
        view.string = "A rewrite of the first note.\n"
        coordinator.textDidChange(changed(view))

        #expect(box.text == "A different note entirely.\n", "one note was saved as another")
        #expect(view.string == "A different note entirely.\n", "and left on screen as another")
    }

    @Test("The refusal lifts the moment the reader types")
    func typingTakesTheNoteBack() {
        let (view, coordinator, box) = editor("Asked about.\n")
        coordinator.lastIdentity = "Asked.md"
        coordinator.writingToolsIsActive = { _ in true }
        coordinator.textViewWritingToolsWillBegin(view)
        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Other.md", in: view)
        coordinator.lastIdentity = "Other.md"
        box.text = "The other note.\n"
        coordinator.load(box.text, into: view)

        // A session that never reports an end must not leave this note
        // unable to be edited: the first keystroke says who is writing.
        coordinator.readerTypedInto(view)
        view.string = "The other note, edited.\n"
        coordinator.textDidChange(changed(view))
        #expect(box.text == "The other note, edited.\n", "the reader's own edit was refused")
    }

    @Test("A session whose end never comes does not hold the editor shut")
    func aSessionThatNeverEndsIsDropped() {
        let (view, coordinator, box) = editor("A line.\n")

        // Asking Siri a question about the note begins a session and reports
        // no end. Held on the beginning alone, the editor stopped taking new
        // text: the note on screen never changed again.
        coordinator.writingToolsIsActive = { _ in false }
        coordinator.textViewWritingToolsWillBegin(view)

        #expect(!coordinator.isWritingToolsSession(view))
        let before = coordinator.completedRestyleCount
        view.string = "Another note entirely.\n"
        coordinator.textDidChange(changed(view))
        #expect(box.text == "Another note entirely.\n")
        coordinator.restyle(view)
        #expect(coordinator.completedRestyleCount > before)
    }
}

/// A composition left in the buffer when the reader opens another note.
///
/// The editor refuses to replace the buffer while one is in progress, which
/// is right for a dead key and wrong for a note that has been left behind:
/// the previous note's text stayed on screen and was saved as the new note.
@MainActor
@Suite("A composition left behind")
struct StaleCompositionTests {
    @Test("Opening another note ends it, so the buffer can be replaced")
    func openingAnotherNoteEndsIt() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.string = "The note it was typed into.\n"
        let editor = LiveTextEditor(
            text: .constant(view.string), documentIdentity: "Asked.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        view.delegate = coordinator
        coordinator.lastIdentity = "Asked.md"

        view.setMarkedText(
            "suggested", selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: 4, length: 0)
        )
        try? #require(view.hasMarkedText())

        // The same note leaves it alone: a dead key mid-composition is not
        // something to throw away.
        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Asked.md", in: view)
        #expect(view.hasMarkedText())

        coordinator.forgetWritingToolsSession(ifDocumentChangedTo: "Other.md", in: view)
        #expect(!view.hasMarkedText(), "the buffer stays locked and the old note is saved as the new")
    }
}
