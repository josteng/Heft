import SwiftUI
import UIKit

/// A few choices as one glass capsule: icon and name, the chosen one under a
/// highlight. A tap slides the highlight over with a click; a sideways swipe
/// on the sheet around it (`switchSwipe`) moves the highlight under the finger
/// and settles it where it was heading. Capture's destinations and New
/// Note's Note and Folder, so the two sheets choose the same way.
struct GlassSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String, symbol: String)]
    /// Where a swipe has the highlight, counted in options from the first,
    /// while one is under way; nil otherwise.
    var dragged: CGFloat?
    /// Only the chosen option named, the others by their icon: three in a
    /// phone's width beside a close button.
    var compact = false
    @State private var frames: [Int: CGRect] = [:]
    @State private var taps = 0

    private var chosenIndex: Int { options.firstIndex { $0.value == selection } ?? 0 }
    private var along: CGFloat { dragged ?? CGFloat(chosenIndex) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                // Mid-swipe, the name the highlight is nearer takes the colour.
                let lit = Int(along.rounded()) == index
                Button {
                    guard option.value != selection else { return }
                    taps += 1
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = option.value }
                } label: {
                    // Named, not just drawn: a bar shows labels as icons alone
                    // unless told otherwise.
                    Label(option.title, systemImage: option.symbol)
                        .labelStyle(TitleWhen(shown: !compact || lit))
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .foregroundStyle(lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("glassSwitch")) } action: {
                    frames[index] = $0
                }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .background(alignment: .topLeading) { highlight }
        .coordinateSpace(.named("glassSwitch"))
        .padding(4)
        .glassEffect(in: .capsule)
        .sensoryFeedback(.selection, trigger: taps)
    }

    /// Between the two options either side of `along`, by how far along.
    @ViewBuilder private var highlight: some View {
        let lower = Int(along.rounded(.down)), upper = min(Int(along.rounded(.up)), options.count - 1)
        if let from = frames[lower], let to = frames[upper] {
            let t = along - CGFloat(lower)
            Capsule().fill(.tint.opacity(0.18))
                .frame(width: from.width + (to.width - from.width) * t, height: from.height)
                .offset(x: from.minX + (to.minX - from.minX) * t, y: from.minY)
        }
    }
}

extension View {
    /// Sideways finger swipes anywhere on this view move `selection` through
    /// `values`, the first on the left, with `dragged` following the finger
    /// for a `GlassSwitch` to draw. Past halfway or flicked it switches,
    /// short of that it springs back, and it clicks as the highlight crosses
    /// a middle under the finger, as a detent. A drag that is mostly vertical
    /// is left alone, for the sheet and for selecting text.
    func switchSwipe<Value: Hashable>(_ selection: Binding<Value>, among values: [Value],
                                      dragged: Binding<CGFloat?>) -> some View {
        modifier(SwitchSwipe(selection: selection, values: values, dragged: dragged))
    }
}

private struct SwitchSwipe<Value: Hashable>: ViewModifier {
    @Binding var selection: Value
    let values: [Value]
    @Binding var dragged: CGFloat?
    /// Where a swipe last clicked, while it is under way.
    @State private var clickedAt: Int?
    @State private var clicks = 0

    /// How far a swipe goes for the highlight to move one place.
    private static var span: CGFloat { 180 }

    private var rest: Int { values.firstIndex(of: selection) ?? 0 }

    private func along(after width: CGFloat) -> CGFloat {
        min(CGFloat(values.count - 1), max(0, CGFloat(rest) - width / Self.span))
    }

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(FingerPan { translation in
                guard abs(translation.width) > abs(translation.height) else { return }
                let now = along(after: translation.width)
                dragged = now
                let nearer = Int(now.rounded())
                if nearer != (clickedAt ?? rest) {
                    clickedAt = nearer
                    clicks += 1
                }
            } ended: { predicted in
                guard dragged != nil else { return }
                let next = Int(along(after: predicted.width).rounded())
                // A flick that switches without having crossed a
                // middle under the finger clicks as it is let go.
                if next != (clickedAt ?? rest) { clicks += 1 }
                clickedAt = nil
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                    selection = values[next]
                    dragged = nil
                }
            })
            .sensoryFeedback(.selection, trigger: clicks)
    }
}

/// A sideways pan for fingers only, alongside whatever else the sheet does.
///
/// A SwiftUI drag saw the Pencil too, and handwriting is mostly sideways
/// strokes longer than a drag's start: writing in Capture switched the
/// destination and cancelled Scribble. A UIKit pan can be told its touch
/// types, so the Pencil is left to write.
private struct FingerPan: UIGestureRecognizerRepresentable {
    let changed: (CGSize) -> Void
    /// Where the finger was heading when it let go, as a drag's predicted
    /// end: the translation carried on by a quarter second of its speed.
    let ended: (CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = context.coordinator
        // Text selection and the sheet's own drag keep working beneath it.
        pan.cancelsTouchesInView = false
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let moved = pan.translation(in: pan.view)
        switch pan.state {
        case .changed:
            changed(CGSize(width: moved.x, height: moved.y))
        case .ended, .cancelled:
            let speed = pan.velocity(in: pan.view)
            ended(CGSize(width: moved.x + speed.x * 0.25, height: moved.y + speed.y * 0.25))
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Title and icon, or the icon alone; the button keeps the title for
/// VoiceOver.
private struct TitleWhen: LabelStyle {
    var shown: Bool
    func makeBody(configuration: Configuration) -> some View {
        if shown {
            HStack(spacing: 6) { configuration.icon; configuration.title }
        } else {
            configuration.icon
        }
    }
}
