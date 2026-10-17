import Foundation

/// An inline style that is applied by wrapping text in a marker pair.
public enum InlineFormat: String, Sendable, CaseIterable {
    case bold = "**"
    case italic = "*"
    case strikethrough = "~~"
    case highlight = "=="
    case code = "`"

    public var marker: String { rawValue }

    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Code"
        }
    }

    /// SF Symbol for the formatting bar.
    public var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Text edits the formatting bar and its keyboard shortcuts perform.
///
/// Pure: takes source and a selection, returns new source and where the
/// selection should end up. Keeping it out of the text view is what makes the
/// toggling behaviour — which has more edge cases than it looks — testable
/// without a window.
public enum MarkdownEditing {

    /// The smallest replacement that performs a formatting change.
    ///
    /// A range and a replacement rather than the whole new document. Handing
    /// back the entire text made the caller replace every character of the
    /// file to bold one word, which relaid the whole document out — the view
    /// jumped — and put the file's entire contents on the undo stack as a
    /// single step.
    public struct Edit: Equatable, Sendable {
        /// Range in the *original* source to replace.
        public let range: NSRange
        public let replacement: String
        /// Where the selection belongs once the replacement is in.
        public let selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }

        /// True when there is nothing to do, so callers can bail cheaply.
        public var isEmpty: Bool { range.length == 0 && replacement.isEmpty }

        public func applied(to source: String) -> String {
            (source as NSString).replacingCharacters(in: range, with: replacement)
        }

        static func nothing(keeping selection: NSRange) -> Edit {
            Edit(range: NSRange(location: 0, length: 0), replacement: "", selection: selection)
        }
    }

    /// Adds `format` around the selection, or removes it when it is already
    /// there — checking both inside the selection and immediately around it,
    /// because whether the user selected the markers along with the words is
    /// an accident of how they dragged.
    public static func toggle(
        _ format: InlineFormat, in source: String, range: NSRange
    ) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }

        guard spansMultipleLines(in: source, range: range) else {
            // A whole bullet selected by a triple-click starts at its `- `.
            let start = contentStart(ofLineAt: range.location, in: text)
            let trimmed = range.location < start && NSMaxRange(range) > start
                ? NSRange(location: start, length: NSMaxRange(range) - start)
                : range
            return toggleSingle(format, in: text, range: trimmed)
        }

        // Backticks are deliberately line-local. Wrapping each selected line
        // as code would silently turn a paragraph selection into several
        // unrelated snippets; a fenced block is a different command entirely.
        guard format != .code else { return .nothing(keeping: range) }

        let ranges = nonWhitespaceLineSegments(in: text, selection: range)
        guard !ranges.isEmpty else { return .nothing(keeping: range) }

        // "Toggle" across a mixed selection behaves like a native style
        // command: add the style everywhere unless every selected line already
        // has it, in which case remove it everywhere.
        let removals = ranges.map { removal(of: format, in: text, range: $0) }
        let removeEverywhere = removals.allSatisfy { $0 != nil }
        var edits: [Edit] = []
        for (index, segment) in ranges.enumerated() {
            if removeEverywhere {
                if let edit = removals[index] { edits.append(edit) }
            } else if removals[index] == nil {
                edits.append(
                    merging(format, in: text, range: segment)
                        ?? wrapping(format, text.substring(with: segment), at: segment)
                )
            }
        }
        guard !edits.isEmpty else { return .nothing(keeping: range) }

        // NSTextView applies one replacement so the whole operation remains a
        // single undo step. Include the original selection in the union so its
        // line breaks and any already-formatted lines stay selected afterward.
        let start = min(range.location, edits.map(\.range.location).min() ?? range.location)
        let end = max(NSMaxRange(range), edits.map { NSMaxRange($0.range) }.max() ?? NSMaxRange(range))
        let union = NSRange(location: start, length: end - start)
        var replacement = text.substring(with: union)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(
                location: edit.range.location - union.location,
                length: edit.range.length
            )
            replacement = (replacement as NSString).replacingCharacters(
                in: local, with: edit.replacement
            )
        }
        return Edit(
            range: union,
            replacement: replacement,
            selection: NSRange(location: union.location, length: (replacement as NSString).length)
        )
    }

    /// What a paste should actually insert, given what is already on the line
    /// in front of the caret.
    ///
    /// Copying a bullet out of a note carries its `- ` with it, so pasting it
    /// at the end of a list item that is already `- ` writes `- - milk`.
    /// Every editor that has ever annoyed anybody about this does the same,
    /// and the fix is small: when the caret sits directly after a list marker
    /// and nothing else, the marker on the pasted text's first line is
    /// dropped, because the line already has one.
    ///
    /// Only the first line, and only when the line so far is nothing but a
    /// marker. Pasting into the middle of a sentence keeps every character:
    /// `see - milk` is text somebody wrote, not a list marker to be tidied
    /// away, and stripping one there would silently eat a dash.
    ///
    /// A pasted box replaces one already on the line rather than going away:
    /// dropping it wrote `- [ ] [ ] milk`, and dropping it instead unticked a
    /// finished task on the way in. So the result can reach back before the
    /// caret, by `replacingBeforeCaret` UTF-16 units.
    public static func pasted(
        _ text: String, afterLinePrefix prefix: String
    ) -> (text: String, replacingBeforeCaret: Int) {
        let unchanged = (text: text, replacingBeforeCaret: 0)
        guard !text.isEmpty else { return unchanged }
        let line = ListLine(prefix + "x")
        guard !line.marker.isEmpty, line.body == "x" else { return unchanged }

        let incoming = ListLine(firstLine(of: text))
        guard !incoming.marker.isEmpty, incoming.indent.isEmpty else { return unchanged }

        // The box comes through even though the marker does not: pasting a
        // task onto a bare bullet plainly means the task.
        let rest = String(text.dropFirst(incoming.marker.count))
        let replacing = line.hasCheckbox && incoming.hasCheckbox
            ? (line.checkbox as NSString).length
            : 0
        return (rest, replacing)
    }

    /// `[selected](url)` when a web address is pasted over a selection of
    /// words, as Obsidian does; nil when the paste should go in as it is.
    ///
    /// Only a single address with a scheme counts, and only over a selection
    /// on one line that is not itself an address: replacing one link with
    /// another is an ordinary paste.
    public static func linkPasting(_ pasted: String, over selected: String) -> String? {
        let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !selected.contains(where: \.isNewline),
              isWebAddress(address),
              !isWebAddress(selected.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return link(text: selected, to: address)
    }

    /// `[text](address)`. A `)` or `<` would end the destination early, so
    /// such an address goes in angle brackets, which keep it whole.
    public static func link(text: String, to address: String) -> String {
        let destination = address.contains(where: { "()<>".contains($0) }) ? "<\(address)>" : address
        return "[\(text)](\(destination))"
    }

    /// A scheme and a host, so `todo:fix` is text and not an address. An
    /// address with a space in it does not parse at all.
    static func isWebAddress(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "mailto" ? text.count > 7 : url.host?.isEmpty == false
    }

    private static func firstLine(of text: String) -> String {
        String(text.prefix { $0 != "\n" && $0 != "\r" })
    }

    /// Advances each selected line's checkbox one step.
    ///
    /// Obsidian's "Toggle checkbox status", and deliberately the same, since
    /// this is a vault somebody may also open there: a line with no box gains
    /// an unchecked one, an unchecked box becomes checked, and a checked box
    /// goes back to unchecked. Nothing ever removes a box, so the command is
    /// safe to hold down and the state is a cycle of two after the first
    /// press rather than a three-way toggle nobody can predict.
    ///
    /// Per line rather than per selection. A mixed selection would otherwise
    /// need a rule about what "all of them" means, and every such rule
    /// surprises somebody; advancing each line one step is what the reader
    /// can see happening.
    ///
    /// Indentation and the marker itself are left exactly as they are, so a
    /// nested list stays nested and `*` does not silently become `-`. A line
    /// that is not a list item gets a marker as well as a box, since asking
    /// for a checkbox on a paragraph plainly means "make this one".
    /// Genuinely empty lines are skipped, or a selection that happens to span
    /// a blank line grows a stray empty task.
    public static func toggleChecklist(in source: String, range: NSRange) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }

        let block = text.lineRange(for: range)
        var lines: [NSRange] = []
        var cursor = block.location
        while cursor < NSMaxRange(block) {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(line)
            cursor = NSMaxRange(line)
            if line.length == 0 { break }
        }

        let content = lines.filter {
            !text.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !content.isEmpty else { return startingTask(on: lines.first, at: range, in: text, spanning: lines.count) }

        let parsed = content.map { ListLine(text.substring(with: $0)) }

        // Where each line grew, and by how much, so the caret can be put back
        // where the reader left it rather than at the top of the block.
        //
        // Obsidian leaves it in the word being typed, and that is the whole
        // point of a keystroke for this: ticking something off must not cost
        // you your place in the sentence beside it.
        var growth: [(lineStart: Int, shiftPoint: Int, delta: Int)] = []
        var replacement = text.substring(with: block)
        for (line, item) in zip(content, parsed).reversed() {
            let rewritten = item.advancingCheckbox
            guard rewritten != item.raw else { continue }
            let local = NSRange(location: line.location - block.location, length: line.length)
            replacement = (replacement as NSString).replacingCharacters(in: local, with: rewritten)
            growth.append((
                lineStart: line.location,
                shiftPoint: line.location + item.checkboxInsertionOffset,
                delta: (rewritten as NSString).length - (item.raw as NSString).length
            ))
        }
        guard replacement != text.substring(with: block) else { return .nothing(keeping: range) }

        return Edit(
            range: block,
            replacement: replacement,
            selection: NSRange(
                location: shifted(range.location, by: growth),
                length: shifted(NSMaxRange(range), by: growth) - shifted(range.location, by: growth)
            )
        )
    }

    /// ⌘L on an empty line starts a task there, as Obsidian does, keeping
    /// any indentation so it nests where the caret was. Only for the one
    /// line the caret is on: blank lines inside a selection stay blank, or
    /// the gaps in a list grow stray empty tasks.
    private static func startingTask(
        on line: NSRange?, at range: NSRange, in text: NSString, spanning count: Int
    ) -> Edit {
        guard count <= 1 else { return .nothing(keeping: range) }
        // The empty last line of a note has no range of its own.
        let line = line ?? NSRange(location: range.location, length: 0)
        let raw = text.substring(with: line)
        let body = raw.trimmingCharacters(in: .newlines)
        let indent = body.prefix { $0 == " " || $0 == "\t" }
        let task = String(indent) + "- [ ] "
        let content = NSRange(location: line.location, length: (body as NSString).length)
        return Edit(
            range: content,
            replacement: task,
            selection: NSRange(location: line.location + (task as NSString).length, length: 0)
        )
    }

    public enum ListKind: Sendable {
        case bullet, numbered
    }

    /// Makes the selected lines a bullet or numbered list, or plain lines
    /// again when every one already is that kind, as Obsidian's two toggles do.
    ///
    /// A checkbox is kept on the way in and leaves with its marker on the way
    /// out, since a box with no marker in front of it is no task. Numbers
    /// count from one at each indent, restarting under a shallower item.
    public static func toggleList(_ kind: ListKind, in source: String, range: NSRange) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }

        let block = text.lineRange(for: range)
        var lines: [NSRange] = []
        var cursor = block.location
        while cursor < NSMaxRange(block) {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(line)
            cursor = NSMaxRange(line)
            if line.length == 0 { break }
        }
        let items = lines.map { line -> ListLine? in
            let raw = text.substring(with: line)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ListLine(raw)
        }
        guard items.contains(where: { $0 != nil }) else { return .nothing(keeping: range) }

        func isKind(_ item: ListLine) -> Bool {
            guard let first = item.marker.first else { return false }
            return kind == .bullet ? "-*+".contains(first) : first.isNumber
        }
        let removing = items.compactMap { $0 }.allSatisfy(isKind)

        // Where each line's marker and box sit, before and after, so the caret
        // can stay on the same words.
        var changes: [(start: Int, oldPrefix: Int, newPrefix: Int)] = []
        var counters: [String: Int] = [:]
        var replacement = ""
        for (line, item) in zip(lines, items) {
            guard let item else {
                replacement += text.substring(with: line)
                continue
            }
            let prefix: String
            if removing {
                prefix = ""
            } else if kind == .bullet {
                prefix = (isKind(item) ? item.marker : "- ") + item.checkbox
            } else {
                counters = counters.filter { $0.key.count <= item.indent.count }
                let number = counters[item.indent, default: 0] + 1
                counters[item.indent] = number
                prefix = "\(number). " + item.checkbox
            }
            replacement += item.indent + prefix + item.body
            changes.append((
                start: line.location + (item.indent as NSString).length,
                oldPrefix: ((item.marker + item.checkbox) as NSString).length,
                newPrefix: (prefix as NSString).length
            ))
        }
        guard replacement != text.substring(with: block) else { return .nothing(keeping: range) }

        func moved(_ position: Int) -> Int {
            var shift = 0
            for change in changes {
                if position >= change.start + change.oldPrefix {
                    shift += change.newPrefix - change.oldPrefix
                } else if position > change.start {
                    // Inside a marker that changed: just after the new one.
                    return change.start + shift + change.newPrefix
                } else {
                    break
                }
            }
            return position + shift
        }
        let start = moved(range.location)
        return Edit(
            range: block,
            replacement: replacement,
            selection: NSRange(location: start, length: max(0, moved(NSMaxRange(range)) - start))
        )
    }

    /// Where a character position ends up once the lines above it have grown.
    ///
    /// A position shifts by a line's growth only when it sits at or after the
    /// point that line actually changed, so a caret inside the bullet itself
    /// stays inside the bullet.
    private static func shifted(
        _ position: Int, by growth: [(lineStart: Int, shiftPoint: Int, delta: Int)]
    ) -> Int {
        growth.reduce(position) { moved, line in
            position >= line.shiftPoint ? moved + line.delta : moved
        }
    }

    /// One line of a list, split into the parts a checklist command moves.
    ///
    /// Written by hand rather than matched, because the indentation has to
    /// come back out byte for byte: rebuilding it from a count would turn a
    /// tab into spaces and shift a nested list under a parser that counts
    /// columns.
    struct ListLine: Equatable {
        let raw: String
        /// Whitespace and quote markers before the bullet.
        let indent: String
        /// `- `, `* `, `1. ` and so on, empty when the line is not a list item.
        let marker: String
        /// `[ ] ` or `[x] `, empty when there is none.
        let checkbox: String
        let body: String

        init(_ raw: String) {
            self.raw = raw
            var rest = Substring(raw)
            // The line break comes off and goes back on untouched: it is not
            // part of the item, and a rewrite that dropped it would join two
            // lines into one.
            var breakLength = 0
            while let last = rest.last, last == "\n" || last == "\r" {
                rest = rest.dropLast()
                breakLength += 1
            }
            let trailing = String(raw.suffix(breakLength))

            let indentEnd = rest.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
            indent = String(indentEnd)
            rest = rest.dropFirst(indentEnd.count)

            var marker = ""
            if let first = rest.first, "-*+".contains(first),
               rest.dropFirst().first == " " || rest.dropFirst().first == "\t" {
                marker = String(rest.prefix(1)) + " "
                rest = rest.dropFirst(2)
            } else {
                let digits = rest.prefix(while: \.isNumber)
                let after = rest.dropFirst(digits.count)
                if !digits.isEmpty, let delimiter = after.first, delimiter == "." || delimiter == ")",
                   after.dropFirst().first == " " {
                    marker = String(digits) + String(delimiter) + " "
                    rest = after.dropFirst(2)
                }
            }
            self.marker = marker

            if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                checkbox = String(rest.prefix(4))
                rest = rest.dropFirst(4)
            } else {
                checkbox = ""
            }
            body = String(rest) + trailing
        }

        var hasCheckbox: Bool { !checkbox.isEmpty }

        /// Where the box is written, as an offset into the line: after the
        /// indent and the marker when there is one, after the indent alone
        /// when the marker has to be made too.
        var checkboxInsertionOffset: Int {
            let indentLength = (indent as NSString).length
            guard !marker.isEmpty else { return indentLength }
            return indentLength + (marker as NSString).length
        }
        var isChecked: Bool { checkbox.hasPrefix("[x") || checkbox.hasPrefix("[X") }

        /// The next state: none becomes unchecked, unchecked becomes checked,
        /// checked becomes unchecked again.
        ///
        /// A line with no marker gains one on the way, because a checkbox
        /// without a bullet in front of it is not a task to any parser.
        var advancingCheckbox: String {
            let lead = indent + (marker.isEmpty ? "- " : marker)
            if !hasCheckbox { return lead + "[ ] " + body }
            return lead + (isChecked ? "[ ] " : "[x] ") + body
        }
    }

    /// Whether a selection contains a hard line boundary. Shared with the UI
    /// so it can disable formats that Markdown cannot represent across lines.
    public static func spansMultipleLines(in source: String, range: NSRange) -> Bool {
        let text = source as NSString
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= text.length else { return false }
        return text.rangeOfCharacter(from: .newlines, options: [], range: range).location != NSNotFound
    }

    private static func toggleSingle(
        _ format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit {
        if let edit = removal(of: format, in: text, range: range) { return edit }
        if let edit = splitting(format, in: text, range: range) { return edit }
        return merging(format, in: text, range: range)
            ?? wrapping(format, text.substring(with: range), at: range)
    }

    /// The spans of `format` on `range`'s line that it overlaps, from the
    /// decorator, so `*` and `_` italics and a highlight's colour emoji are
    /// read the way they are drawn. `***both***` is left out: its markers
    /// are two formats at once and not this one's to take apart.
    private static func spans(
        of format: InlineFormat, in text: NSString, overlapping range: NSRange
    ) -> [MarkdownDecoration] {
        guard format != .code else { return [] }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        return LiveDecorator.decorations(in: text.substring(with: line)).compactMap { decoration in
            let matches = switch (format, decoration.style) {
            case (.bold, .bold), (.italic, .italic), (.strikethrough, .strikethrough),
                 (.highlight, .highlight): true
            default: false
            }
            guard matches, decoration.syntax.count >= 2,
                  decoration.syntax.first?.length == (format.marker as NSString).length
            else { return nil }
            let shifted = MarkdownDecoration(
                range: NSRange(location: decoration.range.location + line.location, length: decoration.range.length),
                syntax: decoration.syntax.map { NSRange(location: $0.location + line.location, length: $0.length) },
                style: decoration.style
            )
            return NSIntersectionRange(shifted.range, range).length > 0 ? shifted : nil
        }
    }

    /// Takes `format` off part of one span: `**bold**` with `ol` selected
    /// becomes `**b**ol**d**`. Whitespace at a cut stays outside the markers,
    /// because `**a **` is not emphasis.
    private static func splitting(
        _ format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit? {
        let found = spans(of: format, in: text, overlapping: range)
        guard found.count == 1, let span = found.first, let closing = span.syntax.last else { return nil }
        let opening = span.syntax.dropLast()
        let contentStart = opening.map(NSMaxRange).max() ?? span.range.location
        guard range.location >= contentStart, NSMaxRange(range) <= closing.location else { return nil }

        let open = opening.map { text.substring(with: $0) }.joined()
        let close = text.substring(with: closing)
        var before = text.substring(with: NSRange(location: contentStart, length: range.location - contentStart))
        var after = text.substring(with: NSRange(location: NSMaxRange(range), length: closing.location - NSMaxRange(range)))
        var selected = text.substring(with: range)
        let trailing = before.reversed().prefix { $0 == " " || $0 == "\t" }
        before.removeLast(trailing.count)
        selected = String(trailing.reversed()) + selected
        let leading = after.prefix { $0 == " " || $0 == "\t" }
        after.removeFirst(leading.count)
        selected += leading

        let head = before.isEmpty ? "" : open + before + close
        let tail = after.isEmpty ? "" : open + after + close
        return Edit(
            range: span.range,
            replacement: head + selected + tail,
            selection: NSRange(
                location: span.range.location + (head as NSString).length
                    + (trailing.count > 0 ? (String(trailing) as NSString).length : 0),
                length: range.length
            )
        )
    }

    /// Formats a selection that already has the format in places as one
    /// span: `x **bold** y` becomes `**x bold y**` rather than
    /// `**x **bold** y**`, which reads as two spans with plain text between.
    /// A highlight keeps the first colour it absorbs.
    private static func merging(
        _ format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit? {
        let found = spans(of: format, in: text, overlapping: range)
        guard !found.isEmpty else { return nil }
        let union = found.reduce(range) { NSUnionRange($0, $1.range) }
        var body = text.substring(with: union)
        let markup = found.flatMap(\.syntax).sorted { $0.location > $1.location }
        for marker in markup {
            body = (body as NSString).replacingCharacters(
                in: NSRange(location: marker.location - union.location, length: marker.length), with: ""
            )
        }
        var open = format.marker
        if case .highlight(let color?) = found.min(by: { $0.range.location < $1.range.location })?.style {
            open += color.emoji
        }
        let openLength = (open as NSString).length
        return Edit(
            range: union,
            replacement: open + body + format.marker,
            selection: NSRange(location: union.location + openLength, length: (body as NSString).length)
        )
    }

    private static func wrapping(_ format: InlineFormat, _ body: String, at range: NSRange) -> Edit {
        let marker = format.marker
        let markerLength = (marker as NSString).length
        return Edit(
            range: range,
            replacement: marker + body + marker,
            selection: NSRange(location: range.location + markerLength, length: range.length)
        )
    }

    /// Returns the unwrapping edit when the selected text either includes its
    /// markers or has a matching pair immediately outside it.
    private static func removal(
        of format: InlineFormat, in text: NSString, range: NSRange
    ) -> Edit? {
        let marker = format.marker
        let markerLength = (marker as NSString).length

        // The selection carries the markers: `**bold**` selected whole.
        if range.length >= markerLength * 2 {
            let body = text.substring(with: range)
            if body.hasPrefix(marker), body.hasSuffix(marker) {
                let inner = String(body.dropFirst(marker.count).dropLast(marker.count))
                return Edit(
                    range: range,
                    replacement: inner,
                    selection: NSRange(
                        location: range.location, length: (inner as NSString).length
                    )
                )
            }
        }

        // The markers sit just outside it: `**bold**` with only `bold` selected.
        let before = NSRange(location: range.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(range), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker,
           text.substring(with: after) == marker {
            let outer = NSRange(
                location: before.location, length: range.length + markerLength * 2
            )
            return Edit(
                range: outer,
                replacement: text.substring(with: range),
                selection: NSRange(location: before.location, length: range.length)
            )
        }
        return nil
    }

    /// The nonempty piece of every selected line. Horizontal whitespace stays
    /// outside markers, because `** text **` is not valid emphasis Markdown.
    private static func nonWhitespaceLineSegments(
        in text: NSString, selection: NSRange
    ) -> [NSRange] {
        var result: [NSRange] = []
        let selectionEnd = NSMaxRange(selection)
        var segmentStart = selection.location

        while segmentStart <= selectionEnd {
            let remaining = NSRange(
                location: segmentStart, length: selectionEnd - segmentStart
            )
            let newline = text.rangeOfCharacter(from: .newlines, options: [], range: remaining)
            let segmentEnd = newline.location == NSNotFound ? selectionEnd : newline.location
            // Never before the line's own markup, or `- item` becomes
            // `**- item**`, which is no longer a list item.
            var lower = max(segmentStart, contentStart(ofLineAt: segmentStart, in: text))
            var upper = segmentEnd
            while lower < upper, isHorizontalWhitespace(text.character(at: lower)) { lower += 1 }
            while upper > lower, isHorizontalWhitespace(text.character(at: upper - 1)) { upper -= 1 }
            if upper > lower {
                result.append(NSRange(location: lower, length: upper - lower))
            }
            guard newline.location != NSNotFound else { break }
            segmentStart = NSMaxRange(newline)
        }
        return result
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    /// Where the words of the line holding `location` begin: after its
    /// indentation and quote markers, a list marker and checkbox, or a
    /// heading's hashes.
    static func contentStart(ofLineAt location: Int, in text: NSString) -> Int {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let parsed = ListLine(text.substring(with: line))
        var prefix = parsed.indent + parsed.marker + parsed.checkbox
        if parsed.marker.isEmpty, parsed.checkbox.isEmpty {
            let hashes = parsed.body.prefix { $0 == "#" }
            let next = parsed.body.dropFirst(hashes.count).first
            if (1...6).contains(hashes.count), next == " " || next == "\t", let next {
                prefix += String(hashes) + String(next)
            }
        }
        return line.location + (prefix as NSString).length
    }

    /// The line's markup before its words, from the line start up to
    /// `contentStart`: what a click on the line's hidden prefix is moved past.
    public static func markupPrefix(ofLineAt location: Int, in text: NSString) -> NSRange {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let start = contentStart(ofLineAt: location, in: text)
        return NSRange(location: line.location, length: start - line.location)
    }

    /// Where a click on the line's hidden prefix puts the caret.
    ///
    /// On a list line, the end of `- [ ]` without its space: a list marker
    /// reveals only while the caret touches it, so one past the space would
    /// leave it hidden with no way to click into it. A heading or quote
    /// reveals with its whole line, so there the caret goes to the words.
    public static func caretBesideMarkup(ofLineAt location: Int, in text: NSString) -> Int {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let parsed = ListLine(text.substring(with: line))
        guard !parsed.marker.isEmpty else { return contentStart(ofLineAt: location, in: text) }
        let markup = (parsed.marker + parsed.checkbox).trimmingCharacters(in: .whitespaces)
        return line.location + (parsed.indent as NSString).length + (markup as NSString).length
    }

    /// Wraps the selection in a link, putting the caret where the destination
    /// goes so it can be typed or pasted straight away.
    public static func makeLink(in source: String, range: NSRange) -> Edit {
        let text = source as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length
        else { return .nothing(keeping: range) }
        guard !spansMultipleLines(in: source, range: range) else {
            return .nothing(keeping: range)
        }

        let replacement = "[\(text.substring(with: range))]()"
        return Edit(
            range: range,
            replacement: replacement,
            // Just inside the parentheses, ready for a destination.
            selection: NSRange(
                location: range.location + (replacement as NSString).length - 1, length: 0
            )
        )
    }
}
