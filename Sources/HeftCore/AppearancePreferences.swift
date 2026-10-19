import Foundation

/// The colours the live surface draws with, kept in the vault so the Mac and
/// the phone draw a vault's notes alike.
///
/// In `.heft/appearance.json` beside the pins, and synced the same way, by
/// whatever syncs the vault. The Mac keeps its own copy and writes this when
/// it changes; the phone has only this. Each colour is a `ColorChoice`: nil
/// for the built-in default, a swatch's name, which the palette resolves, or
/// an sRGB hex string, shown exactly. Link and tag fall back to the accent
/// rather than to a fixed colour, as they do on the Mac.
public struct AppearancePreferences: Codable, Equatable, Sendable {
    public var accent: String?
    public var link: String?
    public var tag: String?
    public var code: String?
    public var bold: String?
    public var italic: String?
    /// h1 through h6.
    public var headings: [String?] = Array(repeating: nil, count: 6)
    /// Bold and italic in their own colours. Off for a vault set up now; on
    /// in a file from before, which never said. Headings have their own
    /// `headingColor`.
    public var colorfulFormatting = false
    /// How the built-in colours and the swatches are drawn. Muted for a
    /// vault set up now; vivid, as they always were, in a file from before.
    public var palette: ColorPalette = .muted
    public var headingFont: HeadingFont = .system
    /// None for a vault set up now; an older file is read as it looked,
    /// see `init(from:)`.
    public var headingColor: HeadingColor = .none

    /// The face headings are set in. Body text stays the system font.
    public enum HeadingFont: String, Codable, CaseIterable, Sendable, Identifiable {
        case system
        /// Apple's serif, shipped with every Mac, iPhone and iPad.
        case newYork
        public var id: Self { self }
        public var title: String { self == .system ? "System" : "New York" }
    }

    /// Today's colours, or the same hues softened.
    public enum ColorPalette: String, Codable, CaseIterable, Sendable, Identifiable {
        case vivid, muted
        public var id: Self { self }
        public var title: String { self == .vivid ? "Vivid" : "Muted" }
    }

    /// A colour picked from the row rather than with Custom: stored by name,
    /// so the palette decides how it looks, in light and dark alike.
    public enum Swatch: String, Codable, CaseIterable, Sendable, Identifiable {
        case red, orange, yellow, green, teal, blue, purple, graphite
        public var id: Self { self }
        public var title: String { rawValue.capitalized }
    }

    /// What a stored colour string means.
    public enum ColorChoice: Equatable, Sendable {
        case swatch(Swatch)
        /// Exactly this sRGB colour, which no palette changes.
        case custom(String)

        public init?(stored: String?) {
            guard let stored else { return nil }
            if let swatch = Swatch(rawValue: stored) {
                self = .swatch(swatch)
            } else if HexColor.components(stored) != nil {
                self = .custom(stored)
            } else {
                return nil
            }
        }

        public var stored: String {
            switch self {
            case .swatch(let swatch): swatch.rawValue
            case .custom(let hex): hex
            }
        }
    }

    /// What marks a heading besides its size and weight.
    public enum HeadingColor: String, Codable, CaseIterable, Sendable, Identifiable {
        case none
        /// A bar in the level's colour beside the heading, as Obsidian draws.
        case levelColors
        public var id: Self { self }
        public var title: String { self == .none ? "None" : "Level Colors" }
    }

    public init() {}

    public static func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".heft", isDirectory: true)
            .appendingPathComponent("appearance.json")
    }

    /// Nil when the vault has no file, which is different from a file of
    /// defaults: with none, the Mac's own choice stands.
    public static func load(fromVault vaultRoot: URL) -> AppearancePreferences? {
        guard let data = try? Data(contentsOf: url(in: vaultRoot)) else { return nil }
        return try? JSONDecoder().decode(AppearancePreferences.self, from: data)
    }

    /// Whole and atomic, as the pins are.
    public func save(toVault vaultRoot: URL) throws {
        let file = Self.url(in: vaultRoot)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// Every key optional when reading, so a file written by an older or
    /// newer build still opens with what it does say.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decodeIfPresent(String.self, forKey: .accent)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        bold = try container.decodeIfPresent(String.self, forKey: .bold)
        italic = try container.decodeIfPresent(String.self, forKey: .italic)
        let stored = try container.decodeIfPresent([String?].self, forKey: .headings) ?? []
        headings = (0..<6).map { $0 < stored.count ? stored[$0] : nil }
        colorfulFormatting = try container.decodeIfPresent(Bool.self, forKey: .colorfulFormatting) ?? true
        palette = try container.decodeIfPresent(ColorPalette.self, forKey: .palette) ?? .vivid
        headingFont = try container.decodeIfPresent(HeadingFont.self, forKey: .headingFont) ?? .system
        // A file from before headings had their own setting drew the bar
        // with colourful formatting, so it keeps looking that way.
        headingColor = try container.decodeIfPresent(HeadingColor.self, forKey: .headingColor)
            ?? (colorfulFormatting ? .levelColors : .none)
    }
}

extension AppearancePreferences {
    public enum SyncStep: Equatable, Sendable {
        case nothing
        /// Write this device's colours to the vault.
        case write
        /// Take the vault's colours.
        case adopt(AppearancePreferences)
    }

    /// What a device does on reading a vault's file, given its own colours.
    ///
    /// The file wins whenever there is one, since it is the last choice made
    /// on any device. With none, a device that has customised its colours
    /// writes them; one still on the defaults writes nothing, so a folder
    /// opened with the defaults is not given a `.heft` it never asked for.
    public static func step(stored: AppearancePreferences?, current: AppearancePreferences) -> SyncStep {
        guard let stored else { return untouched.contains(current) ? .nothing : .write }
        return stored == current ? .nothing : .adopt(stored)
    }

    /// The defaults, and the defaults as they were before headings and the
    /// palette had settings: a Mac that kept the look it always had has
    /// chosen nothing either.
    static var untouched: [AppearancePreferences] {
        [AppearancePreferences(), legacy]
    }

    /// What a file from before these settings means: colourful formatting
    /// on, the heading bar, vivid colours.
    public static var legacy: AppearancePreferences {
        var before = AppearancePreferences()
        before.colorfulFormatting = true
        before.headingColor = .levelColors
        before.palette = .vivid
        return before
    }
}

/// `#RRGGBB`, or `#RRGGBBAA` when not opaque, in sRGB.
public enum HexColor {
    public static func format(red: Double, green: Double, blue: Double, alpha: Double = 1) -> String {
        func byte(_ value: Double) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt32) -> Double { Double((full >> shift) & 0xFF) / 255 }
        return (channel(24), channel(16), channel(8), channel(0))
    }
}
