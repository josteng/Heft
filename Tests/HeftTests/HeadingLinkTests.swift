import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// Following `[[Note#Heading]]` to the heading rather than to the top.
///
/// The two halves existed long before the link did: `NoteText.lineOfHeading`
/// answers where a heading is, and `open(_:revealingLine:)` is what a search
/// hit already uses. `follow` resolved the note and dropped the heading, so
/// every sectioned link landed on line one.
@MainActor
@Suite("Heading links")
struct HeadingLinkTests {

    /// Line numbers here are 1-based, counted over the whole file, which is
    /// the convention a search hit carries and a reveal expects. The core
    /// helpers underneath count from 0; `AppModel.line(of:in:)` is where the
    /// two meet, and getting that wrong is why this feature did nothing.
    private static let note = """
    # Note
    intro

    ## Second
    under second

    ## Third
    under third
    """

    // MARK: - Which line a link names

    @Test("A heading link names the heading's line")
    func headingLine() {
        let link = WikiLink(target: "Note", heading: "Third")
        #expect(AppModel.line(of: link, in: Self.note) == 7)
    }

    @Test("A different heading names a different line")
    func anotherHeadingIsElsewhere() {
        let link = WikiLink(target: "Note", heading: "Second")
        #expect(AppModel.line(of: link, in: Self.note) == 4)
    }

    /// Obsidian matches a heading however it was capitalised in the link.
    @Test("Matching a heading ignores case")
    func matchingIgnoresCase() {
        let link = WikiLink(target: "Note", heading: "tHiRd")
        #expect(AppModel.line(of: link, in: Self.note) == 7)
    }

    @Test("A link with no heading names no line")
    func noHeadingNoLine() {
        #expect(AppModel.line(of: WikiLink(target: "Note"), in: Self.note) == nil)
    }

    @Test("A heading the note does not have names no line")
    func unknownHeadingNamesNoLine() {
        let link = WikiLink(target: "Note", heading: "Fourth")
        #expect(AppModel.line(of: link, in: Self.note) == nil)
    }

    /// Frontmatter is counted, unlike in an embed: the editor shows it, so a
    /// heading under it is further down the file than the body alone suggests.
    @Test("Frontmatter counts toward the line")
    func frontmatterCounts() {
        let source = """
        ---
        title: x
        ---

        # After
        """
        let link = WikiLink(target: "Note", heading: "After")
        #expect(AppModel.line(of: link, in: source) == 5)
    }

    /// `NoteText.headings` skips fences, and navigation inherits that: a `#`
    /// line inside a shell snippet is a comment, not a destination.
    @Test("A heading inside a fence is not a destination")
    func fencedHeadingIsNotADestination() {
        let source = """
        # Top

        ```
        # Fake
        ```

        ## Real
        """
        #expect(AppModel.line(of: WikiLink(target: "N", heading: "Fake"), in: source) == nil)
        #expect(AppModel.line(of: WikiLink(target: "N", heading: "Real"), in: source) == 7)
    }

    /// `#^id` parses as both a heading and a block id, so the order matters.
    @Test("A block id wins over a heading of the same text")
    func blockIDWins() {
        let source = """
        # One
        a line ^mark

        ## mark
        """
        let link = WikiLink(target: "N", heading: "mark", blockID: "mark")
        #expect(AppModel.line(of: link, in: source) == 2)
    }

    // MARK: - What the line actually reveals

    /// The assertion that was missing, and the reason this shipped broken
    /// twice. A line number looks plausible whatever its base; only the text
    /// it reveals says whether it is right. The reveal path counts from 1 and
    /// the core helpers count from 0, so the raw index landed a line early.
    private func revealedText(_ link: WikiLink, in source: String) throws -> String {
        let line = try #require(AppModel.line(of: link, in: source))
        let range = try #require(NoteText.range(ofLine: line, in: source))
        return (source as NSString).substring(with: range)
    }

    @Test("The line a heading link names reveals that heading")
    func revealsTheHeadingItself() throws {
        let link = WikiLink(target: "Note", heading: "Third")
        #expect(try revealedText(link, in: Self.note) == "## Third")
    }

    @Test("A second heading reveals its own text, not its neighbour's")
    func revealsTheRightHeading() throws {
        let link = WikiLink(target: "Note", heading: "Second")
        #expect(try revealedText(link, in: Self.note) == "## Second")
    }

    /// A heading on the very first line is line 1, never 0. A reveal discards
    /// anything below 1, so this case did nothing at all rather than landing
    /// somewhere wrong, which is what made the bug look like a dead feature.
    @Test("A heading on the first line is line one, which a reveal accepts")
    func firstLineHeadingIsLineOne() throws {
        let link = WikiLink(target: "Note", heading: "Note")
        #expect(AppModel.line(of: link, in: Self.note) == 1)
        #expect(try revealedText(link, in: Self.note) == "# Note")
    }

    @Test("A heading under frontmatter reveals the heading")
    func revealsPastFrontmatter() throws {
        let source = """
        ---
        title: x
        ---

        # After
        """
        let link = WikiLink(target: "Note", heading: "After")
        #expect(try revealedText(link, in: source) == "# After")
    }

    @Test("A block link reveals the line carrying the marker")
    func revealsTheBlockLine() throws {
        let source = """
        # One
        a line ^mark

        ## mark
        """
        let link = WikiLink(target: "N", blockID: "mark")
        #expect(try revealedText(link, in: source) == "a line ^mark")
    }

    // MARK: - Following one through the model

    private func vault(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-heading-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func ready(_ model: AppModel) async throws -> AppModel {
        for _ in 0..<600 where model.tree == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tree != nil, "the vault never finished scanning")
        return model
    }

    private func model(_ root: URL, open: String?) -> AppModel {
        AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: open),
            host: ScriptedHost()
        )
    }

    @Test("Following a heading link opens the note at the heading")
    func followingRevealsTheHeading() async throws {
        let root = try vault(["Index.md": "See [[Note#Third]]\n", "Note.md": Self.note])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, open: "Index.md"))

        model.follow(WikiLink(target: "Note", heading: "Third"))
        #expect(model.current?.relativePath == "Note.md")
        #expect(model.pendingLineReveal == 7)
    }

    /// The same link without its heading is the control: without it, a reveal
    /// left over from anything else would make the test above pass by itself.
    @Test("Following a plain link reveals no line")
    func plainLinkRevealsNothing() async throws {
        let root = try vault(["Index.md": "See [[Note]]\n", "Note.md": Self.note])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, open: "Index.md"))

        model.follow(WikiLink(target: "Note"))
        #expect(model.current?.relativePath == "Note.md")
        #expect(model.pendingLineReveal == nil)
    }

    /// A heading that no longer exists, which is what a reader mid-rename has.
    /// Opening the note beats refusing to go anywhere.
    @Test("An unresolved heading still opens the note")
    func unknownHeadingStillOpens() async throws {
        let root = try vault(["Index.md": "See [[Note#Gone]]\n", "Note.md": Self.note])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, open: "Index.md"))

        model.follow(WikiLink(target: "Note", heading: "Gone"))
        #expect(model.current?.relativePath == "Note.md")
        #expect(model.pendingLineReveal == nil)
    }

    /// `[[#Heading]]` carries no target, which the index already resolves to
    /// the note on screen. It has to stay on that note rather than reopening
    /// something else.
    @Test("A link with no target jumps inside the open note")
    func sameNoteJump() async throws {
        let root = try vault(["Index.md": Self.note])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, open: "Index.md"))

        model.follow(WikiLink(target: "", heading: "Third"))
        #expect(model.current?.relativePath == "Index.md")
        #expect(model.pendingLineReveal == 7)
    }

    // MARK: - The click the reader actually makes

    /// The URL the live surface attaches to a wikilink, which is what a click
    /// hands back to the model.
    private func attachedURL(_ source: String) -> URL? {
        let storage = NSTextStorage(string: source)
        _ = LiveStyler.apply(
            to: storage, reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil),
            contentWidth: 600
        )
        var found: URL?
        storage.enumerateAttribute(
            .link, in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if let url = value as? URL {
                found = url
                stop.pointee = true
            }
        }
        return found
    }

    private func target(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "target" }?.value
    }

    /// The bug this suite missed the first time. Following carried the heading
    /// correctly and the rendered preview composed the whole link, but the live
    /// surface passed `link.target` alone, so a click arrived with the heading
    /// already gone and every sectioned link opened at the top.
    @Test("The live surface keeps the heading in the link it attaches")
    func liveSurfaceKeepsTheHeading() throws {
        let url = try #require(attachedURL("See [[Manual#Installing]] here\n"))
        #expect(target(of: url) == "Manual#Installing")
    }

    @Test("The live surface keeps a block id too")
    func liveSurfaceKeepsTheBlockID() throws {
        let url = try #require(attachedURL("See [[Manual#^answer]] here\n"))
        #expect(target(of: url) == "Manual#^answer")
    }

    @Test("A plain link still attaches just its target")
    func plainLinkAttachesItsTarget() throws {
        let url = try #require(attachedURL("See [[Manual]] here\n"))
        #expect(target(of: url) == "Manual")
    }

    /// End to end, the way the reader meets it: what the styler attached, put
    /// back through the handler a click calls. Every step above can be right
    /// and this still fail, which is exactly what happened.
    @Test("Clicking a heading link in the live surface reveals the heading")
    func clickingFromTheLiveSurfaceReveals() async throws {
        let root = try vault(["Index.md": "See [[Note#Third]]\n", "Note.md": Self.note])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await ready(model(root, open: "Index.md"))

        let url = try #require(attachedURL("See [[Note#Third]]\n"))
        #expect(model.handle(url: url))
        #expect(model.current?.relativePath == "Note.md")
        #expect(model.pendingLineReveal == 7)
    }
}
