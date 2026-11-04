import Foundation

/// A property being typed in the frontmatter, and what completing it writes:
/// a key at the start of a line, or the value after `key: ` or on a list
/// item under it. Shaped like the other completion contexts, so the editor
/// offers the vault's keys and values through the same menu.
public struct PropertyCompletionContext: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case key
        /// A value of `key`; `siblings` are the items the list already holds.
        case value(key: String, siblings: [String])
    }

    public let part: Part
    public let query: String
    public let queryRange: NSRange

    /// What is being typed at `selection`, or nil. Only with nothing after
    /// the caret on its line, so completing never leaves a tail behind, and
    /// only between the fences.
    /// `emptyKey` lets a blank row count as a key with nothing typed yet,
    /// for the menu Add property opens straight away.
    public static func detect(in source: String, selection: NSRange, emptyKey: Bool = false) -> Self? {
        guard selection.length == 0, let block = PropertyEditing.blockRange(in: source) else { return nil }
        let text = source as NSString
        let caret = selection.location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let opening = text.lineRange(for: NSRange(location: 0, length: 0))
        let closing = text.lineRange(for: NSRange(location: NSMaxRange(block) - 1, length: 0))
        guard line.location >= NSMaxRange(opening), line.location < closing.location else { return nil }
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        guard caret == end else { return nil }

        let typed = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let indented = typed.first == " " || typed.first == "\t"
        let trimmed = typed.trimmingCharacters(in: .whitespaces)

        // A list item: `  - value`.
        if trimmed == "-" || trimmed.hasPrefix("- ") {
            guard let dash = typed.firstIndex(of: "-") else { return nil }
            var start = typed.index(after: dash)
            while start < typed.endIndex, typed[start] == " " { start = typed.index(after: start) }
            guard start > typed.index(after: dash) else { return nil }
            let query = String(typed[start...])
            guard let key = owningKey(above: line.location, in: text) else { return nil }
            return Self(
                part: .value(key: key, siblings: items(of: key, around: line.location, in: text)),
                query: query,
                queryRange: NSRange(location: caret - (query as NSString).length, length: (query as NSString).length)
            )
        }
        guard !indented, !trimmed.hasPrefix("#") else { return nil }

        if let colon = typed.firstIndex(of: ":") {
            let key = String(typed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            var rest = String(typed[typed.index(after: colon)...])
            // A list edited as pills takes its next item straight after the
            // colon; anything else wants the space YAML does.
            let isList = PropertyListContext.detect(in: source, selection: selection) != nil
            guard rest.first == " " || (isList && !rest.isEmpty) else { return nil }
            if rest.first == " " { rest.removeFirst() }
            var siblings: [String] = []
            if let list = PropertyListContext.detect(in: source, selection: selection) {
                siblings = list.items.map(\.value)
            }
            // Inside an inline list, the item after the last comma.
            if rest.hasPrefix("[") {
                let parts = rest.dropFirst().components(separatedBy: ",")
                siblings = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                rest = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
            } else {
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            let length = (rest as NSString).length
            return Self(
                part: .value(key: key, siblings: siblings), query: rest,
                queryRange: NSRange(location: caret - length, length: length)
            )
        }
        if trimmed.isEmpty, emptyKey {
            return Self(part: .key, query: "", queryRange: NSRange(location: caret, length: 0))
        }
        guard !trimmed.isEmpty, !typed.contains(" ") else { return nil }
        let length = (typed as NSString).length
        return Self(part: .key, query: typed, queryRange: NSRange(location: caret - length, length: length))
    }

    /// What the menu offers: keys the note does not have yet, or the key's
    /// values the list does not hold yet.
    public func suggestions(from catalog: PropertyCatalog, in source: String) -> [String] {
        switch part {
        case .key:
            let present = Set(PropertyEditing.keys(in: source).map { $0.lowercased() })
            return catalog.keys(matching: query, excluding: present)
        case let .value(key, siblings):
            return catalog.values(for: key, matching: query, excluding: Set(siblings.map { $0.lowercased() }))
        }
    }

    /// Writes the completion in place of what was typed: a key with its
    /// `: `, ready for the value; a value as YAML reads it back.
    public func accepting(_ completion: String) -> MarkdownEditing.Edit {
        let replacement: String
        switch part {
        case .key: replacement = completion + ": "
        case .value: replacement = PropertyEditing.scalar(completion, inList: isInlineList)
        }
        return MarkdownEditing.Edit(
            range: queryRange, replacement: replacement,
            selection: NSRange(location: queryRange.location + (replacement as NSString).length, length: 0)
        )
    }

    private var isInlineList: Bool {
        if case let .value(_, siblings) = part { return !siblings.isEmpty }
        return false
    }

    /// The key whose list a `- item` line belongs to: the nearest key line
    /// above it.
    private static func owningKey(above location: Int, in text: NSString) -> String? {
        var cursor = location
        while cursor > 0 {
            let line = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
            let string = text.substring(with: line)
            if string.first != " ", string.first != "\t", !string.hasPrefix("-"), !string.hasPrefix("#"),
               let colon = string.firstIndex(of: ":") {
                return String(string[..<colon]).trimmingCharacters(in: .whitespaces)
            }
            if string.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { return nil }
            cursor = line.location
        }
        return nil
    }

    /// The items already in the list around a `- item` line, that line's own
    /// excluded.
    private static func items(of key: String, around location: Int, in text: NSString) -> [String] {
        var result: [String] = []
        func item(_ line: NSRange) -> String? {
            let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        var cursor = location
        while cursor > 0 {
            let line = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
            guard let value = item(line) else { break }
            result.append(value)
            cursor = line.location
        }
        cursor = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
        while cursor < text.length {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            guard let value = item(line) else { break }
            result.append(value)
            cursor = NSMaxRange(line)
        }
        return result
    }
}
