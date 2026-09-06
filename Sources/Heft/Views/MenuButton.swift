import SwiftUI

/// One row of a context menu: a title, a symbol, and what it does.
///
/// The symbol is drawn in the text's own colour. The whole scene carries the
/// reader's accent as its tint, and a menu icon left to inherit that comes
/// out accent-coloured, which no menu on the system does: macOS 26 draws
/// them in the label's ink.
struct MenuButton<Title: StringProtocol>: View {
    /// A disabled row dims its title by itself, but not a symbol given a
    /// colour of its own: the pinned ink outranks the dimming, and Paste
    /// with an empty pasteboard came out grey text beside a full-strength
    /// icon. The row's own state is read back and the ink follows it.
    @Environment(\.isEnabled) private var isEnabled

    let title: Title
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: Title, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
        }
        .tint(isEnabled ? Color.primary : Color.secondary)
    }
}
