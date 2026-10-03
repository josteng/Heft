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
            // App-wide, above the per-vault answers: which vault comes up at
            // all decides which of the answers below applies.
            Section {
                LabeledContent {
                    VaultChoiceMenu(selection: $settings.launchVaultPath)
                        .alignedWithTitle()
                } label: {
                    SettingLabel(
                        "Open",
                        detail: "Which vault comes up. What it opens is chosen below."
                    )
                }
            } header: {
                SectionHeading("When there is nothing to restore")
            }

            if let vault {
                // Menus rather than radio groups: two lists of five answers
                // each made the pane a column of dots, and the field a choice
                // needs now sits right under the menu it belongs to.
                Section {
                    // What the chosen answer does is the row's, under its name,
                    // as everywhere in Settings; above the card is only what
                    // the group is.
                    StartupChoiceEditor(
                        title: "Open",
                        note: Binding(get: { current }, set: { save($0) }),
                        vault: vault,
                        detail: explanation
                    )
                } header: {
                    SectionHeading("When Heft opens \(vault.lastPathComponent)")
                }

                Section {
                    // A switch, and the same menu as above under it while it
                    // is off: following the launch is a yes or no, not one
                    // more answer in a list of them.
                    let follows = Binding(
                        get: { settings.reopen(for: vault).sameAsLaunch },
                        set: { var next = settings.reopen(for: vault); next.sameAsLaunch = $0; settings.setReopen(next, for: vault) }
                    )
                    Toggle("Same as when Heft opens", isOn: follows)
                    if !follows.wrappedValue {
                        StartupChoiceEditor(
                            title: "Open",
                            note: Binding(
                                get: { settings.reopen(for: vault).note },
                                set: { var next = settings.reopen(for: vault); next.note = $0; settings.setReopen(next, for: vault) }
                            ),
                            vault: vault
                        )
                    }
                } header: {
                    SectionHeading(
                        "When a window opens again",
                        detail: "After its last window was closed without quitting, as when you "
                            + "click Heft in the Dock."
                    )
                }

                if current.choice != .nothing {
                    // Not "today": only two of the five answers depend on the
                    // date at all, and a named note is the same note whenever.
                    Section("What Heft would open now") {
                        Text(preview).foregroundStyle(.primary)
                    }
                }
            } else {
                Section {
                    Text("Open a vault to choose what it starts on.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
}

/// One launch-shaped answer: a menu of what to open, and the note or the
/// pattern the answer needs, under it. Used for launching and, when it does
/// not simply follow the launch, for reopening.
private struct StartupChoiceEditor: View {
    let title: String
    @Binding var note: StartupNote
    let vault: URL
    /// What the chosen answer does, under the menu's name.
    var detail: String?

    var body: some View {
        Picker(selection: $note.choice) {
            ForEach(StartupNote.Choice.allCases) { Text(Self.title($0)).tag($0) }
        } label: {
            if let detail { SettingLabel(title, detail: detail) } else { Text(title) }
        }
        .defaultMenuTint()

        if note.choice.needsText {
            LabeledContent(note.choice == .note ? "Note" : "Pattern") {
                HStack(spacing: 8) {
                    TextField("", text: $note.text, prompt: Text(placeholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if note.choice == .note {
                        Button("Choose…") { chooseNote() }
                    }
                }
            }
            // The same list the daily-note sheet shows, from the same
            // component: the same tokens through the same `MomentFormat`.
            if note.choice == .pattern {
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

    static func title(_ option: StartupNote.Choice) -> String {
        switch option {
        case .nothing: "Nothing"
        case .lastNote: "The note you were last on"
        case .dailyNote: "Today's daily note"
        case .note: "One note, always"
        case .pattern: "A note worked out from the date"
        }
    }

    /// Not `Inbox.md`. That name means one thing in Heft — the note Spotlight
    /// capture appends to — and offering it as the example here made it look
    /// like the canonical note for everything.
    private var placeholder: String {
        note.choice == .note ? "Projects/Overview.md" : "Journal/{{date:YYYY}}/{{date:YYYY-MM}}.md"
    }

    private func chooseNote() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vault
        panel.prompt = "Choose"
        panel.message = "Pick the note Heft should open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = vault.standardizedFileURL.path
        let chosen = url.standardizedFileURL.path
        guard chosen.hasPrefix(root + "/") else { return }
        note.text = String(chosen.dropFirst(root.count + 1))
    }
}
