import Foundation

/// The colours the live surface draws with, kept in the vault so the Mac and
/// the phone draw a vault's notes alike.
///
/// In `.heft/appearance.json` beside the pins, and synced the same way, by
/// whatever syncs the vault. The Mac keeps its own copy as archived
/// `NSColor`s and writes this when it changes; the phone has only this. Each
/// colour is an sRGB hex string, and nil means the built-in default. Link
/// and tag fall back to the accent rather than to a fixed colour, as they do
/// on the Mac.
public struct AppearancePreferences: Codable, Equatable, Sendable {
    public var accent: String?
    public var link: String?
    public var tag: String?
    public var code: String?
    public var bold: String?
    public var italic: String?
    /// h1 through h6.
    public var headings: [String?] = Array(repeating: nil, count: 6)
    /// On by default, as on the Mac. Bold and italic; headings have their
    /// own `headingColor` since there was a choice of how they look.
    public var colorfulFormatting = true
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

    /// The defaults, and the defaults as they were before headings had their
    /// own setting: a Mac that kept the bar it always drew has chosen
    /// nothing either.
    static var untouched: [AppearancePreferences] {
        var before = AppearancePreferences()
        before.headingColor = .levelColors
        return [AppearancePreferences(), before]
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
