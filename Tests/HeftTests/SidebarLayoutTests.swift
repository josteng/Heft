import Foundation
import Testing
@testable import Heft

/// Which sidebar views show, in what order, and where a window starts.
@Suite("Sidebar layout")
struct SidebarLayoutTests {

    private func layout(_ shown: [(SidebarMode, Bool)], start: SidebarLayout.Start = .first) -> SidebarLayout {
        SidebarLayout(entries: shown.map { .init(mode: $0.0, isShown: $0.1) }, start: start)
    }

    @Test("The views shown, in the reader's order; Files when none is")
    func visible() {
        #expect(SidebarLayout.standard.visible == [.files, .recent, .tags])
        #expect(layout([(.recent, true), (.files, true), (.tags, false)]).visible == [.recent, .files])
        #expect(layout([(.files, false), (.recent, false), (.tags, false)]).visible == [.files])
    }

    /// ⌘1 is the first view shown, whatever it is.
    @Test("⌘1 to ⌘3 number the views shown")
    func shortcuts() {
        let reordered = layout([(.recent, true), (.tags, false), (.files, true)])
        #expect(reordered.mode(forShortcut: 1) == .recent)
        #expect(reordered.mode(forShortcut: 2) == .files)
        #expect(reordered.mode(forShortcut: 3) == nil, "only two are shown")
        let one = layout([(.recent, true), (.tags, false), (.files, false)])
        #expect(one.mode(forShortcut: 1) == nil, "one view has nothing to switch to")
    }

    @Test("A window opens on the first view, or the last one used if it is shown")
    func start() {
        let first = layout([(.recent, true), (.files, true), (.tags, true)])
        #expect(first.initialMode(lastUsed: .tags) == .recent)
        let last = layout([(.recent, true), (.files, true), (.tags, false)], start: .lastUsed)
        #expect(last.initialMode(lastUsed: .files) == .files)
        #expect(last.initialMode(lastUsed: .tags) == .recent, "a hidden view is not reopened")
        #expect(last.initialMode(lastUsed: nil) == .recent)

        // A named view, whatever the order, until it is hidden.
        let recentFirst = layout([(.files, true), (.recent, true), (.tags, true)], start: .view(.recent))
        #expect(recentFirst.initialMode(lastUsed: .tags) == .recent)
        let hidden = layout([(.files, true), (.recent, false), (.tags, true)], start: .view(.recent))
        #expect(hidden.initialMode(lastUsed: nil) == .files)
        for start in SidebarLayout.Start.allCases {
            #expect(SidebarLayout.Start(rawValue: start.rawValue) == start)
        }
    }

    @Test("The last view shown cannot be switched off")
    func lastStays() {
        let one = layout([(.files, false), (.recent, true), (.tags, false)])
        #expect(!one.canHide(.recent))
        #expect(one.canHide(.files), "already off")
        #expect(SidebarLayout.standard.canHide(.tags))
    }

    @Test("A view switched off while showing gives way to the first shown")
    func givesWay() {
        let noTags = layout([(.files, true), (.recent, true), (.tags, false)])
        #expect(noTags.shown(.tags) == .files)
        #expect(noTags.shown(.recent) == .recent)
    }

    @Test("Stored and read back; a view the stored order lacks is appended")
    func storage() throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.stenglein.Heft.sidebar-\(UUID().uuidString)"))
        #expect(SidebarLayout.current(in: defaults) == .standard)
        let saved = layout([(.tags, false), (.recent, true), (.files, true)], start: .lastUsed)
        saved.save(in: defaults)
        #expect(SidebarLayout.current(in: defaults) == saved)

        defaults.set(["recent"], forKey: "dev.stenglein.Heft.sidebar.order")
        #expect(SidebarLayout.current(in: defaults).entries.map(\.mode) == [.recent, .files, .tags])
        SidebarLayout.recordLastUsed(.tags, in: defaults)
        #expect(SidebarLayout.lastUsed(in: defaults) == .tags)
    }
}

/// The right side's views: the same layout, stored apart from the left's.
@Suite("Right sidebar layout")
@MainActor
struct InspectorLayoutTests {

    @Test("Stored under its own keys, so the left side's order is untouched")
    func storedApart() throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.stenglein.Heft.inspector-\(UUID().uuidString)"))
        let left = SidebarLayout(entries: [.init(mode: .tags, isShown: true), .init(mode: .files, isShown: false),
                                           .init(mode: .recent, isShown: true)], start: .lastUsed)
        left.save(in: defaults)
        #expect(InspectorLayout.current(in: defaults) == .standard)

        let right = InspectorLayout(entries: [.init(mode: .chats, isShown: true), .init(mode: .backlinks, isShown: true)],
                                    start: .view(.chats))
        right.save(in: defaults)
        #expect(InspectorLayout.current(in: defaults) == right)
        #expect(SidebarLayout.current(in: defaults) == left)
        #expect(defaults.stringArray(forKey: "dev.stenglein.Heft.sidebar.order") == ["tags", "files", "recent"],
                "the left side keeps the keys it always had")

        InspectorLayout.recordLastUsed(.chats, in: defaults)
        #expect(InspectorLayout.lastUsed(in: defaults) == .chats)
        #expect(SidebarLayout.lastUsed(in: defaults) == nil)
    }

    @Test("A view that cannot show leaves the switch, the shortcuts and the start")
    func offering() {
        let both = InspectorLayout(entries: [.init(mode: .chats, isShown: true), .init(mode: .backlinks, isShown: true)],
                                   start: .view(.chats))
        #expect(both.mode(forShortcut: 1) == .chats)
        #expect(both.mode(forShortcut: 2) == .backlinks)
        let noChats = both.offering { $0 != .chats }
        #expect(noChats.visible == [.backlinks])
        #expect(noChats.mode(forShortcut: 1) == nil, "one view has nothing to switch to")
        #expect(noChats.initialMode(lastUsed: .chats) == .backlinks)
        // Backlinks switched off and Chats unavailable still leaves a view.
        let neither = InspectorLayout(entries: [.init(mode: .backlinks, isShown: false), .init(mode: .chats, isShown: true)],
                                      start: .first).offering { $0 != .chats }
        #expect(neither.visible == [.backlinks])
    }

    @Test("The last view ticked keeps its box")
    func lastTicked() {
        let both = InspectorLayout.standard
        #expect(!PanelLayoutRows.isLastShown(.backlinks, in: both))
        var onlyAsk = both
        onlyAsk.entries[0].isShown = false
        #expect(PanelLayoutRows.isLastShown(.chats, in: onlyAsk))
        #expect(!PanelLayoutRows.isLastShown(.backlinks, in: onlyAsk), "already off")
    }
}
