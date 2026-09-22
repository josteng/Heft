import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Inline code and maths in a paragraph follow the view's font scale.
///
/// Presentation draws at twice the size; a paragraph passed the scale to its
/// prose only, so `code` sat at the reading size in a line twice as tall.
@MainActor
@Suite("Paragraphs scale their inline code and maths")
struct PresentationScaleTests {

    private let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)

    private func runs(_ inlines: [MDInline], scale: CGFloat) -> [InlineRun] {
        ParagraphView.pieces(
            inlines, context: context, font: Theme.body(scale: scale), fontScale: scale
        ).flatMap { piece -> [InlineRun] in
            if case .text(let runs) = piece { return runs }
            return []
        }
    }

    @Test("Inline code is set in the scaled monospaced face")
    func codeScales() throws {
        let styled = runs([.text("Finished "), .code("hancas")], scale: 2).compactMap { run in
            if case .styled(let text) = run { return text }
            return nil
        }
        let code = try #require(styled.flatMap { Array($0.runs) }.last { run in
            run.font == Theme.mono(scale: 2)
        })
        #expect(code.font == Theme.mono(scale: 2))
        #expect(!styled.flatMap { Array($0.runs) }.contains { $0.font == Theme.mono(scale: 1) })
    }

    @Test("Inline maths is typeset at the scaled size")
    func mathScales() throws {
        func height(_ scale: CGFloat) -> CGFloat? {
            for run in runs([.math("x^2", display: false)], scale: scale) {
                if case .math(let image) = run { return image.size.height }
            }
            return nil
        }
        let normal = try #require(height(1))
        let doubled = try #require(height(2))
        #expect(doubled > normal * 1.5)
    }
}
