import Foundation

/// The Mac's replacements and pairing, kept in the vault so the iPhone and
/// iPad type with the same list: `.heft/typing.json`. Written by the Mac,
/// read by iOS, which has no editor for the list of its own.
public struct SharedTypingSetup: Codable, Equatable, Sendable {
    public var substitutions: Bool
    /// By name, so a group added later arrives switched on.
    public var disabledGroups: [String]
    public var custom: [CustomSubstitution]
    public var pairsBrackets: Bool
    public var pairsMarkdown: Bool

    public init(substitutions: Bool = true, disabledGroups: [String] = [], custom: [CustomSubstitution] = [],
                pairsBrackets: Bool = true, pairsMarkdown: Bool = true) {
        self.substitutions = substitutions
        self.disabledGroups = disabledGroups
        self.custom = custom
        self.pairsBrackets = pairsBrackets
        self.pairsMarkdown = pairsMarkdown
    }

    public var config: SmartTypographyConfig {
        SmartTypographyConfig(
            isEnabled: substitutions,
            enabledGroups: Set(SmartTypographyGroup.allCases.filter { !disabledGroups.contains($0.rawValue) }),
            custom: custom
        )
    }

    /// What the vault holds, when it is an edit made on another device to
    /// take in: neither this device's own setup nor what it last wrote.
    /// With nothing written yet there is no telling, and nil keeps this
    /// device's.
    public static func edit(inVault there: Self?, mine: Self, lastWritten: Self?) -> Self? {
        guard let there, there != mine, let lastWritten, there != lastWritten else { return nil }
        return there
    }

    public static func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".heft/typing.json")
    }

    /// The vault's setup, or nil before a Mac has written one.
    public static func read(from vaultRoot: URL) -> Self? {
        guard let data = try? Data(contentsOf: url(in: vaultRoot)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Written only when it differs from what is there, so opening a vault
    /// does not touch a file iCloud would then sync for nothing; and not
    /// at all for the defaults, which iOS assumes without a file, so a
    /// vault nobody changed the typing for gets no `.heft` folder.
    public func write(to vaultRoot: URL) throws {
        let existing = Self.read(from: vaultRoot)
        guard existing != self, existing != nil || self != Self() else { return }
        let url = Self.url(in: vaultRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
