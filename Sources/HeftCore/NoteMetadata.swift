import Foundation

/// One key/value pair from a note's YAML frontmatter, in file order.
public struct NoteProperty: Equatable, Sendable, Identifiable {
    public let key: String
    public let value: PropertyValue
    public var id: String { key }

    public init(key: String, value: PropertyValue) {
        self.key = key
        self.value = value
    }
}

public enum PropertyValue: Equatable, Sendable {
    case text(String)
    case list([String])

    public var display: String {
        switch self {
        case .text(let value): value
        case .list(let values): values.joined(separator: ", ")
        }
    }

    public var items: [String] {
        switch self {
        case .text(let value): value.isEmpty ? [] : [value]
        case .list(let values): values
        }
    }
}

/// Reads the slice of YAML that Obsidian calls "properties".
///
/// A real YAML parser is deliberately not used. Obsidian's own property editor
/// only ever writes scalars, inline lists and block lists, and the alternative
/// is either a dependency or a parser that accepts anchors and multi-document
/// streams this app has no meaning for. Anything more exotic in a vault's
/// frontmatter is shown verbatim as text rather than being misread.
public enum Frontmatter {

    public static func parse(_ yaml: String) -> [NoteProperty] {
        var properties: [NoteProperty] = []
        let lines = yaml.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // Only top-level keys: an indented line belongs to the key above.
            guard line.first != " ", line.first != "\t",
                  let colon = trimmed.firstIndex(of: ":")
            else { continue }

            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rest = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if !rest.isEmpty {
                properties.append(NoteProperty(key: key, value: scalarOrInlineList(rest)))
                continue
            }

            // A bare `key:` introduces a block list, or nothing at all.
            var items: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("- ") || candidate == "-" else { break }
                items.append(unquoted(String(candidate.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                index += 1
            }
            properties.append(NoteProperty(
                key: key, value: items.isEmpty ? .text("") : .list(items)
            ))
        }
        return properties
    }

    private static func scalarOrInlineList(_ raw: String) -> PropertyValue {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return .text(unquoted(raw)) }
        let inner = String(raw.dropFirst().dropLast())
        let items = inner
            .split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return .list(items)
    }

    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let quotes: [Character] = ["\"", "'"]
        guard let first = raw.first, let last = raw.last,
              quotes.contains(first), first == last
        else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}

/// Tags, wherever a note declares them.
public enum NoteTags {

    /// Frontmatter tags plus inline `#tags`, deduplicated and in the order the
    /// note introduces them.
    ///
    /// Obsidian accepts both forms and treats them as one namespace, so a note
    /// found by `#project` must be found whether it wrote the tag in its
    /// frontmatter or in its prose.
    public static func all(in source: String) -> [String] {
        let split = NoteText.splitFrontmatter(source)
        var seen = Set<String>()
        var result: [String] = []

        func add(_ raw: String) {
            let tag = normalise(raw)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return }
            result.append(tag)
        }

        if let frontmatter = split.frontmatter {
            for property in Frontmatter.parse(frontmatter)
            where property.key.lowercased() == "tags" || property.key.lowercased() == "tag" {
                property.value.items.forEach(add)
            }
        }
        inline(in: split.body).forEach(add)
        return result
    }

    /// `#tag` occurrences in prose, skipping fenced code.
    public static func inline(in body: String) -> [String] {
        var result: [String] = []
        NoteText.forEachProseLine(body) { _, line in
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            // A tag needs a letter first, so `#1` (and a bare `#`) is not one,
            // and must not be preceded by a word character or `/`, so that
            // neither `a#b` nor a URL fragment is picked up.
            for match in tagPattern.matches(in: line, range: full) {
                result.append(ns.substring(with: match.range))
            }
        }
        return result
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/&])#[A-Za-z][\w/-]*"#
    )

    /// Strips a leading `#` and surrounding whitespace, so the frontmatter and
    /// inline spellings of the same tag compare equal.
    public static func normalise(_ raw: String) -> String {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag = String(tag.dropFirst()) }
        return tag
    }
}
