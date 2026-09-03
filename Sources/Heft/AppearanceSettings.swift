import AppKit
import SwiftUI
import HeftCore

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
    /// Falls back to the accent colour for the same reason links do: a tag is
    /// something to click through, and reads as one when it shares their
    /// colour.
    @Published var customTagColor: NSColor? {
        didSet { Self.persist(customTagColor, key: Self.tagKey) }
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
            HeftDefaults.shared.set(colorfulFormattingEnabled, forKey: Self.colorfulFormattingKey)
        }
    }

    var accentColor: NSColor { customAccentColor ?? Self.defaultAccentColor }
    var linkColor: NSColor { customLinkColor ?? accentColor }
    var tagColor: NSColor { customTagColor ?? accentColor }
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
    private static let tagKey = "dev.stenglein.Heft.appearance.tagColor"
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
        customTagColor = Self.load(Self.tagKey)
        customCodeColor = Self.load(Self.codeKey)
        customBoldColor = Self.load(Self.boldKey)
        customItalicColor = Self.load(Self.italicKey)
        customHeadingColors = (0..<6).map { Self.load(Self.headingKey($0)) }
        colorfulFormattingEnabled = HeftDefaults.shared.object(forKey: Self.colorfulFormattingKey) == nil
            ? true
            : HeftDefaults.shared.bool(forKey: Self.colorfulFormattingKey)
    }

    private static func load(_ key: String) -> NSColor? {
        guard let data = HeftDefaults.shared.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func persist(_ color: NSColor?, key: String) {
        guard let color,
              let data = try? NSKeyedArchiver.archivedData(
                withRootObject: color, requiringSecureCoding: true
              )
        else {
            HeftDefaults.shared.removeObject(forKey: key)
            return
        }
        HeftDefaults.shared.set(data, forKey: key)
    }
}

/// Applies the chosen accent colour to a whole scene.
///
/// SwiftUI resolves `Color.accentColor` and every stock control's highlight
/// from the environment, so tinting once at a scene's root reaches the
/// calendar, the sidebar's selection, Quick Open, search and the rest without
/// each of them having to know the setting exists. Only drawing that bypasses
/// SwiftUI — the AppKit completion panel, the editor's own widgets — has to
/// read `AppearanceSettings` for itself.
/// The accent colour to paint with, for views that draw their own highlight
/// rather than letting a stock control do it.
///
/// `.tint` alone was not enough: it steers stock controls, but SwiftUI's
/// `Color.accentColor` kept resolving to the *system* accent, so the calendar
/// dots and the sidebar's selection ignored the setting. Views that fill a
/// shape themselves read this instead of `Color.accentColor`.
private struct AppAccentKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: AppearanceSettings.defaultAccentColor)
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}

private struct AppAccent: ViewModifier {
    @ObservedObject private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        let accent = Color(nsColor: appearance.accentColor)
        return content.tint(accent).environment(\.appAccent, accent)
    }
}

extension View {
    /// Tints this scene with the user's accent colour. Belongs at a scene
    /// root; anywhere deeper and the views above it keep the system accent.
    func appAccentTint() -> some View { modifier(AppAccent()) }
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

    /// The tabs, as one table. The window measures the selected pane to size
    /// itself, so a second hand-written list of which view is in which tab
    /// would be a thing to keep in step and a thing to get wrong.
    enum Tab: String, CaseIterable, Hashable, Identifiable {
        case appearance, startup, typing, calendar, attachments, vim

        var id: String { rawValue }

        var title: String {
            switch self {
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
            case .appearance: AppearanceSettingsView()
            case .startup: StartupSettingsView()
            case .typing: TypingSettingsView()
            case .calendar: CalendarSettingsView()
            case .attachments: AttachmentSettingsView()
            case .vim: VimSettingsView()
            }
        }
    }

    @EnvironmentObject private var registry: VaultRegistry
    // Observed so the window re-measures when a pane changes shape, not only
    // when the tab does: choosing a rule that needs a folder name, or a startup
    // note that needs a path, grows the pane by a row, and a window sized once
    // per tab then clips it.
    @ObservedObject private var startup = StartupSettings.shared
    @ObservedObject private var attachments = AttachmentSettings.shared
    @ObservedObject private var typing = TypingSettings.shared
    @State private var tab: Tab = .appearance

    /// Measured on every pass rather than cached: it is one hosting view for a
    /// window nobody opens in a loop, and anything cached here has to be
    /// invalidated by whatever might change a pane's height, which is a list
    /// that would rot.
    private var paneHeight: CGFloat {
        Self.idealHeight(of: tab, registry: registry)
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        // Pinned to the pane that is showing, rather than left to the tab
        // view's own idea of its size. Asking the window afterwards measured
        // the tab on its way out, so the window was always one tab behind:
        // right on the one it opened with, too tall or too short for the rest.
        .frame(width: Self.paneWidth, height: paneHeight > 0 ? paneHeight : nil)
        .background(FitsItsWindow(trigger: paneHeight))
    }

    static let paneWidth: CGFloat = 630

    /// What a pane would take if nothing constrained it.
    ///
    /// Measured by laying the pane out on the side rather than by asking the
    /// window: a `TabView`'s own fitting size is the tallest tab's, whichever
    /// one is showing, which is exactly the number that made every short pane
    /// sit in a window sized for the long one.
    @MainActor
    static func idealHeight(of tab: Tab, registry: VaultRegistry) -> CGFloat {
        let host = NSHostingView(
            rootView: AnyView(tab.content.environmentObject(registry))
        )
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}

/// Resizes the Settings window to whichever tab is showing.
///
/// A SwiftUI Settings window grows for a taller tab and never shrinks back, so
/// one visit to the longest pane leaves every short one in a window mostly
/// empty. Measured: the Calendar pane wants 276pt against the 720 Typing needs.
private struct FitsItsWindow: NSViewRepresentable {
    /// Only there to make SwiftUI run `updateNSView` when the pane changes size.
    let trigger: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // After this layout pass, so the content is the height just asked for.
        // The tab bar's own height comes along in `fittingSize`, which is the
        // showing pane plus that chrome, so there is nothing to work out.
        DispatchQueue.main.async {
            guard let window = view.window, let content = window.contentView else { return }
            let wanted = content.fittingSize.height
            // A tolerance, because setting the size a window already has posts
            // a resize, which lays out and asks again.
            guard wanted > 0, abs(content.frame.height - wanted) > 1 else { return }
            window.setContentSize(NSSize(width: content.frame.width, height: wanted))
        }
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
        // One `Grid` for every row, not two, so the label column — and
        // therefore where every swatch starts — is sized from all six rows
        // together. Two separate `Grid`s here previously sized their label
        // columns independently, so Bold/Italic/Heading (short labels)
        // drifted away from Reset compared to Accent/Link/Code (long ones).
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
                "Tag Color",
                detail: "For #tags and the pill behind them. Defaults to Accent Color above.",
                color: settableBinding(current: appearance.tagColor) { appearance.customTagColor = $0 },
                isCustom: appearance.customTagColor != nil,
                reset: { appearance.customTagColor = nil },
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

            // A view given directly to `Grid`, not wrapped in `GridRow`,
            // spans every column automatically.
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

            Group {
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
        .frame(width: 630, alignment: .leading)
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
            // A fixed width, not `maxWidth: .infinity`: an infinitely
            // flexible column makes the whole `Grid` stretch to fill this
            // pane's outer frame, and since the text itself does not need
            // that much room, the swatch column it pushed the label column's
            // *allocated* width to be far wider than the *visible* text,
            // leaving a dead gap before the swatch that had nothing to do
            // with wrapping.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.labelColumnWidth, alignment: .leading)

            // Right-anchored rather than a plain fixed frame: the shared
            // swatch column is as wide as the heading-colour pill, which is
            // wider than one swatch, and it should still sit next to Reset
            // rather than float at the column's left edge.
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 22)
                .frame(width: Self.swatchColumnWidth, alignment: .trailing)

            Button("Reset", action: reset)
                .disabled(!isCustom)
                .help(resetHelp)
                .frame(width: 60)
        }
    }

    /// Fixed widths for both non-Reset columns, shared by `colorRow` and
    /// `headingColorsRow`: see the comment in `colorRow` for why these are
    /// not `maxWidth: .infinity`. `swatchColumnWidth` fits the six-segment
    /// heading pill (6 × 30pt segments + 5 × 1pt gaps) with a little slack.
    private static let labelColumnWidth: CGFloat = 300
    private static let swatchColumnWidth: CGFloat = 190

    /// A heading segment, plus the border around the whole pill, comes to
    /// the same 18pt of colour inside a 3pt band that a single swatch above
    /// draws, so the pill reads as one more control in the same column
    /// rather than a differently built thing of its own kind. Six segments
    /// and their border stay inside `swatchColumnWidth`.
    private static let headingSegmentWidth: CGFloat = 29
    private static let headingSegmentHeight: CGFloat = 18
    private static let headingBorderWidth: CGFloat = 3
    private static let headingSeparatorWidth: CGFloat = 2

    /// A colour well darkens the outermost 1pt of its fill by about 8%, on
    /// all four sides — measured off a screenshot of one, not guessed. The
    /// pill reproduces it so its segments are shaded like every other
    /// swatch in the column instead of looking flatly printed.
    private static let edgeShadingOpacity: Double = 0.08
    private static let edgeShadingWidth: CGFloat = 1

    /// Six full rows for h1–h6 would dwarf everything else in this pane, so
    /// this is one row of small swatches instead, with a single Reset that
    /// clears all six back to the built-in rainbow at once.
    @ViewBuilder
    private func headingColorsRow() -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heading Colors")
                Text("The stripe beside h1–h6 headings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.labelColumnWidth, alignment: .leading)

            // One connected pill — rounded at the two outer ends, square
            // where segments meet — rather than six independent swatches,
            // since h1–h6 read as one sequence, not six unrelated choices.
            // A 1pt gap keeps each segment's click target legible without
            // breaking the pill silhouette. Right-anchored, like the single
            // swatches above, so it sits next to Reset instead of floating
            // at the shared column's left edge.
            HStack(spacing: Self.headingSeparatorWidth) {
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
                    .frame(width: Self.headingSegmentWidth, height: Self.headingSegmentHeight)
                    // Each picker draws its own bordered pill, which is the
                    // chrome a single swatch above wants and a segment of a
                    // shared pill does not: six of them stacked up as six
                    // borders. At this size the well fills the segment and
                    // the clip takes that chrome off, leaving flat colour
                    // and a control that is still a stock colour well
                    // opening the stock panel.
                    .clipShape(Rectangle())
                    .help("Heading \(level)")
                }
            }
            // The rounded ends are cut from the whole row rather than from
            // its first and last segment: rounding the end segments meant
            // two radii that had to agree, and the row is taller than a
            // 22pt swatch (that native chrome again), so its capsule bowed
            // wider than the segments' own corners and bared a crescent at
            // each end.
            // Divides the segments in the same grey as the border, rather
            // than letting the pane show through, so the pill is one
            // control with rules in it and not six chips that happen to sit
            // in a row. The rules stay a step narrower than the border,
            // which is how a segmented control divides itself.
            // Shades each segment's edge where it meets a separator, in the
            // 1pt of 8% black a colour well darkens its own fill edge by.
            //
            // It has to be drawn from out here, over the whole row, rather
            // than by each segment over itself: a colour well is an AppKit
            // control, and a `.overlay` hung on one composites underneath
            // it, so a segment cannot draw on top of its own fill. An
            // overlay on the row draws above all six. Hence the geometry is
            // restated here instead of just aligning to each segment.
            .overlay {
                HStack(spacing: 0) {
                    ForEach(1...6, id: \.self) { level in
                        HStack(spacing: 0) {
                            Color.black
                                .opacity(level == 1 ? 0 : Self.edgeShadingOpacity)
                                .frame(width: Self.edgeShadingWidth)
                            Spacer(minLength: 0)
                            Color.black
                                .opacity(level == 6 ? 0 : Self.edgeShadingOpacity)
                                .frame(width: Self.edgeShadingWidth)
                        }
                        .frame(width: Self.headingSegmentWidth)

                        if level < 6 {
                            Color.clear.frame(width: Self.headingSeparatorWidth)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .background(.separator)
            .frame(height: Self.headingSegmentHeight)
            .clipShape(Capsule())
            // Top, bottom and the two curved ends of the same 1pt shading
            // the segments carry between themselves, so the fill is ringed
            // by it on every side exactly as a colour well's fill is.
            .overlay(
                Capsule().strokeBorder(
                    Color.black.opacity(Self.edgeShadingOpacity),
                    lineWidth: Self.edgeShadingWidth
                )
            )
            // The border goes around the outside of the colours, not over
            // them. `strokeBorder` draws inside its shape, so stroking the
            // capsule the colours are clipped to put the grey straight onto
            // saturated red and purple at the two ends, where it vanished.
            // Padding first strokes a slightly larger capsule (a uniform
            // offset of a capsule is another capsule), so the border sits
            // on the pane's own background the whole way round and never
            // has to out-contrast a fill.
            //
            // The width matches what a colour well actually draws, read off
            // a screenshot rather than guessed: a 3pt band, hard against
            // the fill, in exactly the grey `separator` already resolves
            // to. Padding and line width are equal so the border fills that
            // band entirely, leaving no gap the single swatches don't have.
            .padding(Self.headingBorderWidth)
            .overlay(Capsule().strokeBorder(.separator, lineWidth: Self.headingBorderWidth))
            .frame(width: Self.swatchColumnWidth, alignment: .trailing)

            Button("Reset", action: appearance.resetHeadingColors)
                .disabled(!appearance.hasCustomHeadingColor)
                .help("Reset all six to their default colours")
                .frame(width: 60)
        }
    }
}
