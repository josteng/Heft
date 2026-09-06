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

extension View {
    /// A control beside a two-line `SettingLabel` rides high: a form row
    /// aligns it on the label's first baseline, and a control with no text
    /// has none, while one with text sits centred on the title. This places
    /// it so that the control's top edge meets the top of the title's letters.
    func alignedWithTitle() -> some View {
        alignmentGuide(.firstTextBaseline) { $0[.top] + 13 }
    }
}

/// A menu of the vaults Heft remembers, with "the vault opened last" as the
/// empty choice, for the two settings that name a vault: where a Spotlight
/// capture goes, and what a start with nothing to restore opens.
struct VaultChoiceMenu: View {
    @EnvironmentObject private var registry: VaultRegistry
    /// A standardized vault path, or empty for the vault opened last.
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            Text("The vault opened last").tag("")
            ForEach(choices, id: \.path) { choice in
                Text("Always \(choice.label)").tag(choice.path)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// The remembered vaults, plus the chosen one if it has gone missing from
    /// them, so the menu still shows what is chosen.
    private var choices: [(path: String, label: String)] {
        var choices = registry.recentVaults.map {
            (path: $0.url.standardizedFileURL.path, label: $0.label)
        }
        if !selection.isEmpty, !choices.contains(where: { $0.path == selection }) {
            choices.append((path: selection, label: (selection as NSString).lastPathComponent))
        }
        return choices
    }
}
