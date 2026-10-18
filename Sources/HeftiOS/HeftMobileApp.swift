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
    @State private var tab: MobileTab = .files
    @State private var capture: CaptureSheetRequest?
    @State private var quickCapture: CaptureSheetRequest?
    @Environment(\.scenePhase) private var scenePhase
    private var request = CaptureRequest.shared

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
            .environment(\.mobileCapture) { capture = CaptureSheetRequest() }
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
    @ViewBuilder var root: Root
    @State private var path: [MobileRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { CaptureButton() }
                }
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

private struct CaptureButton: View {
    @Environment(\.mobileCapture) private var capture

    var body: some View {
        Button("Capture", systemImage: "square.and.pencil", action: capture)
    }
}
