import SwiftUI

/// The clear button in a palette's search field, following Finder's search bar.
///
/// Always present, rather than appearing only once something is typed: with a
/// sheet there is nowhere to click "outside" — macOS blocks it — so Escape was
/// the only way out, and nothing on screen said so. Keeping the button there
/// when the field is empty turns it into the visible exit.
///
/// One button, two jobs, in the order you need them: it clears the query while
/// there is one, and closes the palette once there is not. So a stray search
/// takes two clicks in the same spot to back out of entirely.
struct PaletteDismissButton: View {
    @Binding var query: String
    let dismiss: () -> Void

    private var isEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Button {
            if isEmpty { dismiss() } else { query = "" }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isEmpty ? "Close (esc)" : "Clear")
        .accessibilityLabel(isEmpty ? "Close" : "Clear search")
    }
}
