import AppKit
import HeftCore
import SwiftUI

/// Which note a vault's captures land in, for the vault in front.
///
/// Per vault like `StartupSettings`, for the same reason: the setting names a
/// note, and a note is in one vault. The value itself lives in
/// `InboxNotePreference` in the pure target, because Spotlight captures with
/// no window open; this object only lets the pane observe it.
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
}

struct CaptureSettingsView: View {
    @EnvironmentObject private var registry: VaultRegistry
    @ObservedObject private var settings = CaptureSettings.shared
    @State private var copiedMarker = false

    var body: some View {
        Form {
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
                    } label: {
                        SettingLabel("Inbox note", detail: detail(for: vault))
                    }
                } else {
                    Text("Open a vault to choose its inbox note.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeading(
                    "Capture in \(vault?.lastPathComponent ?? "a vault")",
                    detail: "Capture to Inbox in Spotlight files a line into this note, "
                        + "newest first, grouped by day, and Open Inbox shows it; both work "
                        + "while Heft is in front and go to the vault opened last. Spotlight "
                        + "on macOS 26 can give an action a quick key."
                )
            }

            Section {
                LabeledContent {
                    Button(copiedMarker ? "Copied" : "Copy") { copyMarker() }
                        .frame(width: 70)
                } label: {
                    SettingLabel("Log marker", detail: DailyNoteCapture.insertionMarker)
                }
            } header: {
                SectionHeading(
                    "Daily note",
                    detail: "Add to Today's Note appends to today's daily note in the order "
                        + "it happened: above this marker when the template has it, "
                        + "otherwise at the end. The folder, filename format and template "
                        + "are under File ▸ Daily Note Settings…"
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - The setting, read and written where it lives

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
