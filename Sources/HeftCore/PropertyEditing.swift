import Foundation

/// Where a note's frontmatter is, and how a value is written into it so YAML
/// reads it back as typed. The properties are edited in place, as text, on
/// the live surface; this is what that editing needs to know.
public enum PropertyEditing {

    /// From the opening fence to the end of the closing one, its line break
    /// included; nil when the note has no frontmatter, or it never closes.
    public static func blockRange(in source: String) -> NSRange? {
        let text = source as NSString
        func isFence(_ line: NSRange) -> Bool {
            text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }
        guard text.length > 0 else { return nil }
        let first = text.lineRange(for: NSRange(location: 0, length: 0))
        // As the surface draws one, or the caret and the tidying act on a
        // table nobody can see: the opening fence exactly `---`, and a line
        // before the closing one.
        guard ["---\n", "---\r\n"].contains(text.substring(with: first)) else { return nil }
        var location = NSMaxRange(first)
        if location < text.length, isFence(text.lineRange(for: NSRange(location: location, length: 0))) {
            return nil
        }
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            if isFence(line) { return NSRange(location: 0, length: NSMaxRange(line)) }
            location = NSMaxRange(line)
        }
        return nil
    }

    /// Where a note opens with the caret: past its frontmatter, so the
    /// properties show as the table they are drawn as, rather than the
    /// caret standing on the opening fence and showing it.
    public static func openingCaret(in source: String) -> Int {
        blockRange(in: source).map(NSMaxRange) ?? 0
    }

    /// One property as lines of the file: its key line and the list items
    /// or nested lines under it.
    public struct Row: Equatable, Sendable {
        /// Every line of it, line breaks included.
        public let range: NSRange
        /// The end of its first line's text, where the caret goes to edit
        /// its value.
        public let valueEnd: Int
    }

    /// The properties between the fences, in file order. A blank line is a
    /// row of its own, the one a new key is typed into.
    public static func rows(in source: String) -> [Row] {
        guard let block = blockRange(in: source) else { return [] }
        let text = source as NSString
        let opening = text.lineRange(for: NSRange(location: 0, length: 0))
        let closing = text.lineRange(for: NSRange(location: NSMaxRange(block) - 1, length: 0))
        var rows: [(start: Int, end: Int, valueEnd: Int)] = []
        var location = NSMaxRange(opening)
        while location < closing.location {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            while content.length > 0, [10, 13].contains(text.character(at: NSMaxRange(content) - 1)) {
                content.length -= 1
            }
            let string = text.substring(with: content)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            let continues = string.first == " " || string.first == "\t" || trimmed.hasPrefix("- ") || trimmed == "-"
            if continues, !rows.isEmpty {
                rows[rows.count - 1].end = NSMaxRange(line)
            } else {
                rows.append((line.location, NSMaxRange(line), NSMaxRange(content)))
            }
            location = NSMaxRange(line)
        }
        return rows.map { Row(range: NSRange(location: $0.start, length: $0.end - $0.start), valueEnd: $0.valueEnd) }
    }

    /// `key`'s value turned into a list, or out of one, when its type
    /// changes between the two: `key: v` becomes a one-item list, and a list
    /// becomes its items joined by commas. Nil when the value is already the
    /// shape asked for, or the key is not in the note.
    public static func converting(key: String, toList: Bool, in source: String) -> MarkdownEditing.Edit? {
        let text = source as NSString
        for row in rows(in: source) {
            let keyLine = NSRange(location: row.range.location, length: row.valueEnd - row.range.location)
            let line = text.substring(with: keyLine)
            guard let colon = line.firstIndex(of: ":"),
                  String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased()
            else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let newline = text.substring(with: row.range).contains("\r\n") ? "\r\n" : "\n"
            let itemsRange = NSRange(location: NSMaxRange(keyLine), length: NSMaxRange(row.range) - NSMaxRange(keyLine))
            let items = text.substring(with: itemsRange).components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let keyText = String(line[...colon])
            if toList {
                guard items.isEmpty, !value.isEmpty else { return nil }
                let listed: [String]
                if value.hasPrefix("[["), value.hasSuffix("]]") {
                    // A link, not a list in a list: one item, quoted as
                    // Obsidian writes a link in a list.
                    listed = [scalar(value)]
                } else if value.hasPrefix("["), value.hasSuffix("]") {
                    listed = flowItems(String(value.dropFirst().dropLast()))
                } else {
                    listed = [value]
                }
                let replacement = keyText + listed.map { newline + "  - " + $0 }.joined()
                return MarkdownEditing.Edit(
                    range: keyLine, replacement: replacement,
                    selection: NSRange(location: keyLine.location + (keyText as NSString).length, length: 0)
                )
            }
            guard !items.isEmpty else { return nil }
            // Each item's own quotes come off: they quoted the item, and
            // inside one value they would be read as its text.
            let joined = items.map(unquoted).joined(separator: ", ")
            let replacement = keyText + " " + scalar(joined) + newline
            return MarkdownEditing.Edit(
                range: row.range, replacement: replacement,
                selection: NSRange(location: row.range.location + (replacement as NSString).length - (newline as NSString).length, length: 0)
            )
        }
        return nil
    }

    /// An inline list's items as written, split at the commas outside
    /// quotes: `"Doe, Jane", Bob` is two items, not three.
    static func flowItems(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                items.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A quoted YAML scalar's text without its quotes; anything else as it is.
    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// The hidden `: ` between a property's key and its value, on the key
    /// line holding `location`: where the key's text ends and the value's
    /// begins. Nil off a key line, or on one with no colon yet.
    public static func colonGap(in source: String, at location: Int) -> (keyEnd: Int, valueStart: Int)? {
        let text = source as NSString
        guard let row = rows(in: source).first(where: {
            location >= $0.range.location && location <= $0.valueEnd
        }) else { return nil }
        let keyLine = NSRange(location: row.range.location, length: row.valueEnd - row.range.location)
        let colon = text.range(of: ":", options: [], range: keyLine)
        guard colon.location != NSNotFound else { return nil }
        var valueStart = NSMaxRange(colon)
        while valueStart < row.valueEnd, text.character(at: valueStart) == 32 { valueStart += 1 }
        return (colon.location, valueStart)
    }

    /// The note's keys, in file order.
    public static func keys(in source: String) -> [String] {
        NoteText.splitFrontmatter(source).frontmatter.map(Frontmatter.parse)?.map(\.key) ?? []
    }

    /// `value` as YAML reads it back unchanged: bare where it can be,
    /// quoted where YAML would read it as something else, a `[[link]]` as a
    /// list, `a: b` as a map, `#x` as a comment.
    public static func scalar(_ value: String, inList: Bool = false) -> String {
        let indicators = CharacterSet(charactersIn: "[]{}#&*!|>'\"%@`,")
        var needsQuotes = value.unicodeScalars.first.map(indicators.contains) ?? false
        // `- `, `? ` and `: ` open a list item, a key and a value.
        needsQuotes = needsQuotes || ["- ", "? ", ": "].contains { value.hasPrefix($0) } || value == "-"
        needsQuotes = needsQuotes || value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
        if inList { needsQuotes = needsQuotes || value.contains("]") }
        guard needsQuotes else { return value }
        // The reader takes the quotes off and unescapes nothing, so a value
        // holding a double quote is single-quoted instead.
        if value.contains("\"") && !value.contains("'") { return "'\(value)'" }
        return "\"\(value.replacingOccurrences(of: "\"", with: "'"))\""
    }
}

/// The keys the vault's notes use, and the values each has been given, for
/// completing them in the frontmatter: most used first.
public struct PropertyCatalog: Sendable, Equatable {
    /// Keys in their first-seen spelling, most used first.
    public let keys: [String]
    /// By lower-cased key: its values, most used first.
    let values: [String: [String]]

    public static let empty = PropertyCatalog(properties: [])

    public init(properties: [[NoteProperty]]) {
        var keyUses: [String: Int] = [:]
        var spelling: [String: String] = [:]
        var valueUses: [String: [String: Int]] = [:]
        var valueSpelling: [String: [String: String]] = [:]
        for note in properties {
            for property in note {
                let key = property.key.lowercased()
                keyUses[key, default: 0] += 1
                spelling[key] = spelling[key] ?? property.key
                for item in property.value.items {
                    let value = item.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { continue }
                    valueUses[key, default: [:]][value.lowercased(), default: 0] += 1
                    if valueSpelling[key]?[value.lowercased()] == nil {
                        valueSpelling[key, default: [:]][value.lowercased()] = value
                    }
                }
            }
        }
        func ranked(_ uses: [String: Int], _ spelled: [String: String]) -> [String] {
            uses.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { spelled[$0.key] ?? $0.key }
        }
        keys = ranked(keyUses, spelling)
        values = valueUses.reduce(into: [:]) { result, entry in
            result[entry.key] = ranked(entry.value, valueSpelling[entry.key] ?? [:])
        }
    }

    /// Keys starting with `typed`, then containing it, leaving out `excluding`
    /// (the note's other keys) and the typed key itself.
    public func keys(matching typed: String, excluding: Set<String> = [], limit: Int = 8) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = keys.filter {
            !excluding.contains($0.lowercased()) && $0.lowercased() != needle
        }
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        let prefixed = candidates.filter { $0.lowercased().hasPrefix(needle) }
        let inside = candidates.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        return Array((prefixed + inside).prefix(limit))
    }

    /// The values `key` has been given that match `typed`, the same way.
    public func values(for key: String, matching typed: String, excluding: Set<String> = [], limit: Int = 8) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = (values[key.lowercased()] ?? []).filter {
            !excluding.contains($0.lowercased()) && $0.lowercased() != needle
        }
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        let prefixed = candidates.filter { $0.lowercased().hasPrefix(needle) }
        let inside = candidates.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        return Array((prefixed + inside).prefix(limit))
    }
}

/// A frontmatter list being edited as pills, the way Obsidian edits one:
/// the caret on its key's line, after the pills, where a new item is typed.
/// Return writes the typed text as a new `- item` line under the others,
/// Backspace on nothing typed takes the last one away, and a pill's × its
/// own line. Every edit is one replacement, so each is one undo.
public struct PropertyListContext: Equatable, Sendable {
    public let key: String
    /// The key line's text, without its line break.
    public let keyLine: NSRange
    /// Where the typed item starts: after the colon and its spaces.
    public let pendingStart: Int
    /// What has been typed on the key line, the next item.
    public var pending: NSRange { NSRange(location: pendingStart, length: NSMaxRange(keyLine) - pendingStart) }
    /// Each item's line, without its line break, and its value.
    public let items: [(line: NSRange, value: String)]
    let indent: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.keyLine == rhs.keyLine && lhs.pendingStart == rhs.pendingStart
            && lhs.items.map(\.line) == rhs.items.map(\.line)
    }

    /// The list whose key line the caret is on, at its end; nil anywhere
    /// else. A key holding a block list, or `tags` and `aliases`, which are
    /// lists however few items they have yet.
    public static func detect(in source: String, selection: NSRange) -> Self? {
        guard selection.length == 0, let row = PropertyEditing.rows(in: source)
            .first(where: { NSLocationInRange(selection.location, $0.range) || selection.location == $0.valueEnd })
        else { return nil }
        let text = source as NSString
        guard selection.location == row.valueEnd else { return nil }
        let keyLine = NSRange(location: row.range.location, length: row.valueEnd - row.range.location)
        let line = text.substring(with: keyLine)
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var pendingStart = keyLine.location + (String(line[...colon]) as NSString).length
        while pendingStart < NSMaxRange(keyLine), text.character(at: pendingStart) == 32 { pendingStart += 1 }

        var items: [(NSRange, String)] = []
        var indent = "  "
        var location = NSMaxRange(text.lineRange(for: NSRange(location: keyLine.location, length: 0)))
        while location < NSMaxRange(row.range) {
            let full = text.lineRange(for: NSRange(location: location, length: 0))
            var content = full
            while content.length > 0, [10, 13].contains(text.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let string = text.substring(with: content)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { return nil }
            if items.isEmpty { indent = String(string.prefix { $0 == " " || $0 == "\t" }) }
            items.append((content, String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
            location = NSMaxRange(full)
        }
        let pendingText = text.substring(with: NSRange(location: pendingStart, length: NSMaxRange(keyLine) - pendingStart))
        // A value of its own, with no items under it, is a value, not a list.
        guard !items.isEmpty || ["tags", "tag", "aliases", "alias", "cssclasses"].contains(key.lowercased()),
              !pendingText.hasPrefix("[")
        else { return nil }
        return Self(key: key, keyLine: keyLine, pendingStart: pendingStart, items: items, indent: indent)
    }

    private func newline(in text: NSString) -> String {
        let line = text.lineRange(for: NSRange(location: keyLine.location, length: 0))
        return text.substring(with: line).hasSuffix("\r\n") ? "\r\n" : "\n"
    }

    /// `item` as the list's last line, the typed text gone from the key
    /// line, the caret back where the next one is typed.
    /// What typing `text` adds: for `tags`, its tags, split at spaces and
    /// without their `#`, as Obsidian's tag field takes them; for anything
    /// else, the text as one item.
    public func items(from text: String) -> [String] {
        ["tags", "tag"].contains(key.lowercased())
            ? PropertyRules.tags(from: text)
            : [text.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }
    }

    /// `item` as the list's last line, the typed text gone from the key
    /// line, the caret back where the next one is typed; tags split first.
    public func adding(_ item: String, in source: String) -> MarkdownEditing.Edit {
        adding(items: items(from: item), in: source)
    }

    /// Each of `added` as a line at the list's end, in order.
    public func adding(items added: [String], in source: String) -> MarkdownEditing.Edit {
        let text = source as NSString
        let colonEnd = keyLine.location + (text.substring(with: keyLine).firstIndex(of: ":").map {
            (String(text.substring(with: keyLine)[...$0]) as NSString).length
        } ?? keyLine.length)
        let end = items.last.map { NSMaxRange($0.line) } ?? NSMaxRange(keyLine)
        let between = NSRange(location: NSMaxRange(keyLine), length: end - NSMaxRange(keyLine))
        let lines = added.map { newline(in: text) + indent + "- " + PropertyEditing.scalar($0) }.joined()
        let replacement = text.substring(with: between) + lines
        return MarkdownEditing.Edit(
            range: NSRange(location: colonEnd, length: end - colonEnd),
            replacement: replacement,
            selection: NSRange(location: colonEnd, length: 0)
        )
    }

    /// The item at `index` gone, its line with it.
    public func removing(at index: Int, in source: String) -> MarkdownEditing.Edit? {
        guard items.indices.contains(index) else { return nil }
        let line = items[index].line
        let previousEnd = index == 0 ? NSMaxRange(keyLine) : NSMaxRange(items[index - 1].line)
        let range = NSRange(location: previousEnd, length: NSMaxRange(line) - previousEnd)
        return MarkdownEditing.Edit(
            range: range, replacement: "",
            selection: NSRange(location: NSMaxRange(keyLine), length: 0)
        )
    }
}

/// What Obsidian documents a property must be, checked: the fixes that keep
/// the block YAML at all, made when the caret leaves a row, and the
/// mismatches Obsidian only warns of, said on the row.
public enum PropertyRules {

    /// A row put right where the file would otherwise stop being YAML, or
    /// read as something else: a key gets its colon, a colon its space, a
    /// link its quotes (`[[Note]]` bare is a list in a list). Nil when the
    /// row is fine.
    public static func tidying(
        _ row: PropertyEditing.Row, in source: String, addingColon: Bool = true
    ) -> MarkdownEditing.Edit? {
        let text = source as NSString
        let original = text.substring(with: row.range)
        var lines = original.components(separatedBy: "\n")
        guard var head = lines.first else { return nil }
        let cr = head.hasSuffix("\r")
        if cr { head.removeLast() }
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, head.first != " ", head.first != "\t", !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-")
        else { return nil }

        // A quoted key's colon is the first after its closing quote: one
        // inside the quotes is the key's own text.
        var keyEnd = head.startIndex
        if let open = head.first, open == "\"" || open == "'" {
            guard let close = head.dropFirst().firstIndex(of: open) else { return nil }
            keyEnd = head.index(after: close)
        }
        var listValue = true
        if let colon = head[keyEnd...].firstIndex(of: ":") {
            let key = String(head[..<colon])
            let rest = String(head[head.index(after: colon)...])
            let value = rest.trimmingCharacters(in: .whitespaces)
            listValue = value.isEmpty
            let fixedValue = quotedLink(value)
            // An empty value is left as written; a value gets its space and
            // its quotes.
            if !value.isEmpty, rest.first != " " || fixedValue != value {
                head = key + ": " + fixedValue
            }
        } else {
            guard addingColon else { return nil }
            head += ":"
        }
        lines[0] = head + (cr ? "\r" : "")
        // Only a list's items are items: under `notes: |` or `>`, a line
        // starting `- ` is the block's literal text.
        for index in lines.indices.dropFirst() where listValue {
            let line = lines[index]
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(lead.count)
            guard rest.hasPrefix("- ") else { continue }
            let tail = rest.hasSuffix("\r")
            var item = String(rest.dropFirst(2))
            if tail { item.removeLast() }
            let quoted = quotedLink(item.trimmingCharacters(in: .whitespaces))
            if quoted != item.trimmingCharacters(in: .whitespaces) {
                lines[index] = lead + "- " + quoted + (tail ? "\r" : "")
            }
        }
        let fixed = lines.joined(separator: "\n")
        guard fixed != original else { return nil }
        return MarkdownEditing.Edit(range: row.range, replacement: fixed, selection: NSRange(location: row.range.location, length: 0))
    }

    /// A bare `[[link]]` quoted, as Obsidian asks; anything else as it is.
    static func quotedLink(_ value: String) -> String {
        guard value.hasPrefix("[["), value.hasSuffix("]]") else { return value }
        return PropertyEditing.scalar(value)
    }

    /// The items a typed tag stands for: split at spaces, its `#` dropped,
    /// as Obsidian's tag field does, where a space ends a tag.
    public static func tags(from typed: String) -> [String] {
        typed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            .map { String($0).drop { $0 == "#" } }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// What Obsidian would warn of on a row, in words, or nil: a value not
    /// of its key's type, a tag holding a space, a key Obsidian retired.
    public static func issue(key: String, value: String, items: [String], type: PropertyType?) -> String? {
        let retired = ["tag": "tags", "alias": "aliases", "cssclass": "cssclasses"]
        if let replacement = retired[key.lowercased()] {
            return "Obsidian reads \u{201C}\(replacement)\u{201D}, not \u{201C}\(key)\u{201D}, since version 1.9"
        }
        let value = value.trimmingCharacters(in: .whitespaces)
        if key.lowercased() == "tags" || type == .tags {
            let all = items + (value.isEmpty ? [] : [value])
            if all.contains(where: { $0.contains(" ") }) { return "A tag can\u{2019}t hold a space" }
            return nil
        }
        guard !value.isEmpty, let type else { return nil }
        let unquoted = value.count >= 2 && (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'"))
            ? String(value.dropFirst().dropLast()) : value
        switch type {
        case .number:
            return Double(unquoted) == nil ? "\u{201C}\(key)\u{201D} is a number, and this isn\u{2019}t one" : nil
        case .checkbox:
            return ["true", "false"].contains(unquoted.lowercased()) ? nil : "\u{201C}\(key)\u{201D} is a checkbox: true or false"
        case .date:
            return unquoted.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
                ? "\u{201C}\(key)\u{201D} is a date, written YYYY-MM-DD" : nil
        case .datetime:
            return unquoted.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$"#, options: .regularExpression) == nil
                ? "\u{201C}\(key)\u{201D} is a date and time, written YYYY-MM-DDTHH:MM:SS" : nil
        default:
            return nil
        }
    }
}
