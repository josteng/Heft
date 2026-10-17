import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// A web address pasted on its own, and the titles it can be linked as.
@Suite("Link titles for a pasted address")
struct PastedLinkTests {

    private func pasted(_ source: String, _ address: String, pasted: String? = nil) -> PastedLink? {
        let location = (source as NSString).range(of: address).location
        return PastedLink.after(pasting: pasted ?? address, at: location, in: source)
    }

    @Test("A bare address is found where it was pasted")
    func findsAddress() {
        #expect(pasted("See https://example.com/post", "https://example.com/post")
            == PastedLink(range: NSRange(location: 4, length: 24), address: "https://example.com/post"))
        // A copied address that brought its line break along.
        #expect(pasted("https://example.com\n", "https://example.com", pasted: "https://example.com\n") != nil)
    }

    @Test("Anything already a link, in code, or not an address is left alone")
    func leavesOthersAlone() {
        #expect(pasted("some words", "words") == nil)
        #expect(pasted("example.com", "example.com") == nil)
        #expect(pasted("`x https://example.com", "https://example.com") == nil)
        #expect(pasted("[a](https://example.com", "https://example.com") == nil)
        #expect(pasted("<https://example.com", "https://example.com") == nil)
        #expect(pasted("[[https://example.com", "https://example.com") == nil)
        #expect(pasted("```\nhttps://example.com", "https://example.com") == nil)
        #expect(pasted("x https://example.com", "https://example.com", pasted: "https://example.com more") == nil)
    }

    @Test("Linking escapes brackets and leaves the caret after the link")
    func linking() throws {
        let source = "See https://example.com/post"
        let link = try #require(pasted(source, "https://example.com/post"))
        let edit = link.linking("A [b] title")
        #expect(edit.applied(to: source) == "See [A \\[b\\] title](https://example.com/post)")
        #expect(edit.selection.location == (edit.applied(to: source) as NSString).length)
        #expect(link.isCurrent(in: source, caret: NSRange(location: 28, length: 0)))
        #expect(!link.isCurrent(in: source + "x", caret: NSRange(location: 29, length: 0)))
    }

    @Test("The site name drops www, and a title is one tidy line")
    func siteAndTitle() {
        #expect(PastedLink(range: NSRange(), address: "https://www.example.org/a").siteName == "example.org")
        #expect(PastedLink.cleanedTitle("  A\n   long   title ") == "A long title")
        #expect(PastedLink.cleanedTitle("  \n ") == nil)
        #expect(PastedLink.cleanedTitle(nil) == nil)
    }

    @Test("Short titles come one a line, tidied, without repeats")
    func shortTitlesCleaned() {
        #expect(LinkTitles.cleaned("1. Short one\n- \"Short one\"\nAnother.\nThe Page", avoiding: ["the page"])
            == ["Short one", "Another"])
    }
}

/// Holds a fetch back until the test lets it finish, so the moment between
/// the paste and the title can be looked at.
@MainActor
private final class Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
@Suite("Link titles in the editor", .serialized)
struct LinkTitleEditorTests {

    private func editor(_ text: String) -> (HeftTextKit2View, LiveTextEditor.Coordinator) {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(""), documentIdentity: "probe.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainer?.size = NSSize(width: 644, height: CGFloat.greatestFiniteMagnitude)
        view.textLayoutManager?.delegate = coordinator
        view.delegate = coordinator
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (view, coordinator)
    }

    /// Runs `body` with the network and the model replaced: the page title
    /// arrives when `gate` opens, and the model offers two short titles and
    /// a repeat of the page's own.
    private func withFakes(_ body: (Gate) async throws -> Void) async rethrows {
        let gate = Gate()
        let page = HeftTextKit2View.fetchPageTitle
        let short = HeftTextKit2View.fetchShortTitles
        let setting = TypingSettings.shared.suggestsLinkTitles
        let shortSetting = TypingSettings.shared.suggestsShortLinkTitles
        HeftTextKit2View.fetchPageTitle = { _ in
            await gate.wait()
            return "  The Post   Title "
        }
        HeftTextKit2View.fetchShortTitles = { _, _ in ["Post Title", "The Post", "The Post Title"] }
        TypingSettings.shared.suggestsLinkTitles = true
        TypingSettings.shared.suggestsShortLinkTitles = true
        defer {
            HeftTextKit2View.fetchPageTitle = page
            HeftTextKit2View.fetchShortTitles = short
            TypingSettings.shared.suggestsLinkTitles = setting
            TypingSettings.shared.suggestsShortLinkTitles = shortSetting
        }
        try await body(gate)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private let address = "https://www.example.com/post"

    @Test("The site name is offered at once, the titles as they arrive")
    func rowsArrive() async throws {
        try await withFakes { gate in
            let (view, coordinator) = editor("See " + address)
            view.offerLinkTitles(afterPasting: address, at: 4)
            #expect(view.visibleCompletions == ["example.com"])

            gate.open()
            await settle()
            #expect(view.visibleCompletions
                == ["The Post Title", "example.com", "Post Title", "The Post"])

            view.insertNewline(nil)
            #expect(view.string == "See [The Post Title](\(address))")
            #expect(view.visibleCompletions.isEmpty)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("A row chosen before the title arrives stays chosen")
    func choiceSurvivesArrival() async throws {
        try await withFakes { gate in
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            #expect(view.visibleCompletions.first == "example.com")
            gate.open()
            await settle()
            view.moveDown(nil)
            view.moveUp(nil)
            view.insertNewline(nil)
            #expect(view.string == "[The Post Title](\(address))")
            withExtendedLifetime(coordinator) {}
        }
        try await withFakes { gate in
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            // The site's name, chosen while it was the only row; the title
            // arriving above it does not take the choice away.
            view.moveDown(nil)
            gate.open()
            await settle()
            view.insertNewline(nil)
            #expect(view.string == "[example.com](\(address))")
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Escape keeps the address as it was pasted")
    func escapeKeepsAddress() async throws {
        try await withFakes { gate in
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            view.cancelOperation(nil)
            #expect(view.string == address)
            #expect(view.visibleCompletions.isEmpty)
            gate.open()
            await settle()
            #expect(view.visibleCompletions.isEmpty)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Typing on closes the menu, and a late title does not reopen it")
    func typingCloses() async throws {
        try await withFakes { gate in
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            view.insertText(" ", replacementRange: view.selectedRange())
            #expect(view.visibleCompletions.isEmpty)
            gate.open()
            await settle()
            #expect(view.visibleCompletions.isEmpty)
            #expect(view.string == address + " ")
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("A slow page's title never lands in a later paste's menu")
    func staleTitleIgnored() async throws {
        try await withFakes { gate in
            HeftTextKit2View.fetchPageTitle = { url in
                if url.path == "/slow" {
                    await gate.wait()
                    return "Slow Title"
                }
                return "Quick Title"
            }
            HeftTextKit2View.fetchShortTitles = { _, _ in [] }
            let slow = "https://example.com/slow", quick = "https://example.org/quick"
            let (view, coordinator) = editor(slow)
            view.offerLinkTitles(afterPasting: slow, at: 0)
            view.string = quick
            view.setSelectedRange(NSRange(location: (quick as NSString).length, length: 0))
            view.offerLinkTitles(afterPasting: quick, at: 0)
            await settle()
            gate.open()
            await settle()
            #expect(view.visibleCompletions == ["Quick Title", "example.org"])
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("With short titles off, the menu keeps the page's title and site")
    func shortTitlesOff() async throws {
        try await withFakes { gate in
            TypingSettings.shared.suggestsShortLinkTitles = false
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            gate.open()
            await settle()
            #expect(view.visibleCompletions == ["The Post Title", "example.com"])
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("With the setting off, a pasted address is only text")
    func settingOff() async throws {
        try await withFakes { gate in
            TypingSettings.shared.suggestsLinkTitles = false
            let (view, coordinator) = editor(address)
            view.offerLinkTitles(afterPasting: address, at: 0)
            #expect(view.visibleCompletions.isEmpty)
            gate.open()
            withExtendedLifetime(coordinator) {}
        }
    }
}
