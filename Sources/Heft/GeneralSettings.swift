import Foundation
import HeftCore
import SwiftUI

/// The app-wide preferences that are not about how anything looks.
///
/// Kept apart from Startup, which answers one question per vault, and from
/// Appearance, which is about the page. These are about how the app behaves:
/// where a new note lands, and whether a window opens with its calendar.
///
/// App-wide rather than per-vault, for the reason `AttachmentSettings` is: they
/// describe how this person works rather than how one vault is arranged. The
/// one that could go either way is the named new-note folder, and a vault
/// without it gets the folder made on demand rather than a silent fallback.
@MainActor
final class GeneralSettings: ObservableObject {
    static let shared = GeneralSettings()

    /// One key, shared with the extension through `HeftCore`.
    private static let newNoteKey = NewNoteLocation.defaultsKey
    private static let calendarKey = "dev.stenglein.Heft.general.calendarVisibility"
    private static let agentOfferKey = "dev.stenglein.Heft.general.offersAgentSetup"

    @Published var newNoteLocation: NewNoteLocation {
        didSet {
            HeftDefaults.shared.set(newNoteLocation.stored, forKey: Self.newNoteKey)
        }
    }

    @Published var calendarVisibility: CalendarVisibility {
        didSet {
            HeftDefaults.shared.set(calendarVisibility.rawValue, forKey: Self.calendarKey)
        }
    }

    /// Whether a vault without agent instructions is offered them. Off is
    /// for someone who does not use agents and would otherwise answer the
    /// question once per vault; the menu item and the command line still
    /// write the guide on request.
    @Published var offersAgentSetup: Bool {
        didSet {
            HeftDefaults.shared.set(offersAgentSetup, forKey: Self.agentOfferKey)
        }
    }

    /// What each scope lists before anything is typed, recent or frequent
    /// first, chosen per scope. Stored by `ScopeOrders` itself.
    @Published var scopeOrders: ScopeOrders {
        didSet { scopeOrders.save(in: HeftDefaults.shared) }
    }

    /// The notes' order, which was the only one before there were more.
    var quickOpenOrder: QuickOpenOrder {
        get { scopeOrders[.notes] }
        set { scopeOrders[.notes] = newValue }
    }

    /// Which sidebar views show, in what order, and which a window opens on.
    @Published var sidebarLayout: SidebarLayout {
        didSet { sidebarLayout.save() }
    }

    /// The same for the right sidebar's views.
    @Published var inspectorLayout: InspectorLayout {
        didSet { inspectorLayout.save() }
    }

    /// Whether the search bar shows what its keys do along its bottom. On
    /// by default, since nothing else says ⌘D pins; off for a reader who has
    /// learnt them and wants the row back.
    @Published var showsKeyHints: Bool {
        didSet { HeftDefaults.shared.set(showsKeyHints, forKey: Self.keyHintsKey) }
    }
    static let keyHintsKey = "dev.stenglein.Heft.searchBar.keyHints"

    /// The agent the search bar's Ask runs: a command on the PATH or a full
    /// path, and the model it is asked to use.
    /// Whether the search bar offers Ask at all. Off until turned on: it
    /// runs an agent the reader may not have, on their own plan.
    @Published var asksAgent: Bool {
        didSet { HeftDefaults.shared.set(asksAgent, forKey: Self.asksAgentKey) }
    }
    static let asksAgentKey = "dev.stenglein.Heft.agent.enabled"

    /// When the bar with no scope puts Ask first, selected, rather than
    /// last: what Return does with text that reads as a question.
    enum AskFirst: String, CaseIterable, Identifiable {
        case forQuestions, whenNothingFound, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forQuestions: "For questions"
            case .whenNothingFound: "When nothing is found"
            case .never: "Never"
            }
        }
    }
    @Published var askFirst: AskFirst {
        didSet { HeftDefaults.shared.set(askFirst.rawValue, forKey: Self.askFirstKey) }
    }
    static let askFirstKey = "dev.stenglein.Heft.agent.askFirst"

    /// Whether chats are named by Apple's on-device model after their
    /// first answer. On by default; off, a chat keeps its first question.
    @Published var namesChats: Bool {
        didSet { HeftDefaults.shared.set(namesChats, forKey: Self.namesChatsKey) }
    }
    static let namesChatsKey = "dev.stenglein.Heft.agent.namesChats"

    /// Whether an empty chat in the right sidebar offers questions to ask
    /// about what is open. On by default.
    @Published var suggestsQuestions: Bool {
        didSet { HeftDefaults.shared.set(suggestsQuestions, forKey: Self.suggestsQuestionsKey) }
    }
    static let suggestsQuestionsKey = "dev.stenglein.Heft.agent.suggestsQuestions"

    /// Whether renaming a note offers names Apple's on-device model
    /// suggests from what is in it, as Finder does. On by default.
    @Published var suggestsNames: Bool {
        didSet { HeftDefaults.shared.set(suggestsNames, forKey: Self.suggestsNamesKey) }
    }
    static let suggestsNamesKey = "dev.stenglein.Heft.general.suggestsNames"

    @Published var agentCommand: String {
        didSet { HeftDefaults.shared.set(agentCommand, forKey: Self.agentCommandKey) }
    }
    @Published var agentModel: String {
        didSet { HeftDefaults.shared.set(agentModel, forKey: Self.agentModelKey) }
    }
    static let agentCommandKey = "dev.stenglein.Heft.agent.command"
    static let agentModelKey = "dev.stenglein.Heft.agent.model"
    static let standardAgentCommand = "claude"
    static let standardAgentModel = "haiku"

    /// What ⌘T lists before anything is typed, stored by `StartList`.
    @Published var startList: StartList {
        didSet { startList.save(in: HeftDefaults.shared) }
    }

    private init() {
        scopeOrders = ScopeOrders.current(in: HeftDefaults.shared)
        startList = StartList.current(in: HeftDefaults.shared)
        sidebarLayout = SidebarLayout.current()
        inspectorLayout = InspectorLayout.current()
        asksAgent = HeftDefaults.shared.bool(forKey: Self.asksAgentKey)
        suggestsNames = HeftDefaults.shared.object(forKey: Self.suggestsNamesKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.suggestsNamesKey)
        namesChats = HeftDefaults.shared.object(forKey: Self.namesChatsKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.namesChatsKey)
        suggestsQuestions = HeftDefaults.shared.object(forKey: Self.suggestsQuestionsKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.suggestsQuestionsKey)
        askFirst = HeftDefaults.shared.string(forKey: Self.askFirstKey)
            .flatMap(AskFirst.init(rawValue:)) ?? .forQuestions
        agentCommand = HeftDefaults.shared.string(forKey: Self.agentCommandKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardAgentCommand
        agentModel = HeftDefaults.shared.string(forKey: Self.agentModelKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardAgentModel
        showsKeyHints = HeftDefaults.shared.object(forKey: Self.keyHintsKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.keyHintsKey)
        offersAgentSetup = HeftDefaults.shared.object(forKey: Self.agentOfferKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.agentOfferKey)
        newNoteLocation = NewNoteLocation(
            stored: HeftDefaults.shared.string(forKey: Self.newNoteKey) ?? ""
        )
        calendarVisibility = HeftDefaults.shared.string(forKey: Self.calendarKey)
            .flatMap(CalendarVisibility.init(rawValue:)) ?? .whenDailyNotesAreInScope
    }
}

/// The General pane.
///
/// The state is read in `body` and written back through a `Binding`, never
/// copied in `onAppear`: the Settings window measures each pane off screen to
/// size itself, and `onAppear` never fires for a view that is never on screen,
/// so a pane filled in there measures as its own empty placeholder.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared

    /// Which of the four the picker is on. Held apart from the folder text so
    /// that switching away from "a folder" and back does not lose what was
    /// typed, the way an attachment rule keeps its name while switched off.
    private enum Choice: String, CaseIterable, Identifiable {
        case beside, focus, root, folder
        var id: String { rawValue }

        var title: String {
            switch self {
            case .beside: "Beside the note I am reading"
            case .focus: "In the folder this window is showing"
            case .root: "At the top of the vault"
            case .folder: "In a specific folder"
            }
        }
    }

    /// Empty, not a guess. It was "Inbox", which is a *note* in at least one
    /// real vault — so the suggestion would have made a folder beside a file
    /// of the same name, which is the one thing a default here must not do.
    @State private var typedFolder = ""

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch settings.newNoteLocation {
                case .besideTheOpenNote: .beside
                case .focusedFolder: .focus
                case .vaultRoot: .root
                case .folder: .folder
                }
            },
            set: { new in
                settings.newNoteLocation = switch new {
                case .beside: .besideTheOpenNote
                case .focus: .focusedFolder
                case .root: .vaultRoot
                case .folder: .folder(typedFolder)
                }
            }
        )
    }

    private var folder: Binding<String> {
        Binding(
            get: {
                if case .folder(let path) = settings.newNoteLocation { return path }
                return typedFolder
            },
            set: { new in
                typedFolder = new
                if case .folder = settings.newNoteLocation {
                    settings.newNoteLocation = .folder(new)
                }
            }
        )
    }


    var body: some View {
        Form {
            Section {
                Picker(selection: choice) {
                    ForEach(Choice.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(
                        "New notes go",
                        detail: "Where ⌘N and the sidebar's + button put a note. A folder "
                            + "picked in the sidebar first still wins."
                    )
                }
                .defaultMenuTint()
                if choice.wrappedValue == .folder {
                    // Bordered and with its label hidden, the way the Startup
                    // pane's path field is: a plain `TextField` in a grouped
                    // Form draws as right-aligned text with no edge to it, so
                    // it reads as a value someone else set rather than as
                    // something to type in.
                    LabeledContent {
                        TextField("", text: folder, prompt: Text("Projects/Notes"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    } label: {
                        SettingLabel(
                            "Folder",
                            detail: "Made when the first note goes in it, if it is not there yet."
                        )
                    }
                }
                let unavailable = OnDeviceModel.unavailableReason
                Toggle(isOn: Binding(
                    get: { settings.suggestsNames && unavailable == nil },
                    set: { settings.suggestsNames = $0 }
                )) {
                    SettingLabel(
                        "Suggest names when renaming",
                        detail: unavailable ?? "Renaming a note offers names Apple Intelligence suggests "
                            + "from what is in it, on this Mac, as Finder does."
                    )
                }
                .disabled(unavailable != nil)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { settings.offersAgentSetup },
                    set: { settings.offersAgentSetup = $0 }
                )) {
                    SettingLabel(
                        "Offer agent setup for new vaults",
                        detail: settings.offersAgentSetup
                            ? "A vault without agent instructions is asked once whether to add them. "
                                + "Not Now is remembered for that vault."
                            : "Never asked. File ▸ Set Up Agent Access still writes the instructions when you want them."
                    )
                }
            }

            Section {
                PanelLayoutRows(
                    layout: $settings.sidebarLayout, shortcutPrefix: "⌘", shortcutCount: 3,
                    opensOnDetail: "The view a new window's sidebar starts in. Last used comes back "
                        + "where you were, after a relaunch too."
                )
                Picker(selection: Binding(
                    get: { settings.calendarVisibility },
                    set: { settings.calendarVisibility = $0 }
                )) {
                    ForEach(CalendarVisibility.allCases) { Text($0.title).tag($0) }
                } label: {
                    // What the setting decides is how a window *opens*. Saying
                    // so matters because ⇧⌘D still works either way, and a
                    // setting that looked absolute would read as broken the
                    // first time it was overridden by hand.
                    SettingLabel(
                        "Show the calendar",
                        detail: settings.calendarVisibility == .whenDailyNotesAreInScope
                            ? "How a window opens: without the calendar when it is showing a folder "
                                + "that holds no daily notes. ⇧⌘D shows and hides it at any time."
                            : "How every window opens. ⇧⌘D shows and hides it at any time."
                    )
                }
                .defaultMenuTint()
            } header: {
                SectionHeading(
                    "Sidebar",
                    detail: "The views it switches between, in order; ⌘1 to ⌘3 follow them. "
                        + "With one shown, the switch above the list goes away."
                )
            }

            Section {
                // With Ask off there is one view and nothing to arrange; a
                // list with Ask ticked but off, and Backlinks unticked but
                // showing, said the opposite of what the sidebar did.
                if settings.asksAgent {
                    PanelLayoutRows(
                        layout: $settings.inspectorLayout, shortcutPrefix: "⌥⌘", shortcutCount: 2,
                        opensOnDetail: "The view a new window's right sidebar starts in. ⌥⌘0 shows and hides it."
                    )
                } else {
                    Text("Ask is off, so the right sidebar shows Backlinks. Turn Ask on in Settings ▸ Ask "
                        + "to have both, and choose their order here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                SectionHeading(
                    "Right Sidebar",
                    detail: "About the note that is open. ⌥⌘1 and ⌥⌘2 follow its views."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// A side's views in Settings: each switched on or off and dragged into
/// place, with the shortcut it has and the view a window opens on. One list
/// for the left side and the right, so they work alike.
struct PanelLayoutRows<Mode: PanelMode>: View {
    @Binding var layout: PanelLayout<Mode>
    /// The shortcut's modifiers as shown before its number: ⌘ or ⌥⌘.
    let shortcutPrefix: String
    let shortcutCount: Int
    let opensOnDetail: String
    private static var rowHeight: CGFloat { 32 }

    /// Whether `mode` is the last view ticked, which stays: a side with none
    /// would be an empty column.
    static func isLastShown(_ mode: Mode, in layout: PanelLayout<Mode>) -> Bool {
        layout.entries.contains { $0.mode == mode && $0.isShown } && !layout.canHide(mode)
    }

    var body: some View {
        List {
            ForEach(Array(layout.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 10) {
                    // The handle says the row drags, as in the other
                    // ordered lists here.
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    let isLast = Self.isLastShown(entry.mode, in: layout)
                    // The last one ticked stays ticked, unticking it does
                    // nothing, and it looks like the others: disabled, it
                    // read as switched off along with everything else.
                    Toggle("", isOn: Binding(
                        get: { entry.isShown },
                        set: { if $0 || !isLast { layout.entries[index].isShown = $0 } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(isLast ? "At least one view stays in the sidebar" : "")
                    Label(entry.mode.title, systemImage: entry.mode.symbol)
                        .foregroundStyle(entry.isShown ? .primary : .secondary)
                    Spacer()
                    // No number with one view: there is nothing to switch to.
                    if let number = layout.visible.firstIndex(of: entry.mode),
                       entry.isShown, number < shortcutCount, layout.visible.count > 1 {
                        Text("\(shortcutPrefix)\(number + 1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(height: Self.rowHeight)
                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            }
            .onMove { layout.entries.move(fromOffsets: $0, toOffset: $1) }
        }
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollDisabled(true)
        .frame(height: CGFloat(layout.entries.count) * Self.rowHeight)
        .alternatingRowBackgrounds()

        // With one view there is nothing to open on but it.
        if layout.visible.count > 1 {
            Picker(selection: $layout.start) {
                ForEach(PanelLayout<Mode>.Start.allCases.prefix(2)) { Text($0.title).tag($0) }
                Divider()
                ForEach(PanelLayout<Mode>.Start.allCases.dropFirst(2)) { Text($0.title).tag($0) }
            } label: {
                SettingLabel("Opens on", detail: opensOnDetail)
            }
            .defaultMenuTint()
        }
    }
}
