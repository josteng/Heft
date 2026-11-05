import HeftCore
import SwiftUI

/// The share sheet, laid out as the capture sheet is, since it is the same
/// act from another app: where it goes large at the top, the inbox, today
/// or a note, changed by a sideways swipe or a tap; the text under it,
/// unboxed, tags drawn as in a note; and along the keyboard the tags a `#`
/// begins, where it goes, and the send button.
///
/// What it adds to the capture: a link's page titles to swap in, and a note
/// to append to, since a shared link usually belongs somewhere. Return
/// breaks the line rather than filing it: a share is often more than a
/// line, and is filed once. Compiled into the app too, which shows it for a
/// screenshot (`HEFT_IOS_SHARE`).
struct ShareView: View {
    let initialText: String
    /// The shared address, when what was shared is a link.
    let url: URL?
    /// The title the sharing app sent along, if it sent one.
    let pageTitle: String?
    let finish: () -> Void
    let cancel: () -> Void

    enum Choice: Hashable { case inbox, today, note }

    @AppStorage("dev.stenglein.Heft.iOS.shareChoice", store: SharedVault.defaults)
    private var lastChoice = "today"
    @State private var choice: Choice = .today
    @State private var dragProgress: CGFloat?
    @State private var text = ""
    @State private var focusRequest = 0
    /// Titles to put in the link instead: the page's own, then short ones.
    @State private var titles: [String] = []
    @State private var notes: [SharedVault.ListedNote] = []
    @State private var query = ""
    @State private var picked: SharedVault.ListedNote?
    @State private var context = SharedVault.CaptureContext()
    @State private var problem: String?
    @State private var queuedNotice = false
    @State private var queuedReason = ""
    @State private var filed = 0
    @FocusState private var searching: Bool

    private static let choices: [Choice] = [.inbox, .today, .note]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Three named options and the close button do not fit a
                // phone's width: only the chosen one keeps its name there.
                ViewThatFits(in: .horizontal) {
                    dial(compact: false)
                    dial(compact: true)
                }
                Spacer(minLength: 0)
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .tint(.primary)
            }
            CaptureTextView(text: $text, tagColor: tagColor, focusRequest: focusRequest,
                            placeholder: "Add a comment", fontSize: 20, submitsOnReturn: false, selectsOnFocus: false, submit: add)
                .frame(minHeight: 60, maxHeight: choice == .note ? 84 : .infinity)
                .padding(.top, 14)
            if choice == .note {
                notePicker
            } else if !titles.isEmpty {
                titleRow.padding(.top, 10)
            }
            Spacer(minLength: 0)
            bottomRow
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .switchSwipe($choice, among: Self.choices, dragged: $dragProgress)
        .sensoryFeedback(.success, trigger: filed)
        .onChange(of: choice) { _, new in
            if new == .note { searching = true } else { searching = false; focusRequest += 1 }
        }
        .onAppear {
            text = initialText
            choice = Choice(stored: lastChoice)
            #if DEBUG
            // `HEFT_IOS_SHARE_CHOICE=inbox|today|note` for a screenshot.
            if let asked = ProcessInfo.processInfo.environment["HEFT_IOS_SHARE_CHOICE"] { choice = Choice(stored: asked) }
            #endif
            notes = SharedVault.noteList()
            context = SharedVault.captureContext()
            if choice == .note { searching = true } else { focusRequest += 1 }
        }
        .task { await lookUpTitles() }
        .alert("Saved for Later", isPresented: $queuedNotice) {
            Button("OK", action: finish)
        } message: {
            Text("Heft will file this the next time you open it.\n\n\(queuedReason)")
        }
    }

    // MARK: Destination

    private func dial(compact: Bool) -> some View {
        GlassSwitch(selection: $choice, options: [
            (.inbox, inboxName, "tray"), (.today, "Today", "calendar"), (.note, "Note", "doc.text"),
        ], dragged: dragProgress, compact: compact)
    }

    /// Where it goes, said along the keyboard as the capture says it.
    private var whereItGoes: (text: String, symbol: String) {
        switch choice {
        case .today: (Date().formatted(.dateTime.weekday(.wide).day().month(.wide)), "calendar")
        case .inbox: ("Added at the top of \(inboxName)", "tray")
        case .note: (picked.map { "Added to the end of \($0.name)" } ?? "Pick a note", "doc.text")
        }
    }

    // MARK: A note

    /// Picking a note is a search: the field and the notes under the text,
    /// most recently edited first, which is where a just-read link is most
    /// likely to go.
    private var notePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find a note", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searching)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(in: .capsule)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { note in
                        Button { picked = note } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.name).foregroundStyle(.primary)
                                    if !note.folder.isEmpty {
                                        Text(note.folder).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if picked?.id == note.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if notes.isEmpty {
                        Text("Open Heft once so the share sheet can see your notes.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollDismissesKeyboard(.never)
        }
        .padding(.top, 10)
    }

    private var matches: [SharedVault.ListedNote] {
        let words = query.lowercased().split(separator: " ")
        let found = words.isEmpty ? notes : notes.filter { note in
            let name = note.path.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return Array(found.prefix(30))
    }

    // MARK: A link's titles

    /// The page's title and short ones, as chips that swap the link's text
    /// and leave any comment around it alone.
    private var titleRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
                    Button { retitle(title) } label: {
                        Label(title, systemImage: offset == 0 ? "textformat" : "sparkles")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// The same titles the Mac offers for a pasted address, from the same
    /// code: the page's title when the sharing app sent none, and up to
    /// three short ones from the on-device model when it is available.
    private func lookUpTitles() async {
        guard let url else { return }
        var title = pageTitle
        if title == nil, let fetched = await LinkTitles.pageTitle(url)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fetched.isEmpty {
            title = fetched
            // Only while the reader has not started on the text themselves.
            if text == initialText { retitle(fetched) }
        }
        guard let title else { return }
        let short = await LinkTitles.shortTitles(title, url)
        titles = short.isEmpty ? [] : [title] + short
    }

    private func retitle(_ title: String) {
        guard let url else { return }
        text = SharedContent.retitled(text, url: url, title: title)
    }

    // MARK: Along the keyboard

    private var bottomRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                tagRow
                Label(problem ?? whereItGoes.text,
                      systemImage: problem != nil ? "exclamationmark.triangle" : whereItGoes.symbol)
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(problem != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            Button("Add", systemImage: "arrow.up", action: add)
                .labelStyle(.iconOnly)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(canAdd ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.4)), in: .circle)
                .disabled(!canAdd)
        }
    }

    /// The vault's tags a typed `#` begins, as the capture offers them.
    /// Always the same height, so nothing jumps as chips come and go.
    private var tagRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let typed = typedTag {
                    ForEach(completions(for: typed), id: \.self) { tag in
                        Button("#" + tag) { text = String(text.dropLast(typed.count)) + tag + " " }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
    }

    private var typedTag: String? {
        guard let match = text.range(of: #"(?:^|\s)#([A-Za-z][\w/-]*)$"#, options: .regularExpression) else { return nil }
        return String(text[match].drop { $0 != "#" }.dropFirst())
    }

    private func completions(for typed: String) -> [String] {
        let lowered = typed.lowercased()
        return context.tags.filter { $0.lowercased().hasPrefix(lowered) && $0.lowercased() != lowered }
            .prefix(8).map { $0 }
    }

    private var tagColor: UIColor {
        guard let hex = context.tagColor, let parts = HexColor.components(hex) else { return .tintColor }
        return UIColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }

    // MARK: Filing

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (choice != .note || picked != nil)
    }

    private var inboxName: String {
        let path = SharedVault.bookmarkedRoot(startAccessing: false)
            .map { InboxNotePreference.path(for: $0) } ?? InboxNotePreference.defaultPath
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private var destination: SharedVault.Destination? {
        switch choice {
        case .today: .today
        case .inbox: .inbox
        case .note: picked.map { .note($0.path) }
        }
    }

    private func add() {
        guard canAdd, let destination else { return }
        lastChoice = choice.stored
        let now = Date()
        do {
            try SharedVault.fileIntoBookmarkedVault(text, to: destination, at: now)
            filed += 1
            // A moment for the click to be felt before the sheet goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: finish)
        } catch {
            do {
                try SharedVault.enqueue(.init(text: text, destination: destination, date: now))
                queuedReason = error.localizedDescription
                queuedNotice = true
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private extension ShareView.Choice {
    init(stored: String) {
        switch stored {
        case "inbox": self = .inbox
        case "note": self = .note
        default: self = .today
        }
    }

    var stored: String {
        switch self {
        case .today: "today"
        case .inbox: "inbox"
        case .note: "note"
        }
    }
}
