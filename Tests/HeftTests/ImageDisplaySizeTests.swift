import Foundation
import HeftCore
import Testing

/// How big an embedded picture is drawn. Obsidian writes the wanted size into
/// the link — `![[shot.png|500]]`, or `|500x300` — and it was ignored, so a
/// picture scaled down for a note came out at whatever it was saved at.
@Suite("Embedded picture sizes")
struct ImageDisplaySizeTests {

    private let natural = CGSize(width: 400, height: 300)

    @Test("A width in the link is honoured, and keeps the shape")
    func widthFromTheLink() {
        let sized = ImageDisplaySize.resolve(natural: natural, width: 200, maxWidth: 460)
        #expect(sized == CGSize(width: 200, height: 150))
    }

    @Test("Both numbers are taken exactly, shape or no shape")
    func widthAndHeight() {
        let sized = ImageDisplaySize.resolve(
            natural: natural, width: 100, height: 100, maxWidth: 460
        )
        #expect(sized == CGSize(width: 100, height: 100))
    }

    @Test("A height on its own works out the width")
    func heightAlone() {
        let sized = ImageDisplaySize.resolve(natural: natural, height: 150, maxWidth: 460)
        #expect(sized == CGSize(width: 200, height: 150))
    }

    /// Whatever was asked for, a picture wider than the room is worse than a
    /// smaller picture.
    @Test("Nothing is ever wider than the room it has")
    func neverWiderThanTheRoom() {
        #expect(ImageDisplaySize.resolve(natural: natural, width: 900, maxWidth: 200).width == 200)
        #expect(ImageDisplaySize.resolve(natural: natural, maxWidth: 200).width == 200)
    }

    /// In prose a small picture stays small; in a table cell it grows into the
    /// column, which is what Obsidian draws.
    @Test("Filling is what separates a cell from prose")
    func fillingOnlyWhereAsked() {
        let small = CGSize(width: 40, height: 30)
        #expect(ImageDisplaySize.resolve(natural: small, maxWidth: 300) == small)
        #expect(
            ImageDisplaySize.resolve(natural: small, maxWidth: 300, fills: true)
                == CGSize(width: 300, height: 225)
        )
        // A size in the link still wins over filling.
        #expect(
            ImageDisplaySize.resolve(natural: small, width: 80, maxWidth: 300, fills: true).width
                == 80
        )
    }

    @Test("A picture with no size of its own does not divide by zero")
    func degenerateImage() {
        let sized = ImageDisplaySize.resolve(natural: .zero, maxWidth: 120)
        #expect(sized.width == 120 && sized.height == 120)
    }
}
