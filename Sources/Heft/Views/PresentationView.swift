import AppKit
import HeftCore
import SwiftUI

struct PresentationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var slideIndex = 0
    /// Parsed when the note changes rather than on every body. The model
    /// publishes on every keystroke and every disk poll, and the body used to
    /// parse the whole note twice each time, including on the frame a slide
    /// change starts animating.
    @State private var slides: [[MDBlock]] = []
    @State private var pacing = SlidePacing()
    /// Counts changes, so the slide shown last is always drawn on top of one
    /// still fading out, whichever way the reader went.
    @State private var changes = 0
    @FocusState private var hasKeyboardFocus: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var context: RenderContext {
        var context = model.renderContext()
        context.appearance = RenderContext.appearance(for: colorScheme)
        return context
    }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).ignoresSafeArea()

            GeometryReader { viewport in
                ZStack {
                    if slides.indices.contains(slideIndex) {
                        slide(at: slideIndex, viewport: viewport.size)
                            // Opaque, so a slide still fading out underneath
                            // never shows its text through this one.
                            .background(Color(nsColor: .textBackgroundColor))
                            .id(slideIndex)
                            .zIndex(Double(changes))
                            .transition(.opacity)
                    }
                }
                .clipped()
            }

            // Not before the deck is parsed, or the bar opens full and then
            // animates back to the first slide.
            if !slides.isEmpty {
                VStack {
                    Spacer()
                    ProgressBar(value: Double(slideIndex + 1) / Double(slides.count))
                        .frame(height: 5)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(PresentationWindowBridge())
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onChange(of: model.text, initial: true) { _, text in
            slides = PresentationDeck.slides(from: MarkdownModel.parse(text).blocks)
            slideIndex = min(slideIndex, max(slides.count - 1, 0))
        }
        .onKeyPress(.leftArrow) { previous(); return .handled }
        .onKeyPress(.rightArrow) { next(); return .handled }
        .onKeyPress(.space) { next(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onDisappear { model.isPresentationPresented = false }
    }

    private func previous() {
        guard slideIndex > 0 else { return }
        go(to: slideIndex - 1)
    }

    private func next() {
        guard slideIndex + 1 < slides.count else { return }
        go(to: slideIndex + 1)
    }

    private func go(to index: Int) {
        var transaction = Transaction(animation: pacing.animation())
        transaction.disablesAnimations = transaction.animation == nil
        withTransaction(transaction) {
            changes += 1
            slideIndex = index
        }
    }

    private func close() {
        model.isPresentationPresented = false
        dismissWindow(id: "presentation")
    }

    private func slide(at index: Int, viewport: CGSize) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            MarkdownView(blocks: slides[index], context: context)
                .environment(\.markdownFontScale, 2)
                .frame(maxWidth: 1050, alignment: .leading)
                .padding(.horizontal, 88)
                .padding(.vertical, 64)
                .frame(
                    minWidth: viewport.width,
                    minHeight: viewport.height,
                    alignment: .center
                )
        }
        .frame(width: viewport.width, height: viewport.height)
    }
}

/// When a change of slide cross-fades.
///
/// Held or quickly tapped arrows used to start a fade on every press, so two
/// or three half-faded slides were drawn at once and the text flickered. A
/// change arriving before the last fade could finish is made at once; the
/// progress bar still moves smoothly, since it animates from where it is.
struct SlidePacing {
    static let fade: TimeInterval = 0.20
    private var lastChange = Date.distantPast

    mutating func animation(at now: Date = Date()) -> Animation? {
        defer { lastChange = now }
        guard now.timeIntervalSince(lastChange) >= Self.fade else { return nil }
        return .easeInOut(duration: Self.fade)
    }
}

private struct ProgressBar: View {
    @Environment(\.appAccent) private var accent

    let value: Double

    var body: some View {
        ProgressFill(value: value, color: NSColor(accent))
            .background(Color.primary.opacity(0.12))
            .accessibilityElement()
            .accessibilityLabel("Presentation progress")
            .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The filled part of the bar, animated by Core Animation.
///
/// A SwiftUI width animation is interpolated on the main thread, frame by
/// frame, and a slide change is exactly when the main thread is busiest: the
/// next slide is laid out at twice the size and its pictures are decoded on
/// first draw. The bar stuttered through every one of those. A layer
/// animation runs in the render server and does not wait for any of it.
struct ProgressFill: NSViewRepresentable {
    let value: Double
    let color: NSColor

    func makeNSView(context: Context) -> FillView { FillView() }

    func updateNSView(_ view: FillView, context: Context) {
        view.color = color
        view.setValue(value)
    }

    final class FillView: NSView {
        static let stepDuration: CFTimeInterval = 0.42

        let fill = CALayer()
        private var value: Double?
        /// Keys the running steps apart, so a new one joins them rather
        /// than replacing one.
        private var steps = 0

        var color: NSColor = .controlAccentColor {
            didSet { updateColor() }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            fill.anchorPoint = .zero
            fill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(fill)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func setValue(_ new: Double) {
            let old = value
            value = new
            guard let old, old != new else {
                place()
                return
            }
            // Additive: each change animates only its own step, from minus
            // the step to nothing, on top of the ones still running. Replacing
            // the running animation instead restarted an ease-in from rest on
            // every key repeat, so a held arrow left the bar trembling where
            // it started until the key was let go.
            let from = fill.bounds.width
            place()
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.isAdditive = true
            animation.fromValue = from - fill.bounds.width
            animation.toValue = 0
            animation.duration = Self.stepDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(animation, forKey: "progress-\(steps)")
            steps += 1
        }

        override func layout() {
            super.layout()
            place()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func place() {
            fill.position = .zero
            fill.bounds = CGRect(
                x: 0, y: 0,
                width: bounds.width * min(max(value ?? 0, 0), 1),
                height: bounds.height
            )
        }

        private func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fill.backgroundColor = color.cgColor
            }
        }
    }
}

private struct PresentationWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            DispatchQueue.main.async {
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
}
