import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// The other half of `SpellCheckScopeTests`: that the text view actually asks.
///
/// AppKit reports every misspelling it finds through `setSpellingState`, one
/// call per word, so the override is the whole suppression mechanism and a
/// wrong answer there is a red underline under `let`.
@MainActor
@Suite("Spell check surface")
struct SpellCheckSurfaceTests {

    private func editor(_ body: String) -> (HeftTextKit2View, LiveTextEditor.Coordinator) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(body), documentIdentity: "s.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        // The text first, then the delegates: assigning `string` with the
        // storage delegate attached restyles on the spot, and a test that
        // wants to watch a restyle publish something cannot start after one.
        view.string = body
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        return (view, coordinator)
    }

    /// Whether anything is drawn as misspelled anywhere in `range`.
    ///
    /// Spelling state is a rendering attribute, not a storage one, which is
    /// also why an underline survives a restyle rewriting every attribute in
    /// the paragraph.
    private func isMarked(_ range: NSRange, in view: HeftTextKit2View) -> Bool {
        guard let manager = view.textLayoutManager,
              let content = view.textContentStorage,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let span = NSTextRange(location: start, end: end)
        else { return false }

        var marked = false
        manager.enumerateRenderingAttributes(from: span.location, reverse: false, using: { _, attributes, attributeRange in
            guard NSTextRange(location: span.location, end: span.endLocation)?
                .intersects(attributeRange) == true else { return false }
            if let state = attributes[.spellingState] as? Int, state != 0 { marked = true }
            // A grammar mark arrives as its own family of rendering
            // attributes rather than as a spelling state, so looking only at
            // the latter would call a blue underline no underline at all.
            if attributes[NSAttributedString.Key("NSGrammarCorrections")] != nil { marked = true }
            return attributeRange.endLocation.compare(span.endLocation) == .orderedAscending
        })
        return marked
    }

    /// Waits for the checker to agree, or gives up.
    ///
    /// `checkText` hands the work to the spell checker and applies the answer
    /// on a later turn of the main queue, so an assertion made on the next
    /// line reads the state from before it. Polled rather than slept on: a
    /// fixed wait is either flaky or slow, and usually both.
    private func settles(
        _ expected: Bool, _ range: NSRange, in view: HeftTextKit2View
    ) async -> Bool {
        for _ in 0..<100 {
            if isMarked(range, in: view) == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func range(of word: String, in body: String) -> NSRange {
        (body as NSString).range(of: word)
    }

    /// The mechanism, end to end: what the checker reports for a code span is
    /// dropped, and what it reports for prose is kept.
    @Test("A word in an excluded span is never marked")
    func vetoesExcludedSpans() {
        let body = "This sentance is prose and `thatIsNotAWord` is not."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)

        let typo = range(of: "sentance", in: body)
        let code = range(of: "thatIsNotAWord", in: body)
        view.setSpellingState(1, range: typo)
        view.setSpellingState(1, range: code)

        #expect(isMarked(typo, in: view), "a typo in prose must be underlined")
        #expect(!isMarked(code, in: view), "a word inside a code span must not be")
    }

    /// The exclusions come from the restyle, so a note that has never been
    /// styled must not silently suppress everything or nothing.
    @Test("Restyling publishes the exclusions to the view")
    func restylePublishesExclusions() {
        let body = "Prose here and `code_here` too, plus #tagHere."
        let (view, coordinator) = editor(body)
        #expect(view.spellExclusions.isEmpty)

        coordinator.restyle(view)
        #expect(view.spellExclusions.count == 2)
        #expect(SpellCheckScope.excludes(range(of: "code_here", in: body), in: view.spellExclusions))
        #expect(SpellCheckScope.excludes(range(of: "tagHere", in: body), in: view.spellExclusions))
        #expect(!SpellCheckScope.excludes(range(of: "Prose", in: body), in: view.spellExclusions))
    }

    /// Editing above a code span moves it, and an exclusion is a range. The
    /// restyle that follows an edit can take an early exit when nothing about
    /// the decorations changed, and the exclusions still have to move with it.
    @Test("Exclusions follow the span when the text above it moves")
    func exclusionsFollowEdits() {
        let body = "Head\n\nProse and `code_here` after.\n"
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        let before = view.spellExclusions

        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Inserted line\n\n")
        coordinator.restyle(view)

        #expect(view.spellExclusions != before, "the span moved but the exclusion did not")
        let moved = range(of: "code_here", in: view.string)
        #expect(SpellCheckScope.excludes(moved, in: view.spellExclusions))
        #expect(!SpellCheckScope.excludes(range(of: "Inserted", in: view.string), in: view.spellExclusions))
    }

    /// Prose can become source. Wrapping a marked word in backticks makes it a
    /// code span, and AppKit then clears the underline it drew a moment ago,
    /// through the same override, on a range that is now excluded. Vetoing
    /// that clear leaves the underline under the code for good.
    @Test("A word that turns into code loses the underline it already had")
    func clearingIsLetThroughOnNewlyExcludedText() {
        let body = "A thatIsNotAWord here."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)

        let word = range(of: "thatIsNotAWord", in: body)
        view.setSpellingState(1, range: word)
        #expect(isMarked(word, in: view))

        // What typing the backticks around it amounts to.
        view.spellExclusions = [word]
        view.setSpellingState(0, range: word)
        #expect(!isMarked(word, in: view), "the underline is stuck under a code span")
    }

    /// Grammar does not come through the veto, so a fenced block would keep
    /// its blue underline without the sweep that follows the check.
    @Test("A grammar mark inside code is taken back off")
    func grammarIsSweptFromCode() async {
        // The same fault twice, once in prose and once in a fence. The prose
        // one is the proof that the checker has run at all: without it,
        // "the fence is unmarked" is also true a millisecond in, before the
        // checker has looked, and the test passes having watched nothing.
        let body = "The the doubled in prose.\n\n```text\nThe the doubled inside code.\n```\n"
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(true, grammar: true)

        let source = body as NSString
        let inProse = source.range(of: "The the")
        let inCode = source.range(
            of: "The the",
            options: [], range: NSRange(location: NSMaxRange(inProse), length: source.length - NSMaxRange(inProse))
        )
        #expect(inCode.location != NSNotFound)

        #expect(await settles(true, inProse, in: view), "the checker never ran")
        #expect(await settles(false, inCode, in: view), "the fence kept its grammar underline")
    }

    /// And the sweep must not reach past the spans it is for.
    @Test("A grammar mark in prose survives the sweep")
    func grammarInProseSurvives() async {
        let body = "The the doubled in prose.\n\n```text\ncode here\n```\n"
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(true, grammar: true)

        let inProse = range(of: "The the", in: body)
        #expect(await settles(true, inProse, in: view))
        view.sweepGrammar()
        #expect(isMarked(inProse, in: view), "the sweep reached into prose")
    }

    // MARK: - Automatic correction

    /// The one feature here that edits the note. It cannot be vetoed the way a
    /// mark can, so it is gated on the caret instead: a correction only ever
    /// rewrites the word being typed.
    @Test("Autocorrect is off while the caret is in source")
    func autocorrectFollowsTheCaret() {
        let body = "Prose here and `code_span` and a #tag too."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.correctsSpelling = true

        view.setSelectedRange(NSRange(location: range(of: "Prose", in: body).location, length: 0))
        #expect(view.isAutomaticSpellingCorrectionEnabled, "prose is where it should work")

        view.setSelectedRange(NSRange(location: range(of: "code_span", in: body).location, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled, "it would rewrite the code")

        view.setSelectedRange(NSRange(location: range(of: "tag", in: body).location, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled, "it would rewrite the tag")

        view.setSelectedRange(NSRange(location: range(of: "too", in: body).location, length: 0))
        #expect(view.isAutomaticSpellingCorrectionEnabled, "and back on the far side of it")
    }

    @Test("Autocorrect stays off when the setting is off, wherever the caret is")
    func autocorrectRespectsTheSetting() {
        let body = "Prose here and `code_span` too."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.correctsSpelling = false

        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        view.setSelectedRange(NSRange(location: range(of: "code_span", in: body).location, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
    }

    /// The caret can move without the restyle rewriting anything: it takes its
    /// cheapest exit when the parse and the revealed spans are both unchanged,
    /// and then nothing republishes the exclusions. So moving the selection
    /// has to recompute the flag on its own.
    @Test("Moving the caret alone recomputes the flag")
    func autocorrectFollowsASelectionWithNoRestyle() {
        let body = "Prose here and `code_span` too."
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.string = body
        view.spellExclusions = SpellCheckScope.exclusions(
            for: LiveDecorator.decorations(in: body), in: body as NSString
        )
        view.correctsSpelling = true

        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(view.isAutomaticSpellingCorrectionEnabled)
        view.setSelectedRange(NSRange(location: range(of: "code_span", in: body).location, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled, "the selection move was not noticed")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(view.isAutomaticSpellingCorrectionEnabled, "and back out again")
    }

    /// Typing turns prose into source under a caret that has not moved, so the
    /// flag is recomputed when the exclusions change and not only when the
    /// selection does.
    @Test("A caret that has not moved is reconsidered when the exclusions change")
    func autocorrectRecomputedWhenExclusionsChange() {
        // No coordinator: selecting through one restyles, which would set the
        // exclusions itself and leave nothing for this test to observe.
        let body = "Prose here and `code_span` too."
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.string = body
        view.correctsSpelling = true
        view.setSelectedRange(NSRange(location: range(of: "code_span", in: body).location, length: 0))
        #expect(view.isAutomaticSpellingCorrectionEnabled, "no exclusions are known yet")

        view.spellExclusions = SpellCheckScope.exclusions(
            for: LiveDecorator.decorations(in: body), in: body as NSString
        )
        #expect(!view.isAutomaticSpellingCorrectionEnabled, "the caret was not reconsidered")
    }

    // MARK: - The three menu items

    /// The Edit and context menus toggle the text view directly. Each of the
    /// three has to write through to the setting instead, or the menu and the
    /// settings pane disagree and the next SwiftUI pass undoes the menu.
    @Test("Every Spelling and Grammar menu item writes through to its setting")
    func menuItemsWriteThrough() {
        let settings = TypingSettings.shared
        let spelling = settings.checksSpelling
        let grammar = settings.checksGrammar
        let correction = settings.correctsSpelling
        defer {
            settings.checksSpelling = spelling
            settings.checksGrammar = grammar
            settings.correctsSpelling = correction
        }

        let (view, _) = editor("Body.")
        for start in [true, false] {
            settings.checksSpelling = start
            view.toggleContinuousSpellChecking(nil)
            #expect(settings.checksSpelling == !start, "Check Spelling While Typing")

            settings.checksSpelling = true
            settings.checksGrammar = start
            view.toggleGrammarChecking(nil)
            #expect(settings.checksGrammar == !start, "Check Grammar with Spelling")

            settings.correctsSpelling = start
            view.toggleAutomaticSpellingCorrection(nil)
            #expect(settings.correctsSpelling == !start, "Correct Spelling Automatically")
        }
    }

    /// The menu's tick has to say whether the setting is on, not whether the
    /// caret happens to be somewhere it can fire.
    @Test("The correction menu item is ticked from the setting, not the caret")
    func correctionMenuItemShowsTheSetting() {
        let settings = TypingSettings.shared
        let was = settings.correctsSpelling
        defer { settings.correctsSpelling = was }

        let body = "Prose here and `code_span` too."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.correctsSpelling = true
        view.setSelectedRange(NSRange(location: range(of: "code_span", in: body).location, length: 0))
        #expect(!view.isAutomaticSpellingCorrectionEnabled, "it cannot fire in a code span")

        let item = NSMenuItem(
            title: "Correct Spelling Automatically",
            action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: ""
        )
        #expect(view.validateMenuItem(item))
        #expect(item.state == .on, "the menu disagreed with the settings pane")

        view.correctsSpelling = false
        #expect(view.validateMenuItem(item))
        #expect(item.state == .off)
    }

    /// Grammar cannot be on without spelling, so the menu item that turns it
    /// on has to turn spelling on with it rather than appear to do nothing.
    @Test("Turning grammar on from the menu turns spelling on too")
    func grammarMenuItemEnablesSpelling() {
        let settings = TypingSettings.shared
        let spelling = settings.checksSpelling
        let grammar = settings.checksGrammar
        defer { settings.checksSpelling = spelling; settings.checksGrammar = grammar }

        let (view, _) = editor("Body.")
        settings.checksSpelling = false
        settings.checksGrammar = false
        view.toggleGrammarChecking(nil)
        #expect(settings.checksSpelling)
        #expect(settings.checksGrammar)
    }

    // MARK: - The setting

    @Test("The setting reaches both AppKit flags")
    func flags() {
        let (view, _) = editor("Body.")

        view.checksSpelling(true, grammar: false)
        #expect(view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)

        view.checksSpelling(true, grammar: true)
        #expect(view.isGrammarCheckingEnabled)

        // Grammar without spelling is not a state the Edit menu can reach and
        // not one AppKit honours.
        view.checksSpelling(false, grammar: true)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)
    }

    /// The bug this suite missed: the flags were set and nothing was
    /// re-examined, so switching checking on left the open note bare until it
    /// was typed into or reopened.
    @Test("Turning checking on marks the note that is already open")
    func turningOnChecksWhatIsAlreadyThere() async {
        let body = "This sentance is prose."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(false, grammar: false)

        let typo = range(of: "sentance", in: body)
        #expect(!isMarked(typo, in: view))

        view.checksSpelling(true, grammar: false)
        #expect(await settles(true, typo, in: view), "the note was never re-checked")
    }

    /// A re-check goes through the same veto, so switching checking on must
    /// not be a way round the exclusions.
    @Test("A re-check still skips code")
    func recheckRespectsExclusions() async {
        let body = "This sentance is prose and `thatIsNotAWord` is not."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(false, grammar: false)
        view.checksSpelling(true, grammar: false)

        #expect(await settles(true, range(of: "sentance", in: body), in: view))
        #expect(!isMarked(range(of: "thatIsNotAWord", in: body), in: view))
    }

    /// And the other half: grammar's blue underlines outlived the setting,
    /// because switching a flag off does not withdraw what it already drew.
    @Test("Turning grammar off takes its underlines with it")
    func turningGrammarOffClearsIt() async {
        // Two paragraphs and a trailing newline: the checker wants a document
        // rather than a fragment, and says nothing about a lone sentence.
        let body = "The the doubled in prose.\n\nA second line of prose.\n"
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(true, grammar: true)

        let clause = range(of: "The the", in: body)
        #expect(await settles(true, clause, in: view), "a doubled word is what grammar catches")

        view.checksSpelling(true, grammar: false)
        #expect(await settles(false, clause, in: view), "the underline outlived the setting")
    }

    /// Re-checking a long note is not something to do on every SwiftUI pass,
    /// and `updateNSView` runs on all of them.
    @Test("Setting the same values again does no work")
    func idempotent() {
        let (view, coordinator) = editor("This sentance is prose.")
        coordinator.restyle(view)

        #expect(view.checksSpelling(true, grammar: true), "off to on is a change")
        #expect(!view.checksSpelling(true, grammar: true), "nothing changed the second time")
        #expect(view.checksSpelling(true, grammar: false), "grammar going off is a change")
        #expect(!view.checksSpelling(true, grammar: false))
        // Grammar is only ever on with spelling, so this pair is the state the
        // view is already in and must not re-check either.
        #expect(view.checksSpelling(false, grammar: false))
        #expect(!view.checksSpelling(false, grammar: true))
    }

    /// Switching checking off is AppKit clearing the document through the same
    /// override, so the veto has to let a clearing call past: an exclusion
    /// overlaps a document-length range, and vetoing it would leave the last
    /// underlines on screen with the setting saying they are gone.
    @Test("Turning checking off clears what was already marked")
    func clearsOnDisable() {
        let body = "This sentance is prose."
        let (view, coordinator) = editor(body)
        coordinator.restyle(view)
        view.checksSpelling(true, grammar: false)

        let typo = range(of: "sentance", in: body)
        view.setSpellingState(1, range: typo)
        #expect(isMarked(typo, in: view))

        view.checksSpelling(false, grammar: false)
        #expect(!isMarked(typo, in: view), "the underline outlived the setting")
    }
}
