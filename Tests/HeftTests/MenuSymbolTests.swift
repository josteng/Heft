import AppKit
@testable import Heft
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
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // HeftTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/Heft/Views/SidebarView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let pattern = try Regex(#"symbol: "([^"]+)""#)
        var names: Set<String> = []
        for match in text.matches(of: pattern) {
            names.insert(String(match.output[1].substring ?? ""))
        }
        #expect(names.count >= 10, "the menus stopped naming their symbols")

        // A row built as a plain `Button(..., systemImage:)` misses the
        // rendering `MenuButton` pins, and comes out in the window's accent
        // colour while the rows beside it are drawn in the label's ink. Two
        // did, because their titles hold quotes and a rewrite skipped them.
        #expect(
            !text.contains("systemImage:"),
            "every menu row goes through MenuButton, symbols and all"
        )

        // And that row dims its symbol with itself. A pinned ink outranks
        // the dimming a disabled row does for its title, which left Paste
        // grey beside a full-strength icon.
        #expect(
            text.contains("@Environment(\\.isEnabled)"),
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
