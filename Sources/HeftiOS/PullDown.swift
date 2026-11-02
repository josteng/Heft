import SwiftUI
import UIKit

extension View {
    /// Pulling this list down past its top runs what Settings ▸ Browsing
    /// chose for `page`: a command, the search, or nothing. `overrides`
    /// gives a command a meaning of its own here, as a folder's New Note
    /// making the note in that folder.
    func pullDownAction(_ page: BrowsingPreferences.PullPage,
                        overrides: [String: () -> Void] = [:]) -> some View {
        modifier(PullDownAction(page: page, overrides: overrides))
    }
}

/// A pull down past the top of a list, made to do something.
///
/// In place of pull to refresh, which Refresh in the "…" menu does too: a
/// list's top is where the thumb already is, and capturing or starting a
/// note from there needs no reach for the bar. Past `threshold` a label says
/// what letting go will do, with a click as it arms; let go there and it
/// runs, short of it and nothing happens. Only the reader's own drag arms
/// it: a list flung back past its top does not.
private struct PullDownAction: ViewModifier {
    let page: BrowsingPreferences.PullPage
    let overrides: [String: () -> Void]
    @Environment(\.mobileLibrary) private var library
    @Environment(MobileVault.self) private var vault
    @State private var preferences = BrowsingPreferences.shared
    /// How far past the top the list is pulled.
    @State private var pulled: CGFloat = 0
    /// The list's top inset, from the screen's top: the bars above it, and
    /// on a page with one, the large title.
    @State private var insetTop: CGFloat = 0
    @State private var dragging = false
    @State private var armed = false

    private static let threshold: CGFloat = 80

    private var choice: String { preferences.pull(on: page) }

    func body(content: Content) -> some View {
        // Refresh keeps the system's own control: its spinner stays open
        // until the vault has been read again, which says more than a label.
        if choice == "refresh" {
            content.refreshable { await vault.refreshed() }
        } else {
            pulling(content)
        }
    }

    private func pulling(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, now in
                insetTop = now
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, now in
                pulled = now
                let arm = dragging && now >= Self.threshold && choice != BrowsingPreferences.PullChoice.off
                if arm != armed { armed = arm }
            }
            // The list's own pan says when a finger is on it and when it lets
            // go. SwiftUI's scroll phase was the first choice and, on a List,
            // never left idle: traced on a phone, a pull 320pt past the top
            // reported no drag at all, so nothing armed.
            .background(ScrollPanObserver { finger in
                if finger {
                    dragging = true
                } else {
                    dragging = false
                    if armed {
                        armed = false
                        run()
                    }
                }
            })
            .sensoryFeedback(.selection, trigger: armed) { _, now in now }
            .overlay(alignment: .top) {
                indicator.ignoresSafeArea(.container, edges: .top)
            }
            #if DEBUG
            // With the list pulled by `HEFT_IOS_PULL`, armed as a finger past
            // the threshold would leave it.
            .onAppear {
                if ProcessInfo.processInfo.environment["HEFT_IOS_PULL"].flatMap(Double.init).map({ $0 >= Self.threshold }) == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { armed = true }
                }
            }
            #endif
    }

    /// The large title's height: a pull opens its gap above the title, which
    /// moves down with the list, between it and the bar.
    private static let largeTitle: CGFloat = 52

    /// Where the gap a pull opens begins, from the screen's top: under the
    /// bar, above a large title where the page has one.
    private var gapTop: CGFloat {
        page == .search ? insetTop : insetTop - Self.largeTitle
    }

    /// In the gap the pull opens, centred in it as the refresh spinner sits:
    /// the command's symbol in a ring that fills toward the threshold, with
    /// its name, grey until letting go would run it, then in the accent with
    /// a click. The ring says how far is left, the colour that it is enough.
    @ViewBuilder private var indicator: some View {
        if let label, pulled > 12 {
            let progress = min(1, pulled / Self.threshold)
            let tint: AnyShapeStyle = armed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: label.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)
                // The command's name alone, the same text throughout: only the
                // colour says it is armed. Wording that changed ("Pull to",
                // "Release to") changed the line's width, and the line either
                // jumped sideways or kept a gap for the longer word.
                Text(label.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .animation(.snappy(duration: 0.18), value: armed)
            .opacity(min(1, (pulled - 12) / 28))
            .offset(y: gapTop + max(0, pulled / 2 - 15))
            .allowsHitTesting(false)
        }
    }

    private var label: (title: String, symbol: String)? {
        switch choice {
        case BrowsingPreferences.PullChoice.off: nil
        case BrowsingPreferences.PullChoice.search: ("Search", "magnifyingglass")
        default: MobileCommand.catalog.first { $0.id == choice }.map { ($0.title, $0.symbol) }
        }
    }

    private func run() {
        if let own = overrides[choice] { return own() }
        guard let library else { return }
        if choice == BrowsingPreferences.PullChoice.search {
            library.search(nil)
        } else {
            MobileCommand.action(choice, library)()
        }
    }
}

/// Tells whether a finger is dragging the scroll view this sits beside: the
/// `List` it is a background of, found by looking up from here and then
/// down for the nearest `UIScrollView`, whose pan gesture it then follows.
private struct ScrollPanObserver: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {
        context.coordinator.changed = changed
    }

    final class FinderView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Once the list beside it is in the window too.
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.nearestScrollView() else { return }
                self.coordinator?.follow(scroll)
            }
        }

        private func nearestScrollView() -> UIScrollView? {
            var level: UIView? = superview
            for _ in 0..<6 {
                guard let current = level else { return nil }
                if let found = Self.firstScrollView(in: current, skipping: self) { return found }
                level = current.superview
            }
            return nil
        }

        private static func firstScrollView(in view: UIView, skipping: UIView) -> UIScrollView? {
            for child in view.subviews where child !== skipping {
                if let scroll = child as? UIScrollView { return scroll }
                if let found = firstScrollView(in: child, skipping: skipping) { return found }
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var changed: (Bool) -> Void = { _ in }
        private weak var followed: UIScrollView?

        func follow(_ scroll: UIScrollView) {
            guard followed !== scroll else { return }
            followed?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            followed = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            #if DEBUG
            // `HEFT_IOS_PULL=<points>` pulls the list down that far, as a
            // finger holding it would, title and all.
            if let held = ProcessInfo.processInfo.environment["HEFT_IOS_PULL"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak scroll] in
                    guard let scroll else { return }
                    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top - held), animated: false)
                }
            }
            #endif
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: changed(true)
            case .ended, .cancelled, .failed: changed(false)
            default: break
            }
        }
    }
}
