import AppKit
import HeftCore
import Testing
@testable import Heft

/// Two tags with one space between them both open their gap on the same
/// character, the last of the first tag: the first from behind, the second
/// looking back past the space. One padding there left the pills touching.
@MainActor
@Suite("Tag pills side by side")
struct TagSpacingTests {
    private func kern(before location: Int, in text: String) throws -> CGFloat {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        let view = PDFExport.renderView(text: text, context: context, width: 483)
        let storage = try #require(view.textStorage)
        return storage.attribute(.kern, at: location, effectiveRange: nil) as? CGFloat ?? 0
    }

    @Test("A tag followed by a word opens one gap; a tag followed by a tag opens two")
    func neighbouringTagsShareTheGap() throws {
        let padding = HeftLayoutFragment.tagPadding
        // "#heft word": the gap behind the first tag sits on its "t".
        #expect(try kern(before: 4, in: "#heft word\n") == padding)
        // "#heft #agents": the same "t" carries the second tag's gap too.
        #expect(try kern(before: 4, in: "#heft #agents\n") == padding * 2)
    }
}
