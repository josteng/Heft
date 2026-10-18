import HeftCore
import SwiftUI
import UIKit

/// The iOS companion: browse, read, search, the calendar, and capture.
///
/// Deliberately not the Mac editor. The live surface is an `NSTextView` and
/// stays on the Mac; here a note is rendered from `MarkdownModel` and edited,
/// when it is, as plain text with an explicit save.
@main
struct HeftMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: MobileAppDelegate
    @State private var vault = MobileVault()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Intents resolve notes in this process, sometimes before a window:
        // the vault on screen, else the bookmarked one.
        NoteEntityQuery.vaultLocator = {
            MobileVault.currentRoot ?? SharedVault.bookmarkedRoot(startAccessing: true)
        }
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
    /// A note just made, opened with the keyboard up.
    case newNote(String)
    case tag(String)
    case image(String)
}

extension EnvironmentValues {
    /// Pushes onto whichever stack the view is in; a link inside a note uses
    /// it to open the note it names.
    @Entry var mobilePush: (MobileRoute) -> Void = { _ in }
    /// Swaps the screen on top for another, as when its note was renamed.
    @Entry var mobileReplace: (MobileRoute) -> Void = { _ in }
}

enum MobileTab: Hashable {
    case recent, files, calendar, search
}

extension EnvironmentValues {
    /// Opens the capture sheet; the small toolbar button on each tab uses it.
    @Entry var mobileCapture: () -> Void = {}
}

/// One sheet request, so the sheet can be told which destination to start on.
struct CaptureSheetRequest: Identifiable {
    let id = UUID()
    var target: CaptureTarget?
}

/// Home Screen quick actions: long-press the icon for the two captures.
/// The scene delegate exists for them alone, since SwiftUI has no hook for
/// a quick action chosen while the app is already running.
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    static let actions: [(type: String, title: String, symbol: String, target: CaptureTarget)] = [
        ("dev.stenglein.HeftMobile.captureToday", "Add to Today", "calendar.badge.plus", .today),
        ("dev.stenglein.HeftMobile.captureInbox", "Capture to Inbox", "tray.and.arrow.down", .inbox),
    ]

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = Self.actions.map {
            UIApplicationShortcutItem(
                type: $0.type, localizedTitle: $0.title, localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: $0.symbol)
            )
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { Self.perform(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = MobileSceneDelegate.self
        return configuration
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = actions.first(where: { $0.type == item.type }) else { return false }
        CaptureRequest.shared.target = action.target
        return true
    }
}

final class MobileSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(MobileAppDelegate.perform(shortcutItem))
    }
}

struct MobileRootView: View {
    @Environment(MobileVault.self) private var vault
    @State private var tab: MobileTab = .recent
    @State private var capture: CaptureSheetRequest?
    @State private var quickCapture: CaptureSheetRequest?
    /// A note open on the Mac, chosen from the app switcher.
    @State private var handedOff: MobileRoute?
    @Environment(\.scenePhase) private var scenePhase
    private var request = CaptureRequest.shared
    private var noteRequest = NoteOpenRequest.shared

    var body: some View {
        if vault.root == nil {
            VaultPickerView()
        } else {
            TabView(selection: $tab) {
                Tab("Recent", systemImage: "clock", value: .recent) {
                    MobileStack(incoming: $handedOff) { RecentView() }
                }
                Tab("Files", systemImage: "folder", value: .files) {
                    MobileStack { FolderView(path: "") }
                }
                Tab("Calendar", systemImage: "calendar", value: .calendar) {
                    // The calendar places Capture itself, after Today.
                    MobileStack(showsCapture: false) { CalendarView() }
                }
                Tab(value: .search, role: .search) {
                    MobileStack { SearchView() }
                }
            }
            .environment(\.mobileCapture) { capture = CaptureSheetRequest() }
            // What the system draws blue takes the vault's accent; the bar's
            // icons stay neutral, as iOS draws them whatever an app's colour.
            .tint(vault.appearance.appTint)
            .sheet(item: $capture) { capture in
                CaptureSheet(requested: capture.target)
            }
            .fullScreenCover(item: $quickCapture) { capture in
                CaptureSheet(requested: capture.target, fullScreen: true)
            }
            .onChange(of: request.target, initial: true) { _, target in
                guard let target else { return }
                request.target = nil
                // Arriving from a control or the Home Screen, the panel is the
                // first thing seen: no slide up over a library nobody asked for.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    capture = nil
                    quickCapture = CaptureSheetRequest(target: target)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // The full-screen panel is a one-off: leaving the app without
                // Done means coming back to the library, not to the panel.
                // An unfiled line survives as the capture draft.
                guard phase == .background, quickCapture != nil else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { quickCapture = nil }
            }
            .onChange(of: noteRequest.path, initial: true) { _, path in
                guard let path else { return }
                noteRequest.path = nil
                capture = nil
                quickCapture = nil
                tab = .recent
                handedOff = .note(path)
            }
            .onContinueUserActivity(HandoffNote.activityType) { activity in
                guard let note = HandoffNote(userInfo: activity.userInfo) else { return }
                capture = nil
                quickCapture = nil
                tab = .recent
                handedOff = .note(note.path)
            }
            .onAppear(perform: applyLaunchRequest)
        }
    }

    private func applyLaunchRequest() {
        #if DEBUG
        // Screenshot hooks for a simulator run, where nothing can tap.
        let environment = ProcessInfo.processInfo.environment
        switch environment["HEFT_IOS_TAB"] {
        case "files": tab = .files
        case "calendar": tab = .calendar
        case "search": tab = .search
        default: break
        }
        // The path an Open Note intent takes, without Shortcuts.
        if let path = environment["HEFT_IOS_OPEN"] { NoteOpenRequest.shared.path = path }
        if environment["HEFT_IOS_CAPTURE"] != nil {
            if environment["HEFT_IOS_QUICK"] != nil {
                quickCapture = CaptureSheetRequest(target: .inbox)
            } else {
                capture = CaptureSheetRequest()
            }
        }
        #endif
    }
}

/// A navigation stack that knows every route, so a link followed from a note
/// in any tab lands in that tab.
struct MobileStack<Root: View>: View {
    var showsCapture = true
    /// A screen to open from outside, replacing whatever was pushed.
    var incoming: Binding<MobileRoute?> = .constant(nil)
    @ViewBuilder var root: Root
    @State private var path: [MobileRoute] = []
    /// A note on the root screen has the keyboard: capture is for getting a
    /// line in without a note open, so it gives the bar to undo and Done.
    @State private var typing = false

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    if showsCapture, !typing {
                        ToolbarItem(placement: .topBarTrailing) { CaptureButton() }
                    }
                }
                .onPreferenceChange(TypingInNoteKey.self) { typing = $0 }
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .folder(let folder): FolderView(path: folder)
                    case .note(let note): NoteView(path: note)
                    case .newNote(let note): NoteView(path: note, startsTyping: true)
                    case .tag(let tag): TagView(tag: tag)
                    case .image(let image): ImageFileView(path: image)
                    }
                }
        }
        .environment(\.mobilePush) { path.append($0) }
        .environment(\.mobileReplace) { route in
            if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
        }
        .onChange(of: incoming.wrappedValue, initial: true) { _, route in
            guard let route else { return }
            incoming.wrappedValue = nil
            path = [route]
        }
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

struct CaptureButton: View {
    @Environment(\.mobileCapture) private var capture

    var body: some View {
        Button("Capture", systemImage: "text.badge.plus", action: capture)
            .tint(.primary)
    }
}

/// Raised by a note being typed into, for the stack around it.
struct TypingInNoteKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
