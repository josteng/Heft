import AppKit
import QuartzCore
import Testing
@testable import Heft

/// The presentation bar is animated by Core Animation, not by SwiftUI.
///
/// A SwiftUI width animation is interpolated on the main thread, which is
/// busy laying out the next slide at exactly that moment, so the bar
/// stuttered. A layer animation runs in the render server.
@MainActor
@Suite("Presentation progress animates on the layer")
struct PresentationProgressTests {

    private func view() -> ProgressFill.FillView {
        let view = ProgressFill.FillView(frame: NSRect(x: 0, y: 0, width: 400, height: 5))
        view.layout()
        return view
    }

    @Test("The first value is placed, not animated")
    func firstValueIsPlaced() {
        let view = view()
        view.setValue(0.25)
        #expect(view.fill.bounds.width == 100)
        #expect(view.fill.animation(forKey: "progress") == nil)
    }

    @Test("A change of slide animates the width to where it is going")
    func changeAnimates() throws {
        let view = view()
        view.setValue(0.25)
        view.setValue(0.5)
        #expect(view.fill.bounds.width == 200)
        let animation = try #require(view.fill.animation(forKey: "progress") as? CABasicAnimation)
        #expect(animation.keyPath == "bounds.size.width")
        #expect(animation.fromValue as? CGFloat == 100)
        #expect(animation.toValue as? CGFloat == 200)
        #expect(animation.duration > 0.2)
    }
}

/// Held or quickly tapped arrows change slide without stacking fades.
@Suite("Slide changes fade only at a reading pace")
struct SlidePacingTests {

    @Test("A change sooner than the fade lasts is made at once")
    func quickChangesAreInstant() {
        var pacing = SlidePacing()
        let start = Date()
        #expect(pacing.animation(at: start) != nil, "the first change fades")
        #expect(pacing.animation(at: start + 0.05) == nil, "a held key does not")
        #expect(pacing.animation(at: start + 0.10) == nil)
        #expect(pacing.animation(at: start + 0.10 + SlidePacing.fade) != nil, "a pause fades again")
    }
}
