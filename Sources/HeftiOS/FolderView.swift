import HeftCore
import SwiftUI
import UIKit

/// One folder of the vault, folders first, as the Mac sidebar orders them.
struct FolderView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @State private var launched = false
    @State private var creating: NewNoteRequest?
    @State private var action: ItemAction?

    var body: some View {
        Group {
            if let folder = vault.folder(at: path) {
                List(folder.children) { item in
                    if item.isFolder || item.kind == .markdown || item.kind == .image {
                        row(item)
                            .itemActions(ItemRef(path: item.relativePath, isFolder: item.isFolder)) { action = $0 }
                    } else {
                        row(item)
                    }
                }
                // A folder's list has no section heading, as Recent's "Today",
                // and began right under the large title.
                .contentMargins(.top, 26, for: .scrollContent)
                .overlay {
                    if folder.children.isEmpty, !vault.isScanning {
                        ContentUnavailableView("Empty Folder", systemImage: "folder")
                    }
                }
            } else if vault.isScanning || vault.tree == nil {
                ProgressView()
            } else {
                ContentUnavailableView("Folder Not Found", systemImage: "questionmark.folder")
            }
        }
        .safeAreaInset(edge: .bottom) { if path.isEmpty { ScanStatus() } }
        .navigationTitle(path.isEmpty ? vault.name : (path as NSString).lastPathComponent)
        .toolbarRole(.browser)
        .refreshable { vault.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NewNoteButton { creating = NewNoteRequest(folder: path) }
            }
            if path.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { VaultMenu() }
            }
        }
        .newNoteSheet($creating)
        .itemActionHost($action)
        .onAppear(perform: applyLaunchRequest)
    }

    @ViewBuilder
    private func row(_ item: VaultItem) -> some View {
        switch item.kind {
        case .folder:
            NavigationLink(value: MobileRoute.folder(item.relativePath)) {
                Label {
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text("\(item.children.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
        case .markdown:
            NavigationLink(value: MobileRoute.note(item.relativePath)) {
                fileLabel(item, symbol: "doc.text")
            }
        case .image:
            NavigationLink(value: MobileRoute.image(item.relativePath)) {
                fileLabel(item, symbol: "photo")
            }
        case .pdf, .canvas, .other:
            fileLabel(item, symbol: "doc")
                .foregroundStyle(.secondary)
        }
    }

    private func fileLabel(_ item: VaultItem, symbol: String) -> some View {
        Label {
            HStack {
                Text(item.name)
                if item.needsDownload {
                    Spacer()
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In iCloud")
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private func applyLaunchRequest() {
        #if DEBUG
        guard path.isEmpty, !launched else { return }
        launched = true

        if let request = ProcessInfo.processInfo.environment["HEFT_IOS_ITEM_ACTION"] {
            // After the scan, as a reader's long press would be.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let item = ItemRef(path: parts[1], isFolder: !parts[1].lowercased().hasSuffix(".md"))
                switch parts[0] {
                case "rename": action = .rename(item)
                case "move": action = .move(item)
                default: action = .delete(item)
                }
            }
            }
        }
        if let note = ProcessInfo.processInfo.environment["HEFT_IOS_NOTE"] {
            push(.note(note))
        }
        #endif
    }
}

/// Every note carrying a tag, newest edit first.
struct TagView: View {
    let tag: String
    @Environment(MobileVault.self) private var vault

    var body: some View {
        let edited = vault.index.notesByLastEdit
        let tagged = Set(vault.index.notes(taggedWith: tag).map(\.relativePath))
        List(edited.filter { tagged.contains($0.relativePath) }) { note in
            NoteRow(note: note)
        }
        .navigationTitle("#\(tag)")
        .toolbarRole(.browser)
    }
}

/// A note in a list: its name, and the folder it is in when there is one.
struct NoteRow: View {
    let note: NoteRef

    var body: some View {
        NavigationLink(value: MobileRoute.note(note.relativePath)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name)
                if !note.folder.isEmpty {
                    Text(note.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ImageFileView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
    @State private var image: UIImage?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .containerRelativeFrame(.horizontal)
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            guard let url = vault.root?.appendingPathComponent(path) else { return }
            image = await MobileImages.load(url)
        }
    }
}

enum MobileImages {
    /// Loads off the main thread and through a coordinator, so a picture
    /// still in iCloud is fetched rather than drawn as nothing.
    static func load(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            var data: Data?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) {
                data = try? Data(contentsOf: $0)
            }
            return data.flatMap(UIImage.init(data:))
        }.value
    }
}
