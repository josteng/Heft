import Foundation

/// The type Obsidian gives a property, vault-wide, in `.obsidian/types.json`:
/// what the icon before a key shows and what its value is edited as.
public enum PropertyType: String, CaseIterable, Sendable {
    case text, multitext, number, checkbox, date, datetime, tags, aliases

    /// What the type picker calls it.
    public var title: String {
        switch self {
        case .text: "Text"
        case .multitext: "List"
        case .number: "Number"
        case .checkbox: "Checkbox"
        case .date: "Date"
        case .datetime: "Date & time"
        case .tags: "Tags"
        case .aliases: "Aliases"
        }
    }

    /// The SF Symbol for its icon.
    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .multitext: "list.bullet"
        case .number: "number"
        case .checkbox: "checkmark.square"
        case .date: "calendar"
        case .datetime: "clock"
        case .tags: "tag"
        case .aliases: "arrow.turn.up.right"
        }
    }

    /// What the picker offers: tags and aliases are Obsidian's own keys,
    /// not types to give another.
    public static let pickable: [PropertyType] = [.text, .multitext, .number, .checkbox, .date, .datetime]

    /// Whether the value is written as a list.
    public var isList: Bool { self == .multitext || self == .tags || self == .aliases }
}

/// Reading and writing `.obsidian/types.json`, which Heft shares with Obsidian
/// so a type picked in either shows in both.
public enum PropertyTypes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: Date, types: [String: PropertyType])] = [:]
    nonisolated(unsafe) private static var generationValue = 0

    /// Moves whenever a read finds the file changed, so a restyle keyed on
    /// it redraws the icons.
    public static var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    public static func file(in vault: URL) -> URL {
        vault.appendingPathComponent(".obsidian/types.json")
    }

    /// The vault's property types, by key as written. Read again only when
    /// the file's date moves, since a restyle asks on every pass.
    public static func types(in vault: URL?) -> [String: PropertyType] {
        guard let vault else { return [:] }
        let url = file(in: vault)
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
        lock.lock()
        if let hit = cache[url.path], hit.stamp == stamp {
            lock.unlock()
            return hit.types
        }
        lock.unlock()
        let types = (try? Data(contentsOf: url)).map(parse) ?? [:]
        lock.lock()
        cache[url.path] = (stamp, types)
        generationValue += 1
        lock.unlock()
        return types
    }

    /// The type of `key`, as written or in any case.
    public static func type(of key: String, in types: [String: PropertyType]) -> PropertyType? {
        types[key] ?? types.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    static func parse(_ data: Data) -> [String: PropertyType] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let types = object["types"] as? [String: String]
        else { return [:] }
        return types.compactMapValues(PropertyType.init(rawValue:))
    }

    /// `source` with `key` given `type`: its entry's value replaced where it
    /// has one, otherwise a line added at the top of `types`, so every other
    /// entry keeps its place and Obsidian's own formatting.
    public static func setting(_ type: PropertyType, for key: String, in source: String?) -> String {
        let quotedKey = jsonString(key)
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "{\n  \"types\": {\n    \(quotedKey): \"\(type.rawValue)\"\n  }\n}"
        }
        let escaped = NSRegularExpression.escapedPattern(for: quotedKey)
        if let entry = try? NSRegularExpression(pattern: escaped + #"\s*:\s*"[^"]*""#),
           let match = entry.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
            return (source as NSString).replacingCharacters(in: match.range, with: "\(quotedKey): \"\(type.rawValue)\"")
        }
        if let opening = source.range(of: #""types"\s*:\s*\{"#, options: .regularExpression) {
            let rest = source[opening.upperBound...]
            let isEmpty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            let line = "\n    \(quotedKey): \"\(type.rawValue)\"" + (isEmpty ? "\n  " : ",")
            var result = source
            result.insert(contentsOf: line, at: opening.upperBound)
            return result
        }
        // No `types` object at all: added as the first member.
        guard let brace = source.firstIndex(of: "{") else { return source }
        var result = source
        let hasMembers = source[source.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines).first != "}"
        result.insert(contentsOf: "\n  \"types\": {\n    \(quotedKey): \"\(type.rawValue)\"\n  }" + (hasMembers ? "," : "\n"),
                      at: source.index(after: brace))
        return result
    }

    /// Gives `key` `type` in the vault's file, creating it if need be.
    public static func set(_ type: PropertyType, for key: String, in vault: URL) throws {
        let url = file(in: vault)
        let source = try? String(contentsOf: url, encoding: .utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setting(type, for: key, in: source).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func jsonString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\(string)\"]"
        return String(array.dropFirst().dropLast())
    }
}
