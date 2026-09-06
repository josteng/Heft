import AppKit
@testable import Heft
@testable import HeftCore
import Foundation
import Testing

/// Every symbol named in the sidebar's menus has to exist, or macOS draws a
/// blank where the icon goes and nothing says so.
///
/// Read out of the source rather than listed here: a list would be a second
/// place to update, and the one that is never updated is the copy.
@Suite("Menu symbols")
struct MenuSymbolTests {
    @Test("Every systemImage in the sidebar resolves to a real SF Symbol")
    func symbolsResolve() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // HeftTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
        // Every menu Heft builds for itself, the AppKit one included.
        let sources = [
            "Sources/Heft/Views/SidebarView.swift",
            "Sources/Heft/Views/MenuButton.swift",
            "Sources/Heft/Views/CalendarPanel.swift",
            "Sources/Heft/Views/ReviewCenter.swift",
            "Sources/Heft/TableSurface.swift",
        ]
        let text = try sources
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        let pattern = try Regex(#"symbol: "([^"]+)"|systemSymbolName: "([^"]+)""#)
        var names: Set<String> = []
        for match in text.matches(of: pattern) {
            for index in 1...2 where match.output[index].substring != nil {
                names.insert(String(match.output[index].substring ?? ""))
            }
        }
        #expect(names.count >= 10, "the menus stopped naming their symbols")

        // A row built as a plain `Button(..., systemImage:)` misses the
        // rendering `MenuButton` pins, and comes out in the window's accent
        // colour while the rows beside it are drawn in the label's ink. Two
        // did, because their titles hold quotes and a rewrite skipped them.
        #expect(names.count >= 18, "a menu stopped carrying symbols")

        // The sidebar's menus are all rows of `MenuButton`. One built the
        // plain way misses the rendering that view pins and comes out in the
        // window's accent colour beside its neighbours, which is how two of
        // them did: their titles hold quotes and a rewrite skipped them.
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/Heft/Views/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(
            !sidebar.contains("systemImage:"),
            "every sidebar menu row goes through MenuButton, symbols and all"
        )

        // And that row dims its symbol with itself. A pinned ink outranks the
        // dimming a disabled row does for its title, which left Paste grey
        // beside a full-strength icon.
        let menuRow = try String(
            contentsOf: root.appendingPathComponent("Sources/Heft/Views/MenuButton.swift"),
            encoding: .utf8
        )
        #expect(
            menuRow.contains("@Environment(\\.isEnabled)"),
            "the menu row reads back whether it is enabled, to dim its symbol"
        )
        for name in names.sorted() {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                Comment(rawValue: "no such SF Symbol: \(name)")
            )
        }
    }
}

/// Whether a reveal moves the list. The rule alone, since whether a row is on
/// screen is a number the view measures and this is what it decides with.
@Suite("Revealing without scrolling")
struct RevealScrollTests {
    private let viewport: CGFloat = 400

    @Test("A row fully on screen is left where it is")
    func visibleRowStaysPut() {
        #expect(!RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: 120, width: 200, height: 22), inViewportOfHeight: viewport
        ))
        // Flush with either edge still counts as seen.
        #expect(!RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: 0, width: 200, height: 22), inViewportOfHeight: viewport
        ))
        #expect(!RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: viewport - 22, width: 200, height: 22), inViewportOfHeight: viewport
        ))
    }

    @Test("A row above or below the viewport is scrolled to")
    func offscreenRowScrolls() {
        #expect(RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: -60, width: 200, height: 22), inViewportOfHeight: viewport
        ))
        #expect(RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: viewport + 10, width: 200, height: 22), inViewportOfHeight: viewport
        ))
        // Half off the bottom is not on screen enough to leave alone.
        #expect(RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: viewport - 10, width: 200, height: 22), inViewportOfHeight: viewport
        ))
    }

    /// A row nobody measured is a row nobody can see: the tree may not have
    /// built it yet, which is exactly when a reveal has to scroll.
    @Test("An unmeasured row, or no viewport at all, still scrolls")
    func unknownRowScrolls() {
        #expect(RevealScroll.needsScrolling(row: nil, inViewportOfHeight: viewport))
        // A viewport of no height is one that has not been measured, not a
        // window with nothing in it, so a row that looks like it sits at the
        // top of it is not taken as visible.
        #expect(RevealScroll.needsScrolling(
            row: CGRect(x: 0, y: 0, width: 200, height: 2), inViewportOfHeight: 0
        ))
    }
}

/// Which rows the tree draws as lit. The rule alone, since what a row looks
/// like is drawing and this is the decision behind it.
@Suite("Lit rows in the tree")
struct SidebarHighlightTests {
    @Test("The open note keeps its row while a revealed file is lit too")
    func bothAreLit() {
        // A PDF dropped in is marked, and the note being read stays selected.
        #expect(SidebarHighlight.litsFile(
            "Papers/Report.pdf", highlighted: "Papers/Report.pdf",
            current: "Index.md", selectedFolder: nil
        ))
        #expect(SidebarHighlight.litsFile(
            "Index.md", highlighted: "Papers/Report.pdf",
            current: "Index.md", selectedFolder: nil
        ))
    }

    @Test("A row that is neither is not lit")
    func othersAreDark() {
        #expect(!SidebarHighlight.litsFile(
            "Other.md", highlighted: "Papers/Report.pdf",
            current: "Index.md", selectedFolder: nil
        ))
    }

    /// A folder clicked in the tree takes the light off the open note, which
    /// is what makes the click visible at all.
    @Test("A clicked folder takes the light from the open note")
    func clickedFolderWins() {
        #expect(!SidebarHighlight.litsFile(
            "Index.md", highlighted: nil, current: "Index.md", selectedFolder: "Papers"
        ))
        #expect(SidebarHighlight.litsFolder(
            "Papers", highlighted: nil, selectedFolder: "Papers"
        ))
        #expect(!SidebarHighlight.litsFolder(
            "Papers", highlighted: nil, selectedFolder: "Ideas"
        ))
    }

    @Test("A folder pasted in is lit wherever the click was")
    func revealedFolderIsLit() {
        #expect(SidebarHighlight.litsFolder(
            "Papers copy", highlighted: "Papers copy", selectedFolder: "Ideas"
        ))
    }
}

/// What a review sheet stops the reader at. The rule alone: whether the band
/// is drawn is drawing, and this is the decision behind it.
@Suite("Warnings in the review sheet")
struct ReviewWarningTests {
    private func daily(folder: String = "Daily Notes") -> DailyNotes {
        var settings = ObsidianSettings()
        settings.dailyNotesFolder = folder
        settings.dailyNotesFolderIsConfigured = true
        return DailyNotes(vaultRoot: URL(fileURLWithPath: "/vault"), settings: settings)
    }

    @Test("A move out of the daily folder is worth stopping at")
    func movingOutWarns() {
        #expect(ReviewWarning.dailyDeparture(
            kind: .move, notePath: "Daily Notes/2026-09-06.md",
            destination: "Archive/2026-09-06.md", daily: daily()
        ) == "This note stops being a daily note. The calendar only looks in Daily Notes.")
    }

    @Test("A move inside the folder, or of an ordinary note, is not")
    func ordinaryMovesAreQuiet() {
        #expect(ReviewWarning.dailyDeparture(
            kind: .move, notePath: "Daily Notes/2026-09-06.md",
            destination: "Daily Notes/2026-09-08.md", daily: daily()
        ) == nil)
        #expect(ReviewWarning.dailyDeparture(
            kind: .move, notePath: "Plan.md", destination: "Archive/Plan.md", daily: daily()
        ) == nil)
    }

    /// Deleting a daily note says what it is in its own headline, and a
    /// warning that repeats the obvious is one people learn to skip.
    @Test("Deleting is not warned about, and neither is a vault with no daily folder")
    func deletesAndUnconfiguredVaults() {
        // Asked with somewhere to go, so it is the kind that decides and not
        // the missing destination a delete happens to have.
        #expect(ReviewWarning.dailyDeparture(
            kind: .delete, notePath: "Daily Notes/2026-09-06.md",
            destination: "Archive/2026-09-06.md", daily: daily()
        ) == nil)
        #expect(ReviewWarning.dailyDeparture(
            kind: .move, notePath: "Daily Notes/2026-09-06.md",
            destination: "Archive/2026-09-06.md", daily: nil
        ) == nil)
    }
}
