import HeftCore
import SwiftUI

/// The phone's share sheet on the Mac: today's note, the inbox, or any note
/// by name, and for a link the page's title and short titles to put in it.
///
/// The vault is the one Spotlight capture files into, read from the app's
/// preferences, and the notes are its index read from disk, so the sheet
/// needs neither a bookmark nor the app to have published a list.
struct ShareView: View {
    let items: [NSExtensionItem]
    let finish: () -> Void
    let cancel: () -> Void

    fileprivate enum Choice: String, Hashable { case today, inbox, note }

    @AppStorage("dev.stenglein.Heft.shareChoice", store: HeftDefaults.shared)
    private var lastChoice = Choice.today.rawValue
    @State private var choice: Choice = .today
    @State private var text = ""
    /// What the items made of the text, so a title found later replaces the
    /// link only while the reader has not started on the text themselves.
    @State private var initialText = ""
    @State private var url: URL?
    @State private var titles: [String] = []
    @State private var notes: [NoteRef] = []
    @State private var query = ""
    @State private var picked: NoteRef?
    @State private var problem: String?
    private enum Field { case text, search }
    @FocusState private var focus: Field?

    private let vault = CaptureVaultPreference.url

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add to Heft").font(.headline)
                Spacer()
                if let vault {
                    Text(vault.lastPathComponent).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($focus, equals: .text)
            Picker("Add to", selection: $choice) {
                Text("Today's Note").tag(Choice.today)
                Text(inboxName).tag(Choice.inbox)
                Text("Note…").tag(Choice.note)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // One fixed panel for both, because the share sheet keeps the
            // size it opened at: titles that arrive later, or a note list,
            // would otherwise be cut off rather than make it grow. As on the
            // phone, the titles step aside while a note is being picked.
            Group {
                if choice == .note {
                    notePicker
                } else {
                    titleChoices
                }
            }
            .frame(height: 150, alignment: .top)
            HStack {
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onChange(of: choice) { _, new in
            focus = new == .note ? .search : .text
        }
        .task { await load() }
    }

    private var notePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find a note", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
            List(matches, id: \.relativePath, selection: Binding(
                get: { picked?.relativePath },
                set: { path in picked = notes.first { $0.relativePath == path } }
            )) { note in
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.name)
                    let folder = (note.relativePath as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if notes.isEmpty {
                    Text(vault == nil ? "No vault yet." : "Reading the vault…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The page title and the short ones, as buttons that swap the link's
    /// text and leave any comment around it alone.
    private var titleChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
                Button {
                    retitle(title)
                } label: {
                    Label {
                        Text(title).lineLimit(1)
                    } icon: {
                        Image(systemName: offset == 0 ? "textformat" : "sparkles")
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private func load() async {
        choice = Choice(rawValue: lastChoice) ?? .today
        let shared = await SharedContent.markdown(from: items)
        text = shared.text
        initialText = shared.text
        url = shared.url
        focus = choice == .note ? .search : .text
        async let titles: Void = lookUpTitles(pageTitle: shared.title)
        if let vault {
            notes = await Task.detached { VaultIndex.open(vaultAt: vault).notesByLastEdit }.value
        }
        await titles
    }

    /// The titles the Mac offers for a pasted address, from the same code
    /// and behind the same two settings: the page's title when the sharing
    /// app sent none, and short ones from the on-device model.
    private func lookUpTitles(pageTitle: String?) async {
        guard let url else { return }
        var title = pageTitle
        if title == nil, LinkTitlePreference.pageTitles(),
           let fetched = await LinkTitles.pageTitle(url)?
               .trimmingCharacters(in: .whitespacesAndNewlines), !fetched.isEmpty {
            title = fetched
            if text == initialText { retitle(fetched) }
        }
        guard let title else { return }
        let short = LinkTitlePreference.shortTitles() ? await LinkTitles.shortTitles(title, url) : []
        titles = short.isEmpty ? [] : [title] + short
    }

    private func retitle(_ title: String) {
        guard let url else { return }
        text = SharedContent.retitled(text, url: url, title: title)
    }

    /// Names containing every typed word, most recently edited first, which
    /// is where a just-read link is most likely to go.
    private var matches: [NoteRef] {
        let words = query.lowercased().split(separator: " ")
        let found = words.isEmpty ? notes : notes.filter { note in
            let name = note.relativePath.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return Array(found.prefix(50))
    }

    private var canAdd: Bool {
        vault != nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (choice != .note || picked != nil)
    }

    private var inboxName: String {
        let path = vault.map { InboxNotePreference.path(for: $0) } ?? InboxNotePreference.defaultPath
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private var destination: SharedVault.Destination? {
        switch choice {
        case .today: .today
        case .inbox: .inbox
        case .note: picked.map { .note($0.relativePath) }
        }
    }

    private func add() {
        guard let vault, let destination else { return }
        lastChoice = choice.rawValue
        do {
            try SharedVault.file(text, to: destination, in: vault)
            if case .note(let path) = destination {
                // As for a line added by Siri: the note you will want next.
                FrecencyStore.notes(forVaultAt: vault.path).record(path)
            }
            finish()
        } catch {
            problem = error.localizedDescription
        }
    }
}
