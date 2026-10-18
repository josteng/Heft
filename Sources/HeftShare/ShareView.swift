import HeftCore
import SwiftUI

/// Today's note, the inbox, or any note by name: the capture panel's choice,
/// plus a note to append to, since a shared link usually belongs somewhere.
struct ShareView: View {
    let initialText: String
    /// The shared address, when what was shared is a link.
    let url: URL?
    /// The title the sharing app sent along, if it sent one.
    let pageTitle: String?
    let finish: () -> Void
    let cancel: () -> Void

    fileprivate enum Choice: Hashable { case today, inbox, note }

    @AppStorage("dev.stenglein.Heft.iOS.shareChoice", store: SharedVault.defaults)
    private var lastChoice = "today"
    @State private var choice: Choice = .today
    @State private var text = ""
    @State private var selection: TextSelection?
    private enum Field { case text, search }
    @FocusState private var focus: Field?
    /// Titles to put in the link instead: the page's own, then short ones.
    @State private var titles: [String] = []
    @State private var notes: [SharedVault.ListedNote] = []
    @State private var query = ""
    @State private var picked: SharedVault.ListedNote?
    @State private var problem: String?
    @State private var queuedNotice = false
    @State private var queuedReason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Picking a note is a search, so the shared text shrinks
                    // to a preview and the keyboard goes to the search field;
                    // tapping the text brings it back to full size.
                    TextField("Add a comment, or edit", text: $text, selection: $selection,
                              axis: .vertical)
                        .lineLimit(choice == .note && focus != .text ? 1...2 : 3...10)
                        .focused($focus, equals: .text)
                    if !titles.isEmpty, choice != .note || focus == .text {
                        titleChoices
                    }
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                if choice == .note {
                    notePicker
                }
            }
            // On the keyboard, where the thumb already is, rather than
            // between the text and the notes. A bar rather than an inset
            // with a background: an opaque strip squared off the keyboard's
            // rounded corners.
            .safeAreaBar(edge: .bottom) {
                Picker("Add to", selection: $choice) {
                    Text("Today's Note").tag(Choice.today)
                    Text(inboxName).tag(Choice.inbox)
                    Text("Note…").tag(Choice.note)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: choice) { _, new in
                focus = new == .note ? .search : .text
            }
            .navigationTitle("Heft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!canAdd)
                }
            }
            .alert("Saved for Later", isPresented: $queuedNotice) {
                Button("OK", action: finish)
            } message: {
                Text("Heft will file this the next time you open it.\n\n\(queuedReason)")
            }
        }
        .onAppear {
            text = initialText
            choice = Choice(stored: lastChoice)
            focus = choice == .note ? .search : .text
            // After focusing, which otherwise puts the cursor back at the start.
            DispatchQueue.main.async {
                selection = TextSelection(insertionPoint: text.endIndex)
            }
            notes = SharedVault.noteList()
        }
        .task { await lookUpTitles() }
    }

    @ViewBuilder
    private var notePicker: some View {
        Section {
            TextField("Find a note", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .search)
            ForEach(matches) { note in
                Button {
                    picked = note
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.name).foregroundStyle(.primary)
                            if !note.folder.isEmpty {
                                Text(note.folder).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if picked?.id == note.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .tint(.primary)
            }
        } footer: {
            if notes.isEmpty {
                Text("Open Heft once so the share sheet can see your notes.")
            }
        }
    }

    /// The page title and the short ones, as buttons that swap the link's
    /// text and leave any comment around it alone.
    /// One a row, so a long page title can be read whole.
    private var titleChoices: some View {
        ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
            Button {
                retitle(title)
            } label: {
                Label {
                    Text(title).lineLimit(2).multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: offset == 0 ? "textformat" : "sparkles")
                }
                .font(.subheadline)
            }
        }
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
        let replacement = SharedContent.link(title, url)
        // The link as it stands: `[anything](url)`, or the bare address.
        let pattern = #"\[[^\n]*\]\("# + NSRegularExpression.escapedPattern(for: url.absoluteString) + #"\)"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            text.replaceSubrange(range, with: replacement)
        } else if let range = text.range(of: url.absoluteString) {
            text.replaceSubrange(range, with: replacement)
        } else {
            text = replacement
        }
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    /// Names containing every typed word, most recently edited first, which
    /// is where a just-read link is most likely to go.
    private var matches: [SharedVault.ListedNote] {
        let words = query.lowercased().split(separator: " ")
        let found = words.isEmpty ? notes : notes.filter { note in
            let name = note.path.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return Array(found.prefix(30))
    }

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
        guard let destination else { return }
        lastChoice = choice.stored
        let now = Date()
        do {
            try SharedVault.fileIntoBookmarkedVault(text, to: destination, at: now)
            finish()
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
