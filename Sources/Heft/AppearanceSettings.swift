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

    /// How consecutive source lines are read, overriding what the vault says.
    ///
    /// Here rather than in General because it is about how a note reads on the
    /// page. Defaults to following the vault, so an upgrade cannot change how
    /// anybody's notes look; the point of the setting is the folder of plain
    /// Markdown that has no `.obsidian` to ask.
    @Published var lineBreaks: LineBreakStyle {
        didSet { HeftDefaults.shared.set(lineBreaks.rawValue, forKey: Self.lineBreaksKey) }
    }

    /// Whether a folder row draws a chevron.
    ///
    /// Off by default: the folder icon already fills when the row is open, so
    /// the arrow is a second way of saying the same thing, in a column of its
    /// own down the right-hand edge of the tree. Chrome, which is why it is
    /// here and not in General.
    @Published var showsFolderArrows: Bool {
        didSet { HeftDefaults.shared.set(showsFolderArrows, forKey: Self.folderArrowsKey) }
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

    private static let lineBreaksKey = "dev.stenglein.Heft.appearance.lineBreaks"
    private static let folderArrowsKey = "dev.stenglein.Heft.appearance.folderArrows"
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
        lineBreaks = HeftDefaults.shared.string(forKey: Self.lineBreaksKey)
            .flatMap(LineBreakStyle.init(rawValue:)) ?? .followTheVault
        showsFolderArrows = HeftDefaults.shared.bool(forKey: Self.folderArrowsKey)
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

/// Whether the file tree draws a chevron beside a folder.
///
/// Through the environment rather than read from the shared settings in each
/// row. A sidebar row is one of hundreds, `AppModel` publishes on every
/// keystroke, and an `@ObservedObject` in a row would open a Combine
/// subscription per row per keystroke to answer a question the whole tree
/// shares. Reading the environment costs nothing and the modifier below
/// observes once, at the scene root.
private struct FolderArrowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsFolderArrows: Bool {
        get { self[FolderArrowsKey.self] }
        set { self[FolderArrowsKey.self] = newValue }
    }
}

private struct AppAccent: ViewModifier {
    @ObservedObject private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        let accent = Color(nsColor: appearance.accentColor)
        return content
            .tint(accent)
            .environment(\.appAccent, accent)
            .environment(\.showsFolderArrows, appearance.showsFolderArrows)
    }
}

extension View {
    /// Tints this scene with the user's accent colour. Belongs at a scene
    /// root; anywhere deeper and the views above it keep the system accent.
    func appAccentTint() -> some View { modifier(AppAccent()) }
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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker(selection: $appearance.lineBreaks) {
                    ForEach(LineBreakStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Consecutive Lines").font(.headline)
                }
                .pickerStyle(.radioGroup)
                Text(lineBreakExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $appearance.showsFolderArrows) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder Arrows in the Sidebar").font(.headline)
                    Text("Adds a chevron beside each folder in the file tree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(20)
        .frame(width: 630, alignment: .leading)
    }

    /// Read in `body`, never copied in `onAppear`: the Settings window
    /// measures each pane off screen, where `onAppear` never fires.
    private var lineBreakExplanation: String {
        switch appearance.lineBreaks {
        case .followTheVault:
            "Whatever this vault's own `strictLineBreaks` says, and a line each "
                + "when it says nothing, which is Obsidian's default."
        case .aLineEach:
            "A single newline is a line break. What Obsidian does."
        case .oneParagraph:
            "A single newline is a space, so two lines are one paragraph. What "
                + "CommonMark says. The editing surface still shows each line "
                + "where it is in the file; this is how a note reads once rendered."
        }
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
