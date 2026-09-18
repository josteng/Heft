import AppKit
import HeftCore
import Testing
@testable import Heft

/// Where the drawn bullet sits when the source marker is spelled oddly.
///
/// The glyph is placed relative to the item's text edge, and that edge does
/// not move for extra whitespace, because the whole marker is collapsed while
/// the glyph is on screen. So neither may the glyph.
@MainActor
@Suite("List glyph offset")
struct ListGlyphOffsetTests {
    private let font = NSFont.systemFont(ofSize: 13)

    private func offset(_ marker: String, _ kind: ListMarkerKind) -> CGFloat {
        LiveStyler.listGlyphOffset(marker: marker, kind: kind, font: font)
    }

    @Test("Extra spaces after a bullet do not move it")
    func spacesDoNotMoveTheBullet() {
        let kind = ListMarkerKind.bullet(shape: .disc)
        let ordinary = offset("- ", kind)
        #expect(offset("-  ", kind) == ordinary)
        #expect(offset("-   ", kind) == ordinary)
        #expect(offset("-       ", kind) == ordinary)
    }

    @Test("A tab after a bullet does not move it either")
    func aTabDoesNotMoveTheBullet() {
        let kind = ListMarkerKind.bullet(shape: .disc)
        #expect(offset("-\t", kind) == offset("- ", kind))
    }

    /// The quoted-list path hands over the marker with its indentation still
    /// attached, where the plain path has already stripped it.
    @Test("Indentation before the marker does not move it")
    func indentationDoesNotMoveTheBullet() {
        let kind = ListMarkerKind.bullet(shape: .disc)
        let ordinary = offset("- ", kind)
        #expect(offset("\t- ", kind) == ordinary)
        #expect(offset("    - ", kind) == ordinary)
    }

    @Test("Ordered and task markers hold still too")
    func theOtherKindsHoldStill() {
        #expect(offset("1.   ", .ordered) == offset("1. ", .ordered))
        #expect(offset("- [ ]   ", .task(.unchecked)) == offset("- [ ] ", .task(.unchecked)))
        #expect(offset("-  [ ] ", .task(.unchecked)) == offset("- [ ] ", .task(.unchecked)))
    }

    /// Measuring the marker is the point, so a canonical spelling that threw
    /// the marker away and answered from the kind alone would satisfy every
    /// test above: the three kinds read their token out of the `kind`, so they
    /// would still land in three different places. A two-digit number is the
    /// assertion that needs the marker's own text.
    @Test("A wider number sits further out")
    func theMarkerItselfIsMeasured() {
        #expect(offset("10. ", .ordered) != offset("1. ", .ordered))
        #expect(offset("100. ", .ordered) != offset("10. ", .ordered))
    }

    @Test("The kinds still sit in different places")
    func theKindsStillDiffer() {
        let bullet = offset("- ", .bullet(shape: .disc))
        let ordered = offset("1. ", .ordered)
        let task = offset("- [ ] ", .task(.unchecked))
        #expect(bullet != ordered)
        #expect(bullet != task)
        #expect(ordered != task)
        // All of them are drawn in the gutter, left of the text they label.
        #expect(bullet < 0 && ordered < 0 && task < 0)
    }
}
