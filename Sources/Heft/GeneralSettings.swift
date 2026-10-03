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

    /// What ⌘T lists before anything is typed, stored by `StartList`.
    @Published var startList: StartList {
        didSet { startList.save(in: HeftDefaults.shared) }
    }

    private init() {
        scopeOrders = ScopeOrders.current(in: HeftDefaults.shared)
        startList = StartList.current(in: HeftDefaults.shared)
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

    private static let startRowHeight: CGFloat = 40
    @State private var confirmsStartReset = false

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
            }

            Section {
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
                ForEach(ScopeOrders.Kind.allCases) { kind in
                    ScopeOrderRow(
                        kind: kind,
                        order: Binding(
                            get: { settings.scopeOrders[kind] },
                            set: { settings.scopeOrders[kind] = $0 }
                        )
                    )
                }
            } header: {
                SectionHeading(
                    "Inside a scope",
                    detail: "What each lists before anything is typed: what you used last, what "
                        + "you use most, or one after the other. What is listed first is not listed "
                        + "again below it. Typing always ranks by match."
                )
            }

            Section {
                List {
                    ForEach(Array(settings.startList.rows.enumerated()), id: \.element.id) { index, row in
                        StartRowView(
                            row: row,
                            fillsRest: settings.startList.fillsRest(row),
                            onChange: { settings.startList.rows[index] = $0 },
                            onDelete: { settings.startList.rows.remove(at: index) }
                        )
                        .frame(height: Self.startRowHeight)
                        // The list's own row padding is what made the height
                        // a guess; without it a row is exactly its frame.
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                    }
                    .onMove { settings.startList.rows.move(fromOffsets: $0, toOffset: $1) }
                }
                // Exactly as tall as its rows: each row has a fixed height and
                // the list's own margins are gone. An estimate of the height
                // left a gap under the last row wherever rows came out shorter.
                .environment(\.defaultMinListRowHeight, Self.startRowHeight)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .scrollDisabled(true)
                .frame(height: CGFloat(max(settings.startList.rows.count, 1)) * Self.startRowHeight)
                .alternatingRowBackgrounds()
            } header: {
                SectionHeading(
                    "Search Everything (⌘T)",
                    detail: "What it lists before anything is typed, from the top: recent or "
                        + "frequent, of whichever kinds you tick. Something an earlier row lists "
                        + "is not listed again by a later one. The last row fills the rest; drag "
                        + "a row to reorder."
                )
            } footer: {
                HStack {
                    Button("Add Row") {
                        settings.startList.rows.append(.init(.recent, [.notes], count: 5))
                    }
                    Spacer()
                    // Asked first: a list of rows takes some building, and
                    // Settings has no undo to bring it back.
                    Button("Reset") { confirmsStartReset = true }
                        .disabled(settings.startList.matches(.standard))
                        .confirmationDialog(
                            "Reset Search Everything to the standard list?",
                            isPresented: $confirmsStartReset
                        ) {
                            Button("Reset", role: .destructive) { settings.startList = .standard }
                        } message: {
                            Text("Your rows are replaced by recent notes, then what you use most, then every note.")
                        }
                }
            }

        }
        .formStyle(.grouped)
    }
}

/// One row of ⌘T's start list: which order, which kinds, how many, and a
/// way to remove it. Dragged to reorder, as the attachment rules are.
private struct StartRowView: View {
    let row: StartList.Row
    /// The last row has no count: it fills the rest.
    let fillsRest: Bool
    let onChange: (StartList.Row) -> Void
    let onDelete: () -> Void
    @State private var isChoosingKinds = false

    private func changed(_ edit: (inout StartList.Row) -> Void) {
        var next = row
        edit(&next)
        onChange(next)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Says the row can be dragged, which nothing else about it does.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

            // Both controls are buttons of a fixed width with one chevron at
            // their trailing edge: the order's pop-up sized itself to its word,
            // so its arrows sat at a different place in every row, and the
            // kinds grew with their list, which moved the popover hung from
            // their middle as boxes were ticked.
            Menu {
                Picker("", selection: Binding(
                    get: { row.order },
                    set: { value in changed { $0.order = value } }
                )) {
                    ForEach(StartList.Order.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                RowControlLabel(title: row.order.title, width: 84)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .defaultMenuTint()

            // Checkboxes in a popover rather than a menu: a macOS menu closes
            // on the first click, and kinds are ticked several at a time.
            Button {
                isChoosingKinds = true
            } label: {
                RowControlLabel(title: row.kindsSummary, width: 170)
            }
            .fixedSize()
            .defaultMenuTint()
            .popover(isPresented: $isChoosingKinds, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(StartList.Kind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { row.kinds.contains(kind) },
                            set: { on in changed { if on { $0.kinds.insert(kind) } else { $0.kinds.remove(kind) } } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    Divider()
                    HStack {
                        Button("All") { changed { $0.kinds = Set(StartList.Kind.allCases) } }
                        Button("None") { changed { $0.kinds = [] } }
                    }
                    .controlSize(.small)
                }
                .padding(12)
            }

            Spacer(minLength: 8)

            if fillsRest {
                Text("The rest").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    TextField("", value: Binding(
                        get: { row.count },
                        set: { value in changed { $0 = .init(id: $0.id, $0.order, $0.kinds, count: value) } }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                    .labelsHidden()
                    Stepper("", value: Binding(
                        get: { row.count },
                        set: { value in changed { $0 = .init(id: $0.id, $0.order, $0.kinds, count: value) } }
                    ), in: StartList.countRange)
                    .labelsHidden()
                }
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this row")
        }
        .padding(.vertical, 2)
        .opacity(row.kinds.isEmpty ? 0.55 : 1)
    }
}

/// A start row's control: its value on the left, one chevron at the right,
/// at a fixed width so the chevron and anything hung from the control stay
/// put from row to row and as the value changes.
private struct RowControlLabel: View {
    let title: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }
}

/// One scope's order: recent or frequent first, or either alone, and how
/// many come first. A row per scope, so the notes can open on what was
/// opened last while the commands open on what is run most.
private struct ScopeOrderRow: View {
    let kind: ScopeOrders.Kind
    @Binding var order: QuickOpenOrder

    private var count: Binding<Int> {
        Binding(
            get: { order.count },
            set: { order = QuickOpenOrder(lead: order.lead, count: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(kind.title)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { order.mode },
                set: { order = order.with(mode: $0) }
            )) {
                ForEach(QuickOpenOrder.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .defaultMenuTint()
            // The count's place is kept when an "only" order has none, so
            // the menus line up down the table.
            HStack(spacing: 4) {
                TextField("", value: count, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                    .labelsHidden()
                Stepper("", value: count, in: 1...QuickOpenOrder.countRange.upperBound)
                    .labelsHidden()
            }
            .opacity(order.mode.isSplit ? 1 : 0)
            .disabled(!order.mode.isSplit)
            .help("How many come before the other order")
        }
    }
}
