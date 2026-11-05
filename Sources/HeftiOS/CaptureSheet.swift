import AppIntents
import HeftCore
import SwiftUI

/// A line or two, filed with as little ceremony as possible: the same
/// append the Mac's Spotlight captures do, through `DailyNoteCapture` and
/// `InboxCapture`.
///
/// Laid out as a quick-capture screen rather than a form: the destination
/// large at the top, Today or the inbox, changed by a sideways swipe anywhere
/// or a tap on the other name; the text itself under it, large and unboxed,
/// tags drawn as in a note; and along the keyboard, the tags to offer, where
/// the line goes, and the send button. There is no preview of the note: a
/// capture lands under a marker in the daily note and at the top of the
/// inbox, so a note's end would say nothing about where it goes.
///
/// Return files the line and the field stays open for the next: a capture
/// is a thought per line. Opened from a control or a Home Screen quick
/// action it fills the screen; from inside the app it is a sheet.
struct CaptureSheet: View {
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dev.stenglein.Heft.iOS.captureTarget", store: HeftDefaults.shared)
    private var lastTarget: CaptureTarget = .today
    /// Set when a control asked for one destination; otherwise what Settings
    /// say, the last used unless chosen.
    var requested: CaptureTarget?
    var fullScreen = false

    @State private var target: CaptureTarget = .today
    /// Kept across launches, so a line typed but not filed is still there
    /// when the panel next opens, however the app was left.
    @AppStorage("dev.stenglein.Heft.iOS.captureDraft", store: HeftDefaults.shared)
    private var text = ""
    @State private var problem: String?
    @State private var filedCount = 0
    /// What was added while the panel is open, newest first, so several
    /// lines in a row can be seen to have gone in.
    @State private var added: [Added] = []
    @State private var suggester = TagSuggester.empty
    @State private var suggestion: String?
    @State private var suggesting: Task<Void, Never>?
    @State private var focusRequest = 0
    /// Which way the last switch went, so the page of added lines slides
    /// in from that side.
    @State private var forward = true
    /// Where the switch's highlight is while a swipe moves it.
    @State private var dragProgress: CGFloat?

    private struct Added: Identifiable {
        let id = UUID()
        let line: String
        let target: CaptureTarget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                dial
                HStack {
                    Spacer()
                    // What is added is already filed, so closing never discards.
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .tint(.primary)
                }
            }
            CaptureTextView(text: $text, tagColor: vault.appearance.tagColor, focusRequest: focusRequest,
                            placeholder: "What's on your mind?", submit: add)
                .padding(.top, 14)
            addedList
            bottomRow
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // The destinations swipe as New Note's Note and Folder do; the
        // clicks are the switch's own, for the reader's switches only.
        .switchSwipe($target, among: [.inbox, .today], dragged: $dragProgress)
        .onChange(of: target) { _, now in forward = now == .today }
        .sensoryFeedback(.success, trigger: filedCount)
        .onAppear {
            target = requested ?? {
                switch BrowsingPreferences.shared.captureStart {
                case .lastUsed: lastTarget
                case .inbox: .inbox
                case .today: .today
                }
            }()
            focusRequest += 1
            #if DEBUG
            // Lines ending in Return are filed, one after another, as typing
            // them would; what is left stays in the field.
            if let preset = ProcessInfo.processInfo.environment["HEFT_IOS_CAPTURE"] {
                var lines = preset.components(separatedBy: "\n")
                let rest = lines.removeLast()
                for line in lines {
                    text = line
                    add()
                }
                text = rest
            }
            // `HEFT_IOS_CAPTURE_SWITCH` turns to the other destination once
            // the panel is up, as a tap would, to watch the motion.
            // `HEFT_IOS_CAPTURE_DRAG=<0…1>` holds the highlight where a drag
            // that far along would.
            if let held = ProcessInfo.processInfo.environment["HEFT_IOS_CAPTURE_DRAG"].flatMap(Double.init) {
                dragProgress = held
            }
            if ProcessInfo.processInfo.environment["HEFT_IOS_CAPTURE_SWITCH"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                        target = target == .today ? .inbox : .today
                    }
                }
            }
            #endif
        }
        .task(id: vault.generation) { suggester = await Self.suggester(for: vault) }
        .onChange(of: text) { suggestSoon() }
        .onChange(of: suggester.isEmpty) { suggestSoon() }
        // Half height inside the app, as New Note opens, so the two read as
        // one kind of sheet: the same size, and the same glass, which iOS
        // draws only on a sheet short of full height. Half height alone: with
        // full height offered too, iOS grew the sheet to it as soon as the
        // keyboard came up. Opened from a control it fills the screen, being
        // all that was asked for.
        .presentationDetents(fullScreen ? [.large] : [.medium])
    }

    // MARK: Destination

    /// The two destinations, the inbox first, as the shared glass switch.
    private var dial: some View {
        GlassSwitch(selection: $target, options: [
            (.inbox, name(.inbox), "tray"), (.today, name(.today), "calendar"),
        ], dragged: dragProgress)
    }

    private func name(_ destination: CaptureTarget) -> String {
        destination == .today ? "Today" : inboxName
    }

    /// Where the line goes: the day for today's note, the top for the inbox.
    private var whereItGoes: String {
        target == .today
            ? Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
            : "Added at the top of \(inboxName)"
    }

    // MARK: Added

    /// What was added here while the panel is open, newest on top: a page
    /// per destination, sliding in with the switch. The last few, so the
    /// text keeps its room.
    private var addedList: some View {
        let here = added.filter { $0.target == target }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(here.prefix(4)) { item in
                Label {
                    Text(item.line).lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                .font(.callout)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, here.isEmpty ? 0 : 14)
        .id(target)
        .transition(.push(from: forward ? .trailing : .leading))
        .animation(.snappy, value: here.map(\.id))
    }

    // MARK: Along the keyboard

    private var bottomRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                tagRow
                Label(problem ?? whereItGoes,
                      systemImage: problem != nil ? "exclamationmark.triangle" : (target == .today ? "calendar" : "tray"))
                    .font(.footnote)
                    .foregroundStyle(problem != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            Button("Add", systemImage: "arrow.up", action: add)
                .labelStyle(.iconOnly)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(isBlank ? AnyShapeStyle(.tint.opacity(0.4)) : AnyShapeStyle(.tint), in: .circle)
                .disabled(isBlank)
        }
    }

    /// What a typed `#` begins, or the tag the line reads like. Always the
    /// same height, so nothing jumps as chips come and go.
    private var tagRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let typed = typedTag {
                    ForEach(completions(for: typed), id: \.self) { tag in
                        Button("#" + tag) { complete(typed, with: tag) }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                } else if let suggestion {
                    Button { take(suggestion) } label: {
                        Label("#" + suggestion, systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .transition(.opacity)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
        .animation(.easeOut(duration: 0.2), value: suggestion)
    }

    /// The `#tag` being typed at the end of the line, without its `#`.
    private var typedTag: String? {
        guard let match = text.range(of: #"(?:^|\s)#([A-Za-z][\w/-]*)$"#, options: .regularExpression) else { return nil }
        return String(text[match].drop { $0 != "#" }.dropFirst())
    }

    /// The vault's tags that begin with what was typed, most used first.
    private func completions(for typed: String) -> [String] {
        let lowered = typed.lowercased()
        return vault.index.allTags
            .filter { $0.lowercased().hasPrefix(lowered) && $0.lowercased() != lowered }
            .prefix(8).map { $0 }
    }

    private func complete(_ typed: String, with tag: String) {
        text = String(text.dropLast(typed.count)) + tag + " "
    }

    private func take(_ tag: String) {
        text += (text.hasSuffix(" ") || text.isEmpty ? "" : " ") + "#" + tag
        suggestion = nil
    }

    /// A suggestion once typing pauses, and none for a line that already
    /// has a tag or is still typing one.
    private func suggestSoon() {
        suggesting?.cancel()
        let line = text
        guard typedTag == nil, NoteTags.inline(in: line).isEmpty else {
            suggestion = nil
            return
        }
        suggesting = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let next = suggester.suggest(for: line)
            if next != suggestion { suggestion = next }
        }
    }

    /// Built off the main thread from every note's text, once per scan.
    private static var cached: (generation: Int, suggester: TagSuggester)?

    private static func suggester(for vault: MobileVault) async -> TagSuggester {
        if let cached, cached.generation == vault.generation { return cached.suggester }
        let urls = vault.index.notes.map(\.url)
        let generation = vault.generation
        let built = await Task.detached(priority: .utility) {
            TagSuggester(examples: TagSuggester.examples(in: urls.compactMap {
                try? String(contentsOf: $0, encoding: .utf8)
            }))
        }.value
        cached = (generation, built)
        return built
    }

    // MARK: Filing

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
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try MobileCapture.file(line, to: target, in: root)
            lastTarget = target
            added.insert(Added(line: line, target: target), at: 0)
            filedCount += 1
            text = ""
            suggestion = nil
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
