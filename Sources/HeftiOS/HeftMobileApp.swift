import HeftCore
import SwiftUI

/// The iOS companion: browse, read, search, the calendar, and capture.
///
/// Deliberately not the Mac editor. The live surface is an `NSTextView` and
/// stays on the Mac; here a note is rendered from `MarkdownModel` and edited,
/// when it is, as plain text with an explicit save.
@main
struct HeftMobileApp: App {
    @State private var vault = MobileVault()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HeftMobileShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(vault)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vault.returnedToForeground() }
        }
    }
}

/// Where a navigation stack can go. Paths, not `NoteRef`s, so a route still
/// means the same note after a rescan has replaced every ref.
enum MobileRoute: Hashable {
    case folder(String)
    case note(String)
    case tag(String)
    case image(String)
}

extension EnvironmentValues {
    /// Pushes onto whichever stack the view is in; a link inside a note uses
    /// it to open the note it names.
    @Entry var mobilePush: (MobileRoute) -> Void = { _ in }
}

enum MobileTab: Hashable {
    case files, calendar, search
}

struct MobileRootView: View {
    @Environment(MobileVault.self) private var vault
    @State private var tab: MobileTab = .files
    @State private var capturing = false

    var body: some View {
        if vault.root == nil {
            VaultPickerView()
        } else {
            TabView(selection: $tab) {
                Tab("Files", systemImage: "folder", value: .files) {
                    MobileStack { FolderView(path: "") }
                }
                Tab("Calendar", systemImage: "calendar", value: .calendar) {
                    MobileStack { CalendarView() }
                }
                Tab(value: .search, role: .search) {
                    MobileStack { SearchView() }
                }
            }
            .tabViewBottomAccessory {
                Button { capturing = true } label: {
                    Label("Capture", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
            }
            .sheet(isPresented: $capturing) {
                CaptureSheet()
            }
            .onAppear(perform: applyLaunchRequest)
        }
    }

    private func applyLaunchRequest() {
        #if DEBUG
        // Screenshot hooks for a simulator run, where nothing can tap.
        let environment = ProcessInfo.processInfo.environment
        switch environment["HEFT_IOS_TAB"] {
        case "calendar": tab = .calendar
        case "search": tab = .search
        default: break
        }
        if environment["HEFT_IOS_CAPTURE"] != nil { capturing = true }
        #endif
    }
}

/// A navigation stack that knows every route, so a link followed from a note
/// in any tab lands in that tab.
struct MobileStack<Root: View>: View {
    @ViewBuilder var root: Root
    @State private var path: [MobileRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .folder(let folder): FolderView(path: folder)
                    case .note(let note): NoteView(path: note)
                    case .tag(let tag): TagView(tag: tag)
                    case .image(let image): ImageFileView(path: image)
                    }
                }
        }
        .environment(\.mobilePush) { path.append($0) }
    }
}

/// First launch: nothing to show until the reader hands Heft a folder.
struct VaultPickerView: View {
    @Environment(MobileVault.self) private var vault
    @State private var picking = false

    var body: some View {
        ContentUnavailableView {
            Label("Open a Vault", systemImage: "books.vertical")
        } description: {
            Text("Choose the folder that holds your notes. For an Obsidian vault in iCloud, that is the vault's folder inside Obsidian in iCloud Drive.")
        } actions: {
            Button("Choose Folder…") { picking = true }
                .buttonStyle(.borderedProminent)
            if let problem = vault.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vault.choose(url) }
        }
    }
}
