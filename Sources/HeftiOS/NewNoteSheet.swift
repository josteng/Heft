import HeftCore
import SwiftUI

/// Where a New Note starts, and with what name.
struct NewNoteRequest: Identifiable {
    let id = UUID()
    var folder: String
    var name = ""
    var makesFolder = false
}

/// The compose button, as Notes has it.
struct NewNoteButton: View {
    let action: () -> Void

    var body: some View {
        Button("New Note", systemImage: "square.and.pencil", action: action)
    }
}

extension View {
    /// Asks for a name and a folder, then opens the note made there.
    func newNoteSheet(_ request: Binding<NewNoteRequest?>) -> some View {
        modifier(NewNoteSheetModifier(request: request))
    }
}

private struct NewNoteSheetModifier: ViewModifier {
    @Binding var request: NewNoteRequest?
    @Environment(\.mobilePush) private var push

    func body(content: Content) -> some View {
        content.sheet(item: $request) { start in
            NewNoteSheet(start: start) { route in
                request = nil
                push(route)
            }
            .presentationDetents([.medium])
        }
    }
}

/// The name first, because the filename is the title links use; the folder
/// under it, already set to where the note would go. A switch in the bar
/// makes a folder there instead, so one button makes both.
private struct NewNoteSheet: View {
    let start: NewNoteRequest
    let created: (MobileRoute) -> Void
    @Environment(MobileVault.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var folder: String
    @State private var makesFolder: Bool
    @State private var problem: String?
    @FocusState private var naming: Bool

    init(start: NewNoteRequest, created: @escaping (MobileRoute) -> Void) {
        self.start = start
        self.created = created
        _name = State(initialValue: start.name)
        _folder = State(initialValue: start.folder)
        _makesFolder = State(initialValue: start.makesFolder)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($naming)
                        .submitLabel(.done)
                        .onSubmit(create)
                    Picker("Location", selection: $folder) {
                        ForEach(vault.folderPaths, id: \.self) { path in
                            Label(title(of: path), systemImage: path.isEmpty ? "books.vertical" : "folder")
                                .tag(path)
                        }
                    }
                    // A menu, not a pushed list: the push took the keyboard
                    // away and the sheet dropped to half height under it.
                    .pickerStyle(.menu)
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .onChange(of: makesFolder) { problem = nil }
            .navigationTitle(makesFolder ? "New Folder" : "New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In the title's place, so the form below stays one group.
                ToolbarItem(placement: .principal) {
                    Picker("Kind", selection: $makesFolder) {
                        Text("Note").tag(false)
                        Text("Folder").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark", role: .confirm, action: create)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear {
                naming = true
                #if DEBUG
                if ProcessInfo.processInfo.environment["HEFT_IOS_NEW_CONFIRM"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: create)
                }
                #endif
            }
        }
    }

    /// A folder by its path, so two folders of one name stay apart.
    private func title(of path: String) -> String {
        path.isEmpty ? vault.name : path
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        do {
            if makesFolder {
                try vault.createFolder(named: trimmed, in: folder)
                // Into it, where the compose button makes its first note.
                let parent = NewNoteLocation.normalised(folder)
                let made = VaultOperations.sanitise(trimmed)
                created(.folder(parent.isEmpty ? made : "\(parent)/\(made)"))
            } else {
                let made = try vault.createNote(named: trimmed, in: folder)
                created(made.existed ? .note(made.path) : .newNote(made.path))
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
