import AppKit
import HeftCore
import Testing
@testable import Heft

/// A click on a tag's pill opens the search narrowed to the tag; anywhere
/// else on its line is a click in the text.
@Suite("Clicking a tag")
@MainActor
struct TagClickTests {

    private static let note = "Plans for the #travel week\nThe list ends with #todo\n\nLast line."

    private func styled() -> HeftTextKit2View {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let editor = LiveTextEditor(
            text: .constant(Self.note), documentIdentity: "t.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = Self.note
        // The caret away from both tags, as when reading.
        view.setSelectedRange(NSRange(location: (Self.note as NSString).length, length: 0))
        coordinator.restyle(view)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    private func rect(of word: String, in view: HeftTextKit2View) throws -> CGRect {
        let range = (Self.note as NSString).range(of: word)
        return try #require(view.rect(forSelection: range))
    }

    @Test("The pill opens its tag")
    func pill() throws {
        let view = styled()
        let travel = try rect(of: "#travel", in: view)
        #expect(view.tag(at: NSPoint(x: travel.midX, y: travel.midY)) == "travel")
        let todo = try rect(of: "#todo", in: view)
        #expect(view.tag(at: NSPoint(x: todo.midX, y: todo.midY)) == "todo")
    }

    /// Past the end of a line that ends in a tag, the nearest character is
    /// still the tag's last one; that click means the end of the line.
    @Test("Beyond the pill is a click in the text")
    func beyond() throws {
        let view = styled()
        let todo = try rect(of: "#todo", in: view)
        #expect(view.tag(at: NSPoint(x: todo.maxX + 80, y: todo.midY)) == nil)
        let plans = try rect(of: "Plans", in: view)
        #expect(view.tag(at: NSPoint(x: plans.midX, y: plans.midY)) == nil)
        let last = try rect(of: "Last", in: view)
        #expect(view.tag(at: NSPoint(x: last.midX, y: last.midY)) == nil)
    }

    @Test("The pointer is a hand over a tag, as over a link")
    func hand() throws {
        let view = styled()
        let travel = try rect(of: "#travel", in: view)
        #expect(view.cursorOverride(at: NSPoint(x: travel.midX, y: travel.midY), among: []) == .pointingHand)
        let plans = try rect(of: "Plans", in: view)
        #expect(view.cursorOverride(at: NSPoint(x: plans.midX, y: plans.midY), among: []) == nil)
    }

    /// The iPad shows a tapped tag in its sidebar; the Mac does too, unless
    /// Tags is not one of the sidebar's views, when the bar takes it.
    @Test("A clicked tag opens in the sidebar's Tags, or in the bar without one")
    func routing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-tag-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GeneralSettings.shared.sidebarLayout
        defer { GeneralSettings.shared.sidebarLayout = layout }
        let model = AppModel(registry: VaultRegistry(), descriptor: WorkspaceDescriptor(vaultPath: root.path))
        defer { model.closeWorkspace() }

        GeneralSettings.shared.sidebarLayout = .standard
        model.showTag("travel")
        #expect(model.sidebarModeRequest == .tags)
        #expect(model.tagRevealRequest == "travel")
        #expect(model.bar == nil)

        model.sidebarModeRequest = nil
        model.tagRevealRequest = nil
        let tags = try #require(GeneralSettings.shared.sidebarLayout.entries.firstIndex { $0.mode == .tags })
        GeneralSettings.shared.sidebarLayout.entries[tags].isShown = false
        model.showTag("travel")
        #expect(model.tagRevealRequest == nil)
        #expect(model.bar?.scope == .tag("travel"))
    }
}
