import HeftCore
import SwiftUI
import UIKit

/// One folder of the vault, folders first, as the Mac sidebar orders them.
struct FolderView: View {
    let path: String
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobilePush) private var push
    @State private var choosingVault = false
    @State private var launched = false

    var body: some View {
        Group {
            if let folder = vault.folder(at: path) {
                List(folder.children) { item in
                    row(item)
                }
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
        .navigationTitle(path.isEmpty ? vault.name : (path as NSString).lastPathComponent)
        .refreshable { vault.refresh() }
        .toolbar {
            if path.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") { vault.refresh() }
                        Button("Change Vault…", systemImage: "folder.badge.gearshape") {
                            choosingVault = true
                        }
                    } label: {
                        Label("Vault", systemImage: "ellipsis")
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingVault, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vault.choose(url) }
        }
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
