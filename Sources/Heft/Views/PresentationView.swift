import AppKit
import HeftCore
import SwiftUI

struct PresentationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var slideIndex = 0
    @FocusState private var hasKeyboardFocus: Bool

    private var slides: [[MDBlock]] {
        PresentationDeck.slides(from: MarkdownModel.parse(model.text).blocks)
    }

    private var context: RenderContext {
        RenderContext(
            index: model.index,
            current: model.current,
            vaultRoot: model.vaultRoot,
            colorfulFormatting: appearance.colorfulFormattingEnabled,
            accentColor: appearance.accentColor,
            linkColor: appearance.linkColor,
            tagColor: appearance.tagColor,
            codeColor: appearance.codeColor,
            boldColor: appearance.boldColor,
            italicColor: appearance.italicColor,
            headingColors: (1...6).map { appearance.headingColor($0) }
        )
    }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).ignoresSafeArea()

            GeometryReader { viewport in
                ZStack {
                    slide(at: slideIndex, viewport: viewport.size)
                        .id(slideIndex)
                        .transition(.opacity)
                }
                .clipped()
                .animation(.easeInOut(duration: 0.20), value: slideIndex)
            }

            VStack {
                Spacer()
                ProgressBar(value: Double(slideIndex + 1) / Double(max(slides.count, 1)))
                    .frame(height: 5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(PresentationWindowBridge())
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(.leftArrow) { previous(); return .handled }
        .onKeyPress(.rightArrow) { next(); return .handled }
        .onKeyPress(.space) { next(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onDisappear { model.isPresentationPresented = false }
    }

    private func previous() {
        guard slideIndex > 0 else { return }
        slideIndex -= 1
    }

    private func next() {
        guard slideIndex + 1 < slides.count else { return }
        slideIndex += 1
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

private struct ProgressBar: View {
    @Environment(\.appAccent) private var accent

    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.primary.opacity(0.12)
                accent
                    .frame(width: geometry.size.width * value)
                    .animation(.easeInOut(duration: 0.42), value: value)
            }
        }
        .accessibilityLabel("Presentation progress")
        .accessibilityValue("\(Int(value * 100)) percent")
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
