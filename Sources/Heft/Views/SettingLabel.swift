import SwiftUI

// How every settings pane is laid out, taken from System Settings rather
// than invented: a grouped Form, where a card holds controls and nothing
// else. What one control does is written under that control's own name,
// inside its row. What a group of controls is for is written above the
// card, in the section header. Nothing goes in a footer, and no pane is a
// hand-built stack, so the seven tabs read as one window.

/// A control's name with what it does beneath it.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A group's name above its card, with what the group is for when that
/// needs saying.
struct SectionHeading: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
