import HeftCore
import SwiftUI

/// Where the app opens: pinned notes, then every note by when it was last
/// written, grouped Today, Yesterday, Previous 7 Days and on, the way Notes
/// and the Mac's Recent list group theirs.
///
/// Drawn from `MobileVault.recent`, which a launch fills from the last run's
/// snapshot, so the list is there before the vault has been scanned.
struct RecentView: View {
    @Environment(MobileVault.self) private var vault
    @State private var creating: NewNoteRequest?
    @State private var action: ItemAction?

    var body: some View {
        let dating = RecentDating()
        let pinned = vault.pinnedNotes
        let pinnedPaths = Set(pinned.map(\.path))
        let groups = dating.grouped(vault.recent.filter { !pinnedPaths.contains($0.path) },
                                    date: \.modified)
        List {
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { RecentRow(note: $0, dating: dating) { action = $0 } }
                } header: {
                    Label("Pinned", systemImage: "pin.fill")
                }
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section(group.section.map(dating.title(of:)) ?? "") {
                    ForEach(group.items) { RecentRow(note: $0, dating: dating) { action = $0 } }
                }
            }
        }
        .overlay {
            if vault.recent.isEmpty {
                if vault.isScanning {
                    ProgressView(vault.status ?? "Reading your vault…")
                } else {
                    ContentUnavailableView("No Notes Yet", systemImage: "doc.text")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { ScanStatus() }
        .navigationTitle("Recent")
        .refreshable { vault.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NewNoteButton { creating = NewNoteRequest(folder: vault.newNoteFolder) }
            }
            ToolbarItem(placement: .topBarTrailing) { VaultMenu() }
        }
        .newNoteSheet($creating)
        .itemActionHost($action)
        #if DEBUG
        .onAppear {
            let environment = ProcessInfo.processInfo.environment
            if let name = environment["HEFT_IOS_NEW"] {
                creating = NewNoteRequest(folder: vault.newNoteFolder, name: name,
                                          makesFolder: environment["HEFT_IOS_NEW_KIND"] == "folder")
            }
        }
        #endif
    }
}

/// Title, then when and how it begins, then where it lives: the three
/// things the eye uses to tell one note from the next.
private struct RecentRow: View {
    let note: SharedVault.ListedNote
    let dating: RecentDating
    let perform: (ItemAction) -> Void

    var body: some View {
        NavigationLink(value: MobileRoute.note(note.path)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let modified = note.modified {
                        Text(dating.label(for: modified))
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                    Text(note.excerpt ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                if !note.folder.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(note.folder).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .itemActions(ItemRef(path: note.path, isFolder: false), perform)
    }
}

/// What a long first scan is doing, under a list that is already showing.
struct ScanStatus: View {
    @Environment(MobileVault.self) private var vault

    var body: some View {
        if let status = vault.status, !vault.recent.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect()
            .padding(.bottom, 6)
        }
    }
}
