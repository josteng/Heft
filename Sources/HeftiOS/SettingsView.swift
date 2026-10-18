import HeftCore
import SwiftUI
import UIKit

/// The pages of Settings, as the Mac has tabs: a list to pick one from, so a
/// new page is a new row and not a longer form.
enum SettingsPage: String, Hashable, CaseIterable {
    case appearance, vault

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .vault: "Vault"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
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
    @Environment(MobileVault.self) private var vault
    @State private var settings: SettingsRequest?
    /// The launch hook opens Settings once, on whichever screen shows first.
    @MainActor private static var launched = false

    var body: some View {
        Menu {
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
                    NavigationLink {
                        HeadingColorsView()
                    } label: {
                        HStack {
                            Text("Headings")
                            Spacer()
                            HeadingSwatches(appearance: appearance)
                        }
                    }
                }
                .disabled(!appearance.colorfulFormatting)
            } footer: {
                Text("Gives bold, italic and headings each their own color. "
                    + "Shared with Heft on your Mac through the vault.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ key: WritableKeyPath<AppearancePreferences, Bool>) -> Binding<Bool> {
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
            Text("Weekend plans")
                .font(.title3.bold())
                .foregroundStyle(colorful ? Color(uiColor: appearance.headingColor(1)) : .primary)
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
