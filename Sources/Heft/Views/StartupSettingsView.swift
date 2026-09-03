import HeftCore
import SwiftUI

/// What Heft opens when it starts, for the vault in front.
///
/// Per vault, because "always open this note" names a note, and a note only
/// exists in one vault. The pane says which vault it is answering for rather
/// than leaving that to be guessed.
///
/// Everything here is read straight from the store rather than copied into
/// `@State` on appear. The window measures this pane off screen to size itself,
/// and a view that fills itself in only once it is on screen measures as the
/// empty placeholder — which is exactly how this tab came up clipped.
struct StartupSettingsView: View {
    @EnvironmentObject private var registry: VaultRegistry
    @ObservedObject private var settings = StartupSettings.shared

    var body: some View {
        Form {
            // The choice on its own. A field in the same group sat directly
            // under the last option and read as belonging to it, however it
            // was labelled: a grouped Form draws one card, and everything in
            // the card looks related.
            Section {
                if vault != nil {
                    Picker("", selection: choice) {
                        ForEach(StartupNote.Choice.allCases) { option in
                            Text(title(option)).tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } else {
                    Text("Open a vault to choose what it starts on.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("When Heft opens\(vault.map { " \($0.lastPathComponent)" } ?? "")")
            } footer: {
                if vault != nil {
                    Text(explanation)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if vault != nil, current.choice.needsText {
                Section {
                    LabeledContent(fieldLabel) {
                        HStack(spacing: 8) {
                            TextField("", text: text, prompt: Text(placeholder))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            if current.choice == .note {
                                Button("Choose…") { chooseNote() }
                            }
                        }
                    }

                    // The same list the daily-note sheet shows, from the same
                    // component: the same tokens through the same
                    // `MomentFormat`, and two lists would read as two systems
                    // that happen to look alike.
                    if current.choice == .pattern {
                        PlaceholderReference(
                            title: "Template Variables",
                            tokens: PlaceholderReference.dateTokens,
                            footnote: PlaceholderReference.momentTokenFootnote,
                            tokenWidth: 160
                        )
                        .padding(.top, 6)
                    }
                }
            }

            if vault != nil, current.choice != .nothing {
                // Not "today": only two of the five answers depend on the date
                // at all, and a named note is the same note whenever you look.
                Section("What Heft would open now") {
                    Text(preview).foregroundStyle(.primary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    // MARK: - The setting, read and written where it lives

    private var vault: URL? { registry.frontmostModel?.vaultRoot }

    private var current: StartupNote {
        vault.map { settings.setting(for: $0) } ?? .standard
    }

    private func save(_ setting: StartupNote) {
        guard let vault else { return }
        settings.set(setting, for: vault)
    }

    private var choice: Binding<StartupNote.Choice> {
        Binding(
            get: { current.choice },
            set: { var next = current; next.choice = $0; save(next) }
        )
    }

    private var text: Binding<String> {
        Binding(
            get: { current.text },
            set: { var next = current; next.text = $0; save(next) }
        )
    }

    // MARK: - Words

    private func title(_ option: StartupNote.Choice) -> String {
        switch option {
        case .nothing: "Nothing"
        case .lastNote: "The note you were last on"
        case .dailyNote: "Today's daily note"
        case .note: "One note, always"
        case .pattern: "A note worked out from the date"
        }
    }

    private var fieldLabel: String {
        current.choice == .note ? "Note" : "Pattern"
    }

    private var placeholder: String {
        current.choice == .note ? "Inbox.md" : "Journal/{{date:YYYY}}/{{date:YYYY-MM}}.md"
    }

    private var explanation: String {
        switch current.choice {
        case .nothing:
            return "What Heft does now: macOS brings back the window you had, and a "
                + "cold start with nothing to bring back opens on no note."
        case .lastNote:
            return "The last note you had open in this vault, reopened even when there "
                + "is no window to restore. Nothing is created."
        case .dailyNote:
            return "Today's note, by this vault's daily-note settings, created from "
                + "the template if it is not there yet."
        case .note:
            return "The same note every time, as a path from the top of the vault. "
                + "Nothing is created: if it is not there, Heft opens on what you had."
        case .pattern:
            return "The tokens a daily-note template uses — {{date:YYYY-MM-DD}}, "
                + "{{time:HH:mm}} — so a weekly note is {{date:GGGG-[W]WW}}. For a "
                + "note the daily-note settings cannot describe. Nothing is created."
        }
    }

    private var preview: String {
        guard let vault,
              let relative = current.relativePath(
                on: Date(), dailyPath: dailyPath, lastNote: lastNote
              )
        else {
            return current.choice == .lastNote
                ? "nothing yet — this vault has no note in its recents"
                : "nothing"
        }
        let exists = FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(relative).path
        )
        if exists { return relative }
        return current.choice == .dailyNote
            ? "\(relative)  (would be created)"
            : "\(relative)  (not there, so nothing would open)"
    }

    private func dailyPath(_ date: Date) -> String? {
        registry.frontmostModel?.dailyNotes?.relativePath(for: date)
    }

    private func lastNote() -> String? {
        registry.frontmostModel?.recentNotes.first?.relativePath
    }

    private func chooseNote() {
        guard let vault else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vault
        panel.prompt = "Choose"
        panel.message = "Pick the note Heft should open when it starts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = vault.standardizedFileURL.path
        let chosen = url.standardizedFileURL.path
        guard chosen.hasPrefix(root + "/") else { return }
        text.wrappedValue = String(chosen.dropFirst(root.count + 1))
    }
}
