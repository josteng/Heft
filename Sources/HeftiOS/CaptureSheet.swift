import AppIntents
import HeftCore
import SwiftUI

/// Where a capture goes: today's daily note, or the vault's inbox note.
enum CaptureTarget: String, CaseIterable, Identifiable {
    case today, inbox
    var id: String { rawValue }
}

/// A line or two, filed without opening anything: the same append the Mac's
/// Spotlight captures do, through `DailyNoteCapture` and `InboxCapture`.
struct CaptureSheet: View {
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dev.stenglein.Heft.iOS.captureTarget", store: HeftDefaults.shared)
    private var target: CaptureTarget = .today
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                }
                Section {
                    Picker("Add to", selection: $target) {
                        Text("Today's Note").tag(CaptureTarget.today)
                        Text(inboxName).tag(CaptureTarget.inbox)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                focused = true
                #if DEBUG
                if let preset = ProcessInfo.processInfo.environment["HEFT_IOS_CAPTURE"] {
                    text = preset
                }
                #endif
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var inboxName: String {
        guard let root = vault.root else {
            return (InboxNotePreference.defaultPath as NSString).deletingPathExtension
        }
        return ((InboxNotePreference.path(for: root) as NSString).lastPathComponent as NSString)
            .deletingPathExtension
    }

    private func add() {
        guard let root = vault.root else { return }
        do {
            try MobileCapture.file(text, to: target, in: root, settings: vault.settings)
            vault.refresh()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

enum MobileCapture {
    static func file(_ text: String, to target: CaptureTarget, in root: URL,
                     settings: ObsidianSettings) throws {
        switch target {
        case .today:
            try DailyNoteCapture(vaultRoot: root, settings: settings).capture(text)
        case .inbox:
            try InboxCapture(vaultRoot: root).capture(text)
        }
    }

    /// For an intent, which has no open vault: resolves the bookmark, holds
    /// access for the one write, and lets it go.
    static func fileFromIntent(_ text: String, to target: CaptureTarget) throws -> String {
        guard let root = MobileVault.bookmarkedRoot(startAccessing: true) else {
            throw InboxCaptureError.vaultUnavailable
        }
        defer { root.stopAccessingSecurityScopedResource() }
        try file(text, to: target, in: root, settings: ObsidianSettings.load(vaultRoot: root))
        return root.lastPathComponent
    }
}

/// The phone's two captures. On iOS a background intent runs without
/// bringing the app forward, so unlike the Mac these can live in the app;
/// they are separate from `HeftCapture`'s because the vault here is reached
/// through a bookmark rather than a path.
struct MobileAddToTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Today's Note"
    static let description = IntentDescription("Appends an item to today's daily note in Heft.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Note", requestValueDialog: "What would you like to add to today's note?")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$note) to today's note")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vault = try MobileCapture.fileFromIntent(note, to: .today)
        return .result(dialog: "Added to today's note in \(vault).")
    }
}

struct MobileCaptureToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Inbox"
    static let description = IntentDescription("Adds an item to the inbox note of your Heft vault.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Note", requestValueDialog: "What would you like to capture?")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$note) to the inbox")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vault = try MobileCapture.fileFromIntent(note, to: .inbox)
        return .result(dialog: "Captured in \(vault).")
    }
}

struct HeftMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MobileAddToTodayIntent(),
            phrases: [
                "Add to today's note in \(.applicationName)",
                "Log this in \(.applicationName)",
            ],
            shortTitle: "Add to Today's Note",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: MobileCaptureToInboxIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Capture",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
