import HeftCore
import SwiftUI

/// Today's note, the inbox, or any note by name: the capture panel's choice,
/// plus a note to append to, since a shared link usually belongs somewhere.
struct ShareView: View {
    let initialText: String
    /// A shared address that came without a title, to look one up for.
    let untitledURL: URL?
    let finish: () -> Void
    let cancel: () -> Void

    fileprivate enum Choice: Hashable { case today, inbox, note }

    @AppStorage("dev.stenglein.Heft.iOS.shareChoice", store: SharedVault.defaults)
    private var lastChoice = "today"
    @State private var choice: Choice = .today
    @State private var text = ""
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
                    TextField("Add a comment, or edit", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section {
                    Picker("Add to", selection: $choice) {
                        Text("Today's Note").tag(Choice.today)
                        Text(inboxName).tag(Choice.inbox)
                        Text("Note…").tag(Choice.note)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                if choice == .note {
                    notePicker
                }
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
            notes = SharedVault.noteList()
        }
        .task {
            guard let url = untitledURL, let title = await SharedContent.title(of: url) else { return }
            // Only while the reader has not started on the text themselves.
            if text == initialText { text = SharedContent.link(title, url) }
        }
    }

    @ViewBuilder
    private var notePicker: some View {
        Section {
            TextField("Find a note", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
            }
        } footer: {
            if notes.isEmpty {
                Text("Open Heft once so the share sheet can see your notes.")
            }
        }
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
