import HeftCore
import SwiftUI
import UIKit

/// The pages of Settings, as the Mac has tabs: a list to pick one from, so a
/// new page is a new row and not a longer form.
enum SettingsPage: String, Hashable, CaseIterable {
    case appearance, browsing, search, vault

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .browsing: "Browsing"
        case .search: "Search"
        case .vault: "Vault"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .browsing: "sidebar.left"
        case .search: "magnifyingglass"
        case .vault: "books.vertical"
        }
    }
}

/// Which page Settings opens on, carried with the request.
struct SettingsRequest: Identifiable {
    let id = UUID()
    var page: SettingsPage?
}

/// Settings and Refresh, on the two screens a library opens on: Recent,
/// where the app starts, and the top of Files.
struct VaultMenu: View {
    /// The iPad's month at the foot of its sidebar, shown or hidden here.
    var calendarShown: Binding<Bool>?
    /// Capture, where the bar has no button of its own for it.
    var capture: (() -> Void)?
    @Environment(MobileVault.self) private var vault
    @State private var settings: SettingsRequest?
    /// The launch hook opens Settings once, on whichever screen shows first.
    @MainActor private static var launched = false

    var body: some View {
        Menu {
            if let capture {
                Button("Capture", systemImage: "text.badge.plus", action: capture)
            }
            if let calendarShown {
                Button(calendarShown.wrappedValue ? "Hide Calendar" : "Show Calendar", systemImage: "calendar") {
                    withAnimation(.snappy) { calendarShown.wrappedValue.toggle() }
                }
            }
            Button("Settings", systemImage: "gearshape") { settings = SettingsRequest() }
            Button("Refresh", systemImage: "arrow.clockwise") { vault.refresh() }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .tint(.primary)
        .sheet(item: $settings) { SettingsView(page: $0.page) }
        .onAppear {
            #if DEBUG
            guard !Self.launched else { return }
            Self.launched = true
            if let requested = ProcessInfo.processInfo.environment["HEFT_IOS_SETTINGS"] {
                settings = SettingsRequest(page: SettingsPage(rawValue: requested))
            }
            #endif
        }
    }
}

struct SettingsView: View {
    var page: SettingsPage?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        NavigationLink(value: page) {
                            Label(page.title, systemImage: page.symbol)
                        }
                    }
                } footer: {
                    Text(Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .appearance: AppearanceSettingsView()
                case .browsing: BrowsingSettingsView()
                case .search: SearchSettingsView()
                case .vault: VaultSettingsView()
                }
            }
        }
        .onAppear { if let page { path = [page] } }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Heft \(version) (\(build))"
    }
}

/// The Mac's Appearance colours, read from and written to the vault, so a
/// change on either shows on the other once the vault has synced.
private struct AppearanceSettingsView: View {
    @Environment(MobileVault.self) private var vault

    var body: some View {
        let appearance = vault.appearance
        Form {
            Section {
                SettingsPreview(appearance: appearance)
            }
            Section {
                colorRow("Accent", \.accent, current: appearance.accentColor)
            } footer: {
                Text("Checkboxes, the caret and what iOS draws in blue. Follows the system when not set.")
            }
            Section {
                colorRow("Links", \.link, current: appearance.linkColor)
                colorRow("Tags", \.tag, current: appearance.tagColor)
                colorRow("Code", \.code, current: appearance.codeColor)
            } footer: {
                Text("Links and tags follow the accent when not set.")
            }
            Section {
                Toggle("Colorful Formatting", isOn: binding(\.colorfulFormatting))
                Group {
                    colorRow("Bold", \.bold, current: appearance.boldColor)
                    colorRow("Italic", \.italic, current: appearance.italicColor)
                }
                .disabled(!appearance.colorfulFormatting)
            } footer: {
                Text("Gives bold and italic each their own color.")
            }
            Section {
                Picker("Font", selection: setting(\.headingFont)) {
                    ForEach(AppearancePreferences.HeadingFont.allCases) { Text($0.title).tag($0) }
                }
                Picker("Color", selection: setting(\.headingColor)) {
                    ForEach(AppearancePreferences.HeadingColor.allCases) { Text($0.title).tag($0) }
                }
                if appearance.headingColor == .levelColors {
                    NavigationLink {
                        HeadingColorsView()
                    } label: {
                        HStack {
                            Text("Level Colors")
                            Spacer()
                            HeadingSwatches(appearance: appearance)
                        }
                    }
                }
            } header: {
                Text("Headings")
            } footer: {
                Text("New York is Apple's serif. Level Colors draws a bar in each level's color beside the heading.")
            }
        }
        .syncBadge(synced: true)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ key: WritableKeyPath<AppearancePreferences, Bool>) -> Binding<Bool> {
        setting(key)
    }

    private func setting<Value>(_ key: WritableKeyPath<AppearancePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { vault.appearance[keyPath: key] },
            set: { value in
                var changed = vault.appearance
                changed[keyPath: key] = value
                vault.setAppearance(changed)
            }
        )
    }

    private func colorRow(
        _ title: String, _ key: WritableKeyPath<AppearancePreferences, String?>, current: UIColor
    ) -> some View {
        ColorSettingRow(title: title, isCustom: vault.appearance[keyPath: key] != nil, current: current) { hex in
            var changed = vault.appearance
            changed[keyPath: key] = hex
            vault.setAppearance(changed)
        }
    }
}

/// One colour: a picker, and Reset once it is set.
///
/// A picker can hand its own default back on first layout, resolved to a
/// fixed colour; that is not a choice, so a colour equal to the current one
/// is ignored rather than stored as custom.
private struct ColorSettingRow: View {
    let title: String
    let isCustom: Bool
    let current: UIColor
    let set: (String?) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ColorPicker(title, selection: Binding(
                get: { Color(uiColor: current) },
                set: { picked in
                    let hex = AppearancePreferences.hex(UIColor(picked))
                    if hex != AppearancePreferences.hex(current) { set(hex) }
                }
            ), supportsOpacity: false)
            if isCustom {
                Button("Reset") { set(nil) }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
        }
    }
}

private struct HeadingColorsView: View {
    @Environment(MobileVault.self) private var vault

    var body: some View {
        let appearance = vault.appearance
        Form {
            Section {
                ForEach(1...6, id: \.self) { level in
                    ColorSettingRow(
                        title: "Heading \(level)", isCustom: appearance.headings[level - 1] != nil,
                        current: appearance.headingColor(level)
                    ) { hex in
                        var changed = vault.appearance
                        changed.headings[level - 1] = hex
                        vault.setAppearance(changed)
                    }
                }
            }
            if appearance.headings.contains(where: { $0 != nil }) {
                Section {
                    Button("Reset All Headings") {
                        var changed = vault.appearance
                        changed.headings = Array(repeating: nil, count: 6)
                        vault.setAppearance(changed)
                    }
                }
            }
        }
        .navigationTitle("Headings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HeadingSwatches: View {
    let appearance: AppearancePreferences

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...6, id: \.self) { level in
                Circle()
                    .fill(Color(uiColor: appearance.headingColor(level)))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A few lines in the chosen colours, so a change is seen where it is made.
private struct SettingsPreview: View {
    let appearance: AppearancePreferences

    var body: some View {
        let colorful = appearance.colorfulFormatting
        VStack(alignment: .leading, spacing: 6) {
            // As the editor draws a heading: its face, and the bar beside it
            // when headings have level colours.
            HStack(spacing: 9) {
                if appearance.headingColor == .levelColors {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(uiColor: appearance.headingColor(1)))
                        .frame(width: 3, height: 18)
                }
                Text("Weekend plans")
                    .font(appearance.headingFont == .newYork
                          ? .system(.title3, design: .serif) : .title3.bold())
            }
            Text(line([
                ("Buy ", nil, nil),
                ("fresh bread", colorful ? appearance.boldColor : nil, .body.bold()),
                (" and ", nil, nil),
                ("maybe flowers", colorful ? appearance.italicColor : nil, .body.italic()),
                (".", nil, nil),
            ]))
            Text(line([
                ("See ", nil, nil),
                ("Garden", appearance.linkColor, nil),
                (", ", nil, nil),
                ("#home", appearance.tagColor, nil),
                (" and ", nil, nil),
                ("todo.md", appearance.codeColor, .body.monospaced()),
                (".", nil, nil),
            ]))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func line(_ runs: [(String, UIColor?, Font?)]) -> AttributedString {
        runs.reduce(into: AttributedString()) { line, run in
            var piece = AttributedString(run.0)
            if let color = run.1 { piece.foregroundColor = Color(uiColor: color) }
            if let font = run.2 { piece.font = font }
            line += piece
        }
    }
}

/// Recent's order and rows, as the Mac's Appearance sets them, and where
/// the app starts.
private struct BrowsingSettingsView: View {
    @Bindable private var preferences = BrowsingPreferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Ordered By", selection: $preferences.recentOrder) {
                    ForEach(BrowsingPreferences.RecentOrder.allCases) { Text($0.title).tag($0) }
                }
                Picker("Rows", selection: $preferences.recentLayout) {
                    ForEach(BrowsingPreferences.RecentLayout.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Recent")
            } footer: {
                Text("Last Edited follows the files' dates, so a note changed on another device rises too. "
                    + "Last Opened is this device's own history. Preview shows the date, first line and folder.")
            }
            Section {
                Picker("Start With", selection: $preferences.start) {
                    ForEach(BrowsingPreferences.Start.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("What Heft shows when it opens. On an iPad it chooses the sidebar's list, "
                    + "or opens today's note beside it.")
            }
        }
        .syncBadge(synced: false)
        .navigationTitle("Browsing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Whether a page's settings travel with the vault to the Mac, or stay on
/// this device: an icon at the top right, explained when tapped.
private struct SyncBadge: ViewModifier {
    let synced: Bool
    @State private var explains = false

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(synced ? "Synced" : "This Device Only",
                       systemImage: synced ? "arrow.triangle.2.circlepath.icloud"
                           : UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") {
                    explains = true
                }
                .tint(.primary)
                .popover(isPresented: $explains) {
                    Text(synced
                         ? "Synced with Heft on your Mac, through the vault."
                         : "Kept on this device only. Heft on your Mac has its own.")
                        .font(.subheadline)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }
}

extension View {
    func syncBadge(synced: Bool) -> some View { modifier(SyncBadge(synced: synced)) }
}

/// The Mac's Settings ▸ Search: what Search Everything lists before
/// anything is typed, and each scope's order. This device's own, as on the
/// Mac, which keeps its own.
private struct SearchSettingsView: View {
    @State private var list = StartList.current
    @State private var orders = ScopeOrders.current
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                    StartRowEditor(row: row, fillsRest: list.fillsRest(row)) { list.rows[index] = $0 }
                }
                .onMove { list.rows.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { list.rows.remove(atOffsets: $0) }
                Button("Add Row", systemImage: "plus") {
                    list.rows.append(.init(.recent, [.notes], count: 5))
                }
                Button("Reset to Standard", role: .destructive) { confirmsReset = true }
                    .disabled(list.matches(.standard))
            } header: {
                Text("Search Everything")
            } footer: {
                Text("What it lists before anything is typed, from the top: recent, frequent or pinned, "
                    + "of whichever kinds you choose. Something an earlier row lists is not listed again. "
                    + "The last row fills the rest. Swipe to delete; Edit to reorder.")
            }
            Section {
                ForEach(ScopeOrders.Kind.allCases) { kind in
                    ScopeOrderRows(kind: kind, order: Binding(
                        get: { orders[kind] },
                        set: { orders[kind] = $0 }
                    ))
                }
            } header: {
                Text("Inside a Scope")
            } footer: {
                Text("What each lists before anything is typed. Typing always ranks by match.")
            }
        }
        .syncBadge(synced: false)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: list) { list.save(in: HeftDefaults.shared) }
        .onChange(of: orders) { orders.save(in: HeftDefaults.shared) }
        .confirmationDialog("Reset Search Everything to the standard list?", isPresented: $confirmsReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { list = .standard }
        } message: {
            Text("Your rows are replaced by pinned, recent notes, then what you use most, then every note.")
        }
    }
}

/// One start row: its order, its kinds, and how many it lists.
private struct StartRowEditor: View {
    let row: StartList.Row
    let fillsRest: Bool
    let changed: (StartList.Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Picker("Order", selection: Binding(
                        get: { row.order },
                        set: { value in var next = row; next.order = value; changed(next) }
                    )) {
                        ForEach(StartList.Order.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Text(row.order.title).font(.headline)
                }
                Menu {
                    // Chats are Ask's, which is the Mac's.
                    ForEach(StartList.Kind.allCases.filter { $0 != .chats }) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { row.kinds.contains(kind) },
                            set: { on in
                                var next = row
                                if on { next.kinds.insert(kind) } else { next.kinds.remove(kind) }
                                changed(next)
                            }
                        ))
                    }
                } label: {
                    Text(row.kindsSummary).lineLimit(1)
                }
                Spacer()
            }
            if fillsRest {
                Text("Fills the rest").font(.footnote).foregroundStyle(.secondary)
            } else {
                Stepper("\(row.count) at most", value: Binding(
                    get: { row.count },
                    set: { value in changed(.init(id: row.id, row.order, row.kinds, count: value)) }
                ), in: StartList.countRange)
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One scope's order before typing, and, where it is split, how many lead
/// on a row of its own.
private struct ScopeOrderRows: View {
    let kind: ScopeOrders.Kind
    @Binding var order: QuickOpenOrder

    var body: some View {
        Picker(kind.title, selection: Binding(
            get: { order.mode },
            set: { order = order.with(mode: $0) }
        )) {
            ForEach(QuickOpenOrder.Mode.choices(lastEdited: kind.listsNotes)) { Text($0.title).tag($0) }
        }
        .padding(.leading, kind.isNested ? 12 : 0)
        if order.mode.isSplit {
            Stepper("\(order.count) first", value: Binding(
                get: { order.count },
                set: { order = QuickOpenOrder(lead: order.lead, count: $0) }
            ), in: 1...QuickOpenOrder.countRange.upperBound)
            .foregroundStyle(.secondary)
            .padding(.leading, kind.isNested ? 24 : 12)
        }
    }
}

/// Which vault, and what Heft read from its Obsidian settings.
private struct VaultSettingsView: View {
    @Environment(MobileVault.self) private var vault
    @State private var choosing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: vault.name)
                Button("Change Vault…") { choosing = true }
                Button("Refresh") { vault.refresh() }
            } footer: {
                Text("Heft rescans when it opens and after its own changes.")
            }
            Section {
                LabeledContent("New Notes", value: vault.newNoteFolder.isEmpty ? vault.name : vault.newNoteFolder)
                LabeledContent("Daily Notes",
                               value: vault.settings.dailyNotesFolder.isEmpty ? vault.name : vault.settings.dailyNotesFolder)
            } footer: {
                Text("From the vault's Obsidian settings, which Heft on the Mac uses too.")
            }
        }
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vault.choose(url) }
        }
    }
}
