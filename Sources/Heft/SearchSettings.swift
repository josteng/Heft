import HeftCore
import SwiftUI

/// The Search pane: what every search list shows before anything is typed.
///
/// Its own tab, out of General, once there were two lists of settings for
/// it: each scope's recent-or-frequent order, and ⌘T's start list. The
/// values are still kept by `GeneralSettings`, which the search bar reads.
struct SearchSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared
    private static let startRowHeight: CGFloat = 40
    @State private var confirmsStartReset = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showsKeyHints) {
                    SettingLabel(
                        "Show key hints",
                        detail: "A line under the results with the keys you can use, such as how to pin."
                    )
                }
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
                        + "you use most, one after the other, or simply by name. Notes can also go "
                        + "by when they were last edited. Typing always ranks by match."
                )
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
                        // Kept ticked while Ask is off, and listed again
                        // once it is on.
                        .disabled(kind == .chats && !GeneralSettings.shared.asksAgent)
                        .help(kind == .chats && !GeneralSettings.shared.asksAgent ? "Turn on Ask in Settings ▸ Ask" : "")
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

/// One scope's order: recent or frequent first, either alone, or a plain
/// sort, and how many come first. A row per scope, so the notes can open on what was
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
                .padding(.leading, kind.isNested ? 16 : 0)
            Spacer(minLength: 8)
            // The count stands before the menu and reads with it, "5 Recent
            // first". An order without one leaves its place empty on the
            // side of the gap, where it does not show, and the menus still
            // end in one column.
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
            Picker("", selection: Binding(
                get: { order.mode },
                set: { order = order.with(mode: $0) }
            )) {
                ForEach(QuickOpenOrder.Mode.choices(lastEdited: kind.listsNotes)) { mode in
                    // By use above, plain sorts below.
                    if mode == .alphabetical { Divider() }
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
            .defaultMenuTint()
            // As wide as the widest choice, so the counts line up too.
            .frame(width: Self.menuWidth, alignment: .trailing)
        }
    }

    private static let menuWidth: CGFloat = 130
}
