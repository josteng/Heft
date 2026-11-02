import SwiftUI

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
                        .labelStyle(.titleAndIcon)
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
    /// Sideways swipes anywhere on this view move `selection` through
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                        let now = along(after: drag.translation.width)
                        dragged = now
                        let nearer = Int(now.rounded())
                        if nearer != (clickedAt ?? rest) {
                            clickedAt = nearer
                            clicks += 1
                        }
                    }
                    .onEnded { drag in
                        guard dragged != nil else { return }
                        let next = Int(along(after: drag.predictedEndTranslation.width).rounded())
                        // A flick that switches without having crossed a
                        // middle under the finger clicks as it is let go.
                        if next != (clickedAt ?? rest) { clicks += 1 }
                        clickedAt = nil
                        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                            selection = values[next]
                            dragged = nil
                        }
                    }
            )
            .sensoryFeedback(.selection, trigger: clicks)
    }
}
