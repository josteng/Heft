import AppIntents
import HeftCore
import SwiftUI

/// A line or two, filed with as little ceremony as possible: the same
/// append the Mac's Spotlight captures do, through `DailyNoteCapture` and
/// `InboxCapture`.
///
/// Return files the line rather than starting another, and the field stays
/// open for the next, the way quick-capture apps behave: a capture is a
/// thought per line, and a newline in one was never wanted. Opened from a
/// control or a Home Screen quick action it fills the screen; from inside
/// the app it is a sheet.
struct CaptureSheet: View {
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dev.stenglein.Heft.iOS.captureTarget", store: HeftDefaults.shared)
    private var lastTarget: CaptureTarget = .today
    /// Set when a control asked for one destination; otherwise the last used.
    var requested: CaptureTarget?
    var fullScreen = false

    @State private var target: CaptureTarget = .today
    /// Kept across launches, so a line typed but not filed is still there
    /// when the panel next opens, however the app was left.
    @AppStorage("dev.stenglein.Heft.iOS.captureDraft", store: HeftDefaults.shared)
    private var text = ""
    @State private var problem: String?
    @State private var filed: [Filed] = []
    @FocusState private var focused: Bool

    private struct Filed: Identifiable {
        let id = UUID()
        let text: String
        let target: CaptureTarget
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Add to", selection: $target) {
                        Text("Today's Note").tag(CaptureTarget.today)
                        Text(inboxName).tag(CaptureTarget.inbox)
                    }
                    .pickerStyle(.segmented)

                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .font(.title3)
                        .focused($focused)
                        .submitLabel(.done)
                        .onChange(of: text) { _, new in
                            if new.hasSuffix("\n") {
                                text = String(new.dropLast())
                                add()
                            }
                        }

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    ForEach(filed) { line in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.text).lineLimit(2)
                                Text(line.target == .today ? "Today's Note" : inboxName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .foregroundStyle(.secondary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding()
                .animation(.snappy, value: filed.count)
            }
            .scrollDismissesKeyboard(.never)
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(filed.isEmpty ? "Cancel" : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(isBlank)
                }
            }
            .sensoryFeedback(.success, trigger: filed.count)
            .onAppear {
                target = requested ?? lastTarget
                focused = true
                #if DEBUG
                if let preset = ProcessInfo.processInfo.environment["HEFT_IOS_CAPTURE"] {
                    text = preset
                }
                #endif
            }
        }
        .presentationDetents(fullScreen ? [.large] : [.medium, .large])
    }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inboxName: String {
        guard let root = vault.root else {
            return (InboxNotePreference.defaultPath as NSString).deletingPathExtension
        }
        return ((InboxNotePreference.path(for: root) as NSString).lastPathComponent as NSString)
            .deletingPathExtension
    }

    private func add() {
        guard let root = vault.root, !isBlank else { return }
        do {
            try MobileCapture.file(text, to: target, in: root)
            lastTarget = target
            filed.insert(Filed(text: text, target: target), at: 0)
            text = ""
            problem = nil
            vault.refresh()
        } catch {
            problem = error.localizedDescription
        }
    }
}

enum MobileCapture {
    static func file(_ text: String, to target: CaptureTarget, in root: URL) throws {
        try SharedVault.file(text, to: target.destination, in: root)
    }

    /// For an intent, which has no open vault.
    static func fileFromIntent(_ text: String, to target: CaptureTarget) throws -> String {
        try SharedVault.fileIntoBookmarkedVault(text, to: target.destination)
    }
}

extension CaptureTarget {
    var destination: SharedVault.Destination {
        switch self {
        case .today: .today
        case .inbox: .inbox
        }
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
        AppShortcut(
            intent: MobileOpenNoteIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a note in \(.applicationName)",
            ],
            shortTitle: "Open Note",
            systemImageName: "doc.text"
        )
    }
}
