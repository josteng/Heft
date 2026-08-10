import AppKit
import SwiftUI

/// User-chosen colours for the caret and checkboxes (accent), links, inline
/// code, and the two colourful-formatting hues (bold, italic). App-wide
/// rather than per-vault, and shared as a singleton rather than living on
/// `AppModel` so a change in one window's Settings pane repaints every open
/// window immediately, instead of only the window that made the change.
///
/// `nil` means "use the built-in default", which is what makes per-colour
/// reset-to-default possible without a second set of "is this customised"
/// flags.
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    static let defaultAccentColor = NSColor.controlAccentColor
    static let defaultBoldColor = NSColor.systemRed
    static let defaultItalicColor = NSColor.systemOrange
    static let defaultCodeColor = NSColor.systemPink
    /// h1 through h6, in order.
    static let defaultHeadingColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
    ]

    @Published var customAccentColor: NSColor? {
        didSet { Self.persist(customAccentColor, key: Self.accentKey) }
    }
    /// Separate from `customAccentColor` so links can be recoloured without
    /// also recolouring the caret and checkboxes; `nil` falls back to
    /// whatever the accent colour currently is, not to a fixed constant, so
    /// an un-set link colour still tracks an accent change.
    @Published var customLinkColor: NSColor? {
        didSet { Self.persist(customLinkColor, key: Self.linkKey) }
    }
    @Published var customCodeColor: NSColor? {
        didSet { Self.persist(customCodeColor, key: Self.codeKey) }
    }
    @Published var customBoldColor: NSColor? {
        didSet { Self.persist(customBoldColor, key: Self.boldKey) }
    }
    @Published var customItalicColor: NSColor? {
        didSet { Self.persist(customItalicColor, key: Self.italicKey) }
    }
    /// One slot per heading level (index 0 = h1); `nil` entries fall back to
    /// `defaultHeadingColors`. A single array, rather than six named
    /// properties, so the settings row's one "Reset" button can clear all
    /// six at once without six separate calls.
    @Published var customHeadingColors: [NSColor?] = Array(repeating: nil, count: 6) {
        didSet {
            for (index, color) in customHeadingColors.enumerated() {
                Self.persist(color, key: Self.headingKey(index))
            }
        }
    }
    /// Was per-window on `AppModel` until every open window's copy could
    /// drift from every other's. Living here means one toggle, anywhere,
    /// repaints every open window immediately.
    @Published var colorfulFormattingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(colorfulFormattingEnabled, forKey: Self.colorfulFormattingKey)
        }
    }

    var accentColor: NSColor { customAccentColor ?? Self.defaultAccentColor }
    var linkColor: NSColor { customLinkColor ?? accentColor }
    var codeColor: NSColor { customCodeColor ?? Self.defaultCodeColor }
    var boldColor: NSColor { customBoldColor ?? Self.defaultBoldColor }
    var italicColor: NSColor { customItalicColor ?? Self.defaultItalicColor }

    /// - Parameter level: 1-based heading level, as written in Markdown (h1…h6+).
    func headingColor(_ level: Int) -> NSColor {
        let index = min(max(level, 1), Self.defaultHeadingColors.count) - 1
        return customHeadingColors[index] ?? Self.defaultHeadingColors[index]
    }

    var hasCustomHeadingColor: Bool { customHeadingColors.contains { $0 != nil } }
    func resetHeadingColors() { customHeadingColors = Array(repeating: nil, count: 6) }

    private static let accentKey = "dev.stenglein.Heft.appearance.accentColor"
    private static let linkKey = "dev.stenglein.Heft.appearance.linkColor"
    private static let codeKey = "dev.stenglein.Heft.appearance.codeColor"
    private static let boldKey = "dev.stenglein.Heft.appearance.boldColor"
    private static let italicKey = "dev.stenglein.Heft.appearance.italicColor"
    private static let colorfulFormattingKey = "dev.stenglein.Heft.colorfulFormatting"
    private static func headingKey(_ index: Int) -> String {
        "dev.stenglein.Heft.appearance.headingColor\(index + 1)"
    }

    private init() {
        customAccentColor = Self.load(Self.accentKey)
        customLinkColor = Self.load(Self.linkKey)
        customCodeColor = Self.load(Self.codeKey)
        customBoldColor = Self.load(Self.boldKey)
        customItalicColor = Self.load(Self.italicKey)
        customHeadingColors = (0..<6).map { Self.load(Self.headingKey($0)) }
        colorfulFormattingEnabled = UserDefaults.standard.object(forKey: Self.colorfulFormattingKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.colorfulFormattingKey)
    }

    private static func load(_ key: String) -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func persist(_ color: NSColor?, key: String) {
        guard let color,
              let data = try? NSKeyedArchiver.archivedData(
                withRootObject: color, requiringSecureCoding: true
              )
        else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The app-wide Settings scene's root (⌘,). Per-vault configuration (Daily
/// Notes) is deliberately not a tab here — it stays the per-window sheet it
/// always was, on `AppModel` — since this scene has no reliable way to know
/// which vault window a user meant: `@FocusedValue` stops publishing once
/// the Settings window itself becomes key, so a "current vault" tab here
/// would silently show stale or wrong data. Still a `TabView` (rather than a
/// bare view) so another genuinely app-wide preference pane has somewhere to
/// go without restructuring this.
///
/// Fixed width, but no fixed height: macOS's own Preferences windows keep
/// their top edge in place and resize the bottom edge to fit each tab's
/// content, which only happens automatically when the height is left
/// unconstrained.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 620)
    }
}

/// One row per customisable colour: a picker plus a reset button that only
/// lights up once that colour has actually been changed from its default.
struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        // `Form`/`LabeledContent` computed each row's label and control
        // column width independently here, so the first row visibly drifted
        // from the other two. A `Grid` shares one column width across every
        // `GridRow`, and the fixed frames below keep every swatch and every
        // Reset button the same size regardless of its row's text length.
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                colorRow(
                    "Accent Color",
                    detail: "The caret and checkboxes. Follows your macOS accent colour, "
                        + "not a fixed colour, unless set here.",
                    color: settableBinding(current: appearance.accentColor) { appearance.customAccentColor = $0 },
                    isCustom: appearance.customAccentColor != nil,
                    reset: { appearance.customAccentColor = nil },
                    resetHelp: "Follow your macOS accent colour again"
                )
                colorRow(
                    "Link Color",
                    detail: "Defaults to Accent Color above; set here to use a different "
                        + "colour just for links.",
                    color: settableBinding(current: appearance.linkColor) { appearance.customLinkColor = $0 },
                    isCustom: appearance.customLinkColor != nil,
                    reset: { appearance.customLinkColor = nil },
                    resetHelp: "Follow Accent Color again"
                )
                colorRow(
                    "Code Color",
                    detail: "For inline `code` spans.",
                    color: settableBinding(current: appearance.codeColor) { appearance.customCodeColor = $0 },
                    isCustom: appearance.customCodeColor != nil,
                    reset: { appearance.customCodeColor = nil },
                    resetHelp: "Reset to pink"
                )
            }

            Divider()

            Toggle(isOn: $appearance.colorfulFormattingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colourful Formatting").font(.headline)
                    Text("Gives bold, italic, and headings each their own colour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                colorRow(
                    "Bold Color",
                    detail: "For **bold** text.",
                    color: settableBinding(current: appearance.boldColor) {
                        appearance.customBoldColor = $0
                    },
                    isCustom: appearance.customBoldColor != nil,
                    reset: { appearance.customBoldColor = nil },
                    resetHelp: "Reset to red"
                )
                colorRow(
                    "Italic Color",
                    detail: "For *italic* text.",
                    color: settableBinding(current: appearance.italicColor) {
                        appearance.customItalicColor = $0
                    },
                    isCustom: appearance.customItalicColor != nil,
                    reset: { appearance.customItalicColor = nil },
                    resetHelp: "Reset to orange"
                )
                headingColorsRow()
            }
            .disabled(!appearance.colorfulFormattingEnabled)
            .opacity(appearance.colorfulFormattingEnabled ? 1 : 0.4)
        }
        .padding(20)
        .frame(width: 620, alignment: .leading)
    }

    /// `ColorPicker` can round-trip a dynamic system colour to a concrete
    /// one on its first layout pass and report that back through `set` as if
    /// the user had picked it — which would wrongly mark a still-default row
    /// as customised. Comparing resolved components filters that out while
    /// still passing through any colour a user actually picks.
    private func settableBinding(current: NSColor, set: @escaping (NSColor?) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: current) },
            set: { newValue in
                let picked = NSColor(newValue).usingColorSpace(.sRGB)
                let existing = current.usingColorSpace(.sRGB)
                if let picked, let existing,
                   abs(picked.redComponent - existing.redComponent) < 0.004,
                   abs(picked.greenComponent - existing.greenComponent) < 0.004,
                   abs(picked.blueComponent - existing.blueComponent) < 0.004 {
                    return
                }
                set(NSColor(newValue))
            }
        )
    }

    @ViewBuilder
    private func colorRow(
        _ title: String, detail: String, color: Binding<Color>, isCustom: Bool,
        reset: @escaping () -> Void, resetHelp: String
    ) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 22)

            Button("Reset", action: reset)
                .disabled(!isCustom)
                .help(resetHelp)
                .frame(width: 60)
        }
    }

    /// Six full rows for h1–h6 would dwarf everything else in this pane, so
    /// this is one row of small swatches instead, with a single Reset that
    /// clears all six back to the built-in rainbow at once. Needs the wider
    /// window (`SettingsWindow`'s 620pt, up from 420pt) to give six swatches
    /// real spacing without crowding Reset — they looked cramped at the
    /// narrower width even before adding a sixth colour to the row.
    @ViewBuilder
    private func headingColorsRow() -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heading Colors")
                Text("The stripe beside h1–h6 headings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { level in
                    ColorPicker(
                        "",
                        selection: settableBinding(current: appearance.headingColor(level)) { newColor in
                            var colors = appearance.customHeadingColors
                            colors[level - 1] = newColor
                            appearance.customHeadingColors = colors
                        },
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 22, height: 22)
                    // `ColorPicker`'s native swatch is a pill shape that
                    // ignores this frame and bleeds into neighbouring space,
                    // so six of them touch regardless of HStack spacing.
                    // Clipping stops the bleed and lets the spacing show.
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help("Heading \(level)")
                }
            }

            Button("Reset", action: appearance.resetHeadingColors)
                .disabled(!appearance.hasCustomHeadingColor)
                .help("Reset all six to their default colours")
                .frame(width: 60)
        }
    }
}
