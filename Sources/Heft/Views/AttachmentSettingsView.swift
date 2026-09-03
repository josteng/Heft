import HeftCore
import SwiftUI

/// Where pasted and dropped files go: every rule listed once, switched on or
/// off, in the reader's own order, and one line at the bottom saying what all
/// of that does to the note actually open.
struct AttachmentSettingsView: View {
    @EnvironmentObject private var registry: VaultRegistry
    @StateObject private var settings = AttachmentSettings.shared
    /// Bumped when the front window changes, purely to re-run the lookup.
    @State private var frontWindowChanges = 0

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(Array(settings.plan.entries.enumerated()), id: \.element.id) {
                        index, entry in
                        AttachmentRuleRow(
                            entry: entry,
                            obsidianSetting: obsidianSetting,
                            isReachable: settings.plan.isReachable(index),
                            canMoveUp: index > 0,
                            canMoveDown: index < settings.plan.entries.count - 1,
                            onChange: { settings.plan.entries[index] = $0 },
                            onMove: { move(index, by: $0) }
                        )
                    }
                    .onMove { settings.plan.entries.move(fromOffsets: $0, toOffset: $1) }
                }
                // Tall enough for every rule at once, which is what makes the
                // window come up the right size: each tab is sized to its own
                // content, so a list shorter than its rows does not get a
                // taller window, it scrolls inside a short one and hides the
                // very thing being ordered.
                .frame(height: rowsHeight)
                .alternatingRowBackgrounds()

                if settings.plan.entries.allSatisfy({ !$0.isEnabled }) {
                    // Everything off is a legitimate setting, and it has one
                    // consequence worth saying out loud rather than leaving to
                    // be discovered after a paste.
                    Label(
                        "Nothing is switched on, so every attachment goes to the "
                            + "top of the vault.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(
                        "Tried from the top; the first that finds a folder wins. "
                            + "Drag a rule, or use its arrows, to reorder. If none "
                            + "finds a folder, the file goes to the top of the vault."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Reset") { settings.reset() }
                        .disabled(settings.plan == .standard)
                }
            } header: {
                Text("Where attachments go")
            }

            Section("What that means for the note you have open") {
                if let model = registry.frontmostModel {
                    AttachmentPreview(model: model, plan: settings.plan)
                } else {
                    Text("Open a note to see where a pasted file would go.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        // Which window is in front is not something SwiftUI publishes, and
        // `frontmostModel` is a lookup rather than a binding, so without this
        // the pane keeps answering for whichever window was in front when it
        // opened.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            frontWindowChanges &+= 1
        }
        .id(frontWindowChanges)
    }

    /// Sized from the rules there actually are, so adding one later cannot
    /// quietly reintroduce the scroll.
    private var rowsHeight: CGFloat {
        CGFloat(settings.plan.entries.count) * 54 + 16
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.plan.entries.indices.contains(target) else { return }
        settings.plan.entries.swapAt(index, target)
    }

    private var obsidianSetting: String {
        (registry.frontmostModel?.settings.attachmentFolderPath ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Where the whole plan sends a file pasted into the open note.
    ///
    /// The only place an outcome is shown. Every row used to carry its own,
    /// which raised a question it could not answer — whether "finds nothing"
    /// meant this note, this vault, or ever.
    static func describe(_ plan: AttachmentPlan, for model: AppModel) -> String {
        guard let vaultRoot = model.vaultRoot else { return "the top of the vault" }
        let resolved = Attachments.Destination(
            rules: plan.rules, index: model.index, settings: model.settings
        ).resolve(vaultRoot: vaultRoot, noteURL: model.current?.url)

        if resolved.folder.isEmpty { return "the top of the vault" }
        return resolved.needsCreating && resolved.rule.mayCreate
            ? "\(resolved.folder)  (new folder)"
            : resolved.folder
    }
}

/// The one place an outcome is shown, and the only part of the pane that has to
/// keep up with the vault.
///
/// Split out so the model can be observed: Settings is its own scene and does
/// not re-render because a note was opened in another window, so the preview
/// sat on whatever had been open when the pane first appeared.
private struct AttachmentPreview: View {
    @ObservedObject var model: AppModel
    let plan: AttachmentPlan

    var body: some View {
        if let note = model.current {
            LabeledContent(note.relativePath) {
                Text(AttachmentSettingsView.describe(plan, for: model))
                    .foregroundStyle(.primary)
            }
        } else {
            Text("Open a note to see where a pasted file would go.")
                .foregroundStyle(.secondary)
        }
    }
}

struct AttachmentRuleRow: View {
    let entry: AttachmentPlan.Entry
    let obsidianSetting: String
    let isReachable: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: (AttachmentPlan.Entry) -> Void
    let onMove: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { var next = entry; next.isEnabled = $0; onChange(next) }
            ))
            .labelsHidden()
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(entry.isEnabled ? .medium : .regular)
                    if entry.choice.needsName {
                        TextField(placeholder, text: Binding(
                            get: { entry.folder },
                            set: { var next = entry; next.folder = $0; onChange(next) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .disabled(!entry.isEnabled)
                    }
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Buttons rather than dragging. The order is the whole point of
            // this list, and nothing about a row says it can be dragged.
            VStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help("Try this rule earlier")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .help("Try this rule later")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.top, 1)
        }
        .padding(.vertical, 7)
        .opacity(entry.isEnabled && isReachable ? 1 : 0.55)
    }

    private var title: String {
        switch entry.choice {
        case .learned: "Where notes nearby already keep them"
        case .named: "The nearest folder named"
        case .fixed: "One folder for the whole vault"
        case .besideTheNote: "The note's own folder"
        case .obsidian: "This vault's Obsidian setting"
        case .vaultRoot: "The top of the vault"
        }
    }

    private var placeholder: String {
        entry.choice == .named ? "Attachments, Assets" : "Attachments"
    }

    /// Exposed so a test can read what a row says. The wording is what makes
    /// the pane usable and no rendering technique can check it.
    var explanationText: String { explanation }

    private var explanation: String {
        if !isReachable {
            return "Never used: a rule above always finds a folder."
        }
        switch entry.choice {
        case .learned:
            return "Where notes in this folder put them before, then the folder above. "
                + "Finds a folder whatever it is called."
        case .named:
            return "Searched upwards from the note. Several names allowed, separated "
                + "by commas. Never creates one."
        case .fixed:
            return "One folder for the whole vault. The only rule that creates one."
        case .besideTheNote:
            return "Next to the note itself. Always finds one, so nothing below is used."
        case .obsidian:
            return obsidianSetting.isEmpty
                ? "Follows Obsidian's own setting. This vault has none set."
                : "Follows Obsidian's own setting, which is \u{201C}\(obsidianSetting)\u{201D}."
        case .vaultRoot:
            return "The top of the vault."
        }
    }
}
