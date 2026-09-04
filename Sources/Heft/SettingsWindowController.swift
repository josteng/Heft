import AppKit
import SwiftUI

/// The Settings window, as AppKit builds one.
///
/// SwiftUI's `Settings` scene could not size these panes. Not because it never
/// shrinks — measured on macOS 26 it shrinks perfectly well for a pane with a
/// definite height — but because every pane here is a `Form` in the grouped
/// style, which *is* a scroll view and so has no definite height to offer. It
/// accepts whatever the window already has, so visiting the 720pt Typing pane
/// left every pane after it at 720. The workaround was to lay each pane out
/// off screen in a second `NSHostingView`, read its `fittingSize`, and resize
/// the window by hand.
///
/// That cost more than it bought. The measurement is taken in one context and
/// applied in another, so it has been wrong three times — a pane clipped
/// halfway down a control, a pane measured a line short and given a scroll
/// bar. And because the height was read from `body`, a *second live copy* of
/// the pane on screen was built and laid out on every pass, which is both
/// wasteful and enough to leave a tab item rendering blank.
///
/// `NSTabViewController` with the toolbar style is what most Mac settings
/// windows are, and resizing the window to each tab is a feature of it rather
/// than something to arrange. `NSHostingController.sizingOptions` is the
/// bridge: it makes AppKit take the controller's `preferredContentSize` from
/// what SwiftUI says it needs, which is the number the measuring was trying
/// to work out by hand.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private let tabs = SettingsTabController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsPane.width, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        // Remembered per user, the way a Mac settings window is.
        window.setFrameAutosaveName("dev.stenglein.Heft.settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var hasBeenShown = false

    /// Opens it, or brings it forward if it is already open.
    ///
    /// Centred only the first time. Centring on every open would move a window
    /// the reader had put somewhere, which is the opposite of what a Mac
    /// settings window does — and it would quietly undo the frame the autosave
    /// name above exists to remember.
    func show(_ registry: VaultRegistry) {
        tabs.install(registry: registry)
        NSApp.activate(ignoringOtherApps: true)
        if !hasBeenShown {
            hasBeenShown = true
            if window?.frameAutosaveName.isEmpty != false { window?.center() }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The panes, and what each is called.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, startup, typing, calendar, attachments, vim

    var id: String { rawValue }

    static let width: CGFloat = 630

    /// As tall as a pane may make the window.
    ///
    /// Nothing clamps `preferredContentSize`, so a tall pane simply gets a
    /// tall window: the Typing pane wants about 720pt, which with the titlebar
    /// and the tab bar is more than a 13-inch display has, in a window that
    /// cannot be resized and does not scroll. Capped here, the grouped Form
    /// inside scrolls instead, which is what a settings pane too long for the
    /// screen should do.
    static var maximumHeight: CGFloat {
        max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 160)
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .startup: "Startup"
        case .typing: "Typing"
        case .calendar: "Calendar"
        case .attachments: "Attachments"
        case .vim: "Vim (Experimental)"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .startup: "sunrise"
        case .typing: "keyboard"
        case .calendar: "calendar"
        case .attachments: "paperclip"
        case .vim: "terminal"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .startup: StartupSettingsView()
        case .typing: TypingSettingsView()
        case .calendar: CalendarSettingsView()
        case .attachments: AttachmentSettingsView()
        case .vim: VimSettingsView()
        }
    }
}

/// One hosting controller per pane, sized from its SwiftUI content.
@MainActor
final class SettingsTabController: NSTabViewController {

    private var isInstalled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        // The window follows whichever pane is showing, which is the whole
        // reason this is an NSTabViewController and not a TabView.
        transitionOptions = []
    }

    /// Builds the panes once, with the environment they need.
    func install(registry: VaultRegistry) {
        guard !isInstalled else { return }
        isInstalled = true
        loadViewIfNeeded()
        for pane in SettingsPane.allCases {
            let host = NSHostingController(
                rootView: AnyView(
                    pane.content
                        .environmentObject(registry)
                        .appAccentTint()
                        .frame(width: SettingsPane.width)
                        .frame(maxHeight: SettingsPane.maximumHeight)
                )
            )
            // What replaces the hand measurement: AppKit reads the size
            // SwiftUI asks for, and the tab controller resizes the window.
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(
                systemSymbolName: pane.symbol, accessibilityDescription: pane.title
            )
            addTabViewItem(item)
        }
    }

    /// The window takes the pane's name, the way Mac settings windows do.
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = item?.label ?? "Settings"
    }
}
