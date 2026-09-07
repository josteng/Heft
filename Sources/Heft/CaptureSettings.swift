import AppKit
import HeftCore
import SwiftUI

/// Where captures go: which vault, when Spotlight has no window to ask, and
/// which note in the vault in front.
///
/// The note is per vault like `StartupSettings`, for the same reason: it
/// names a note, and a note is in one vault. The vault is app-wide because
/// it answers which vault. Both values live in HeftCore, because Spotlight
/// captures with no window open; this object only lets the pane observe them.
@MainActor
final class CaptureSettings: ObservableObject {
    static let shared = CaptureSettings()

    private init() {}

    func stored(for vault: URL) -> String {
        InboxNotePreference.stored(for: vault) ?? ""
    }

    func set(_ raw: String, for vault: URL) {
        InboxNotePreference.set(raw, for: vault)
        objectWillChange.send()
    }

    /// Whether a captured line carries the time it arrived. Both captures
    /// write the same kind of line, so one answer covers both.
    var timestamps: Bool {
        get { CaptureTimestampPreference.isOn }
        set {
            CaptureTimestampPreference.set(newValue)
            objectWillChange.send()
        }
    }

    /// Whether `heft capture` waits for review. The command line only:
    /// Spotlight and Shortcuts are the reader capturing their own thought.
    var agentCaptureNeedsReview: Bool {
        get { AgentCaptureReviewPreference.isOn }
        set {
            AgentCaptureReviewPreference.set(newValue)
            objectWillChange.send()
        }
    }

    /// Empty means the vault opened last.
    var chosenVaultPath: String {
        get { CaptureVaultPreference.chosenPath() ?? "" }
        set {
            CaptureVaultPreference.choose(newValue.isEmpty ? nil : URL(fileURLWithPath: newValue, isDirectory: true))
            objectWillChange.send()
        }
    }
}

struct CaptureSettingsView: View {
    @EnvironmentObject private var registry: VaultRegistry
    @ObservedObject private var settings = CaptureSettings.shared
    @State private var copiedMarker = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    VaultChoiceMenu(selection: $settings.chosenVaultPath)
                        .alignedWithTitle()
                } label: {
                    SettingLabel(
                        "Captures go to",
                        detail: "With one vault this makes no difference. With more, "
                            + "a capture goes to the vault opened last unless one is "
                            + "chosen here. Open Inbox and Open Today's Note use the "
                            + "same vault."
                    )
                }
                LabeledContent {
                    Toggle("", isOn: $settings.agentCaptureNeedsReview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .alignedWithTitle()
                } label: {
                    SettingLabel(
                        "Review agent captures",
                        detail: "`heft capture` adds a line straight away, since "
                            + "adding one cannot disturb what you already wrote. Turn "
                            + "this on and it waits in the review centre like every "
                            + "other change an agent makes. Your own captures from "
                            + "Spotlight and Shortcuts are unaffected."
                    )
                }
                LabeledContent {
                    Toggle("", isOn: $settings.timestamps)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .alignedWithTitle()
                } label: {
                    SettingLabel(
                        "Stamp the time",
                        detail: "Captured lines start with the time they arrived, "
                            + "as \u{201C}- 14:32 the thought\u{201D}. Turned off they are "
                            + "plain list items. Applies to the inbox and to today's note."
                    )
                }
            } header: {
                SectionHeading(
                    "Spotlight and Shortcuts",
                    detail: "Capture to Inbox and Add to Today's Note are App Shortcuts: "
                        + "actions in Spotlight, and shortcuts in the Shortcuts app and Siri. "
                        + "They file a line without bringing Heft forward. Spotlight lets "
                        + "you give an action a quick key, such as \"in\" for Capture to Inbox."
                )
            }

            Section {
                if let vault {
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField(
                                "", text: text(for: vault),
                                prompt: Text(InboxNotePreference.defaultPath)
                            )
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            Button("Choose…") { chooseNote(in: vault) }
                        }
                        .alignedWithTitle()
                    } label: {
                        SettingLabel("Inbox note", detail: detail(for: vault))
                    }
                } else {
                    Text("Open a vault to choose its inbox note.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeading(
                    "Inbox\(vault.map { " in \($0.lastPathComponent)" } ?? "")",
                    detail: "Capture to Inbox files a line into this note, newest first, "
                        + "grouped by day, and Open Inbox shows it. Each vault has its own."
                )
            }

            Section {
                // The same row the Calendar pane has, for the same reason: the
                // folder, format and template belong to the vault and live
                // with it, but this is where the marker sends you.
                LabeledContent {
                    Button("Open Daily Note Settings…") {
                        registry.frontmostModel?.presentDailyNotesSettings()
                    }
                    .disabled(vault == nil)
                    .alignedWithTitle()
                } label: {
                    SettingLabel(
                        "Folder, filename format and template",
                        detail: "These belong to the vault, so they live with it. "
                            + "Put the marker below in the template where captures should go."
                    )
                }
                LabeledContent {
                    Button(copiedMarker ? "Copied" : "Copy") { copyMarker() }
                        .frame(width: 70)
                        .alignedWithTitle()
                } label: {
                    SettingLabel("Log marker", detail: DailyNoteCapture.insertionMarker)
                }
            } header: {
                SectionHeading(
                    "Daily note",
                    detail: "Add to Today's Note appends to today's daily note in the order "
                        + "it happened: above the marker when the template has it, "
                        + "otherwise at the end. Today's note is created from the "
                        + "template when it is not there yet."
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - The settings, read and written where they live

    private var vault: URL? { registry.frontmostModel?.vaultRoot }

    private func text(for vault: URL) -> Binding<String> {
        Binding(
            get: { settings.stored(for: vault) },
            set: { settings.set($0, for: vault) }
        )
    }

    /// Says what the typed text amounts to when that is not obvious: a
    /// missing `.md`, or a path that cannot be inside the vault.
    private func detail(for vault: URL) -> String {
        let base = "A path from the top of the vault, created on the first capture."
        let typed = settings.stored(for: vault)
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        guard let resolved = InboxNotePreference.normalised(typed) else {
            return base + " This is not one, so \(InboxNotePreference.defaultPath) is used."
        }
        return resolved == typed ? base : base + " Used as \(resolved)."
    }

    private func chooseNote(in vault: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vault
        panel.prompt = "Choose"
        panel.message = "Pick the note captures should go to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = vault.standardizedFileURL.path
        let chosen = url.standardizedFileURL.path
        guard chosen.hasPrefix(root + "/") else { return }
        settings.set(String(chosen.dropFirst(root.count + 1)), for: vault)
    }

    private func copyMarker() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DailyNoteCapture.insertionMarker, forType: .string)
        copiedMarker = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedMarker = false
        }
    }
}
