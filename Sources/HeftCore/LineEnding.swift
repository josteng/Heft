import Foundation

/// The line break a note is written with, so that a break Heft adds is the
/// note's own.
///
/// The buffer is the file, so a note keeps whatever breaks it came with; but
/// a Return typed into a Windows note used to add a bare `\n`, and the note
/// ended up mixed. Obsidian never mixes because CodeMirror turns every break
/// into `\n` and the save rewrites the whole file, which is the rewrite Heft
/// does not do. VS Code's rule is the one that fits: keep the file's ending
/// and type that one.
public enum LineEnding: String, Sendable {
    case lf = "\n"
    case crlf = "\r\n"

    /// CRLF when more than half of the note's breaks are, which is VS Code's
    /// rule: a mostly Windows note with a few stray `\n` lines stays Windows,
    /// and a pasted CRLF line does not turn a Unix note. A note with no break
    /// at all, or a new one, is LF. A lone `\r` counts as neither.
    public init(of text: String) {
        var crlf = 0
        var lf = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 10 {
                if previous == 13 { crlf += 1 } else { lf += 1 }
            }
            previous = unit
        }
        self = crlf > lf ? .crlf : .lf
    }

    /// `text` with every break in it, `\r\n`, `\n` or a lone `\r`, written as
    /// this ending.
    public func applied(to text: String) -> String {
        adapting(text).text
    }

    /// Whether `text` has a break that is not this ending, the cheap check a
    /// keystroke makes before anything is rewritten.
    public func differs(in text: String) -> Bool {
        var previous: UInt16 = 0
        for unit in text.utf16 {
            switch self {
            case .lf: if unit == 13 { return true }
            case .crlf:
                if unit == 10, previous != 13 { return true }
                if previous == 13, unit != 10 { return true }
            }
            previous = unit
        }
        return self == .crlf && previous == 13
    }

    /// The text rewritten, and for every UTF-16 offset into the original,
    /// where it lands in the rewrite. An offset between a `\r` and its `\n`
    /// lands after the break, since the break is one character.
    func adapting(_ text: String) -> (text: String, offsets: [Int]) {
        let units = Array(text.utf16)
        let ending = Array(rawValue.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var offsets = [Int](repeating: 0, count: units.count + 1)
        var index = 0
        while index < units.count {
            let unit = units[index]
            offsets[index] = output.count
            if unit == 13 || unit == 10 {
                let pair = unit == 13 && index + 1 < units.count && units[index + 1] == 10
                output.append(contentsOf: ending)
                if pair {
                    offsets[index + 1] = output.count
                    index += 2
                } else {
                    index += 1
                }
            } else {
                output.append(unit)
                index += 1
            }
        }
        offsets[units.count] = output.count
        return (String(decoding: output, as: UTF16.self), offsets)
    }

    /// Edits whose replacements are written in this ending, and the
    /// selections that describe the text after them moved to match.
    ///
    /// Only the inserted text changes: the note's own lines, mixed or not,
    /// are left as they are. Ranges are in the original text and must not
    /// overlap; selections are in the text after every edit, as the edit
    /// planners hand them back.
    public func adapting(
        _ edits: [(range: NSRange, replacement: String)], selections: [NSRange]
    ) -> (edits: [(range: NSRange, replacement: String)], selections: [NSRange]) {
        guard edits.contains(where: { differs(in: $0.replacement) }) else {
            return (edits, selections)
        }
        // Where each edit's replacement lands in the text after the edits,
        // before and after rewriting, walking them in document order.
        struct Span { var oldStart: Int; var oldLength: Int; var newStart: Int; var offsets: [Int] }
        let order = edits.indices.sorted { edits[$0].range.location < edits[$1].range.location }
        var adapted = edits
        var spans: [Span] = []
        var oldShift = 0
        var newShift = 0
        for index in order {
            let edit = edits[index]
            let rewritten = adapting(edit.replacement)
            adapted[index].replacement = rewritten.text
            let oldLength = (edit.replacement as NSString).length
            spans.append(Span(
                oldStart: edit.range.location + oldShift, oldLength: oldLength,
                newStart: edit.range.location + newShift, offsets: rewritten.offsets
            ))
            oldShift += oldLength - edit.range.length
            newShift += (rewritten.text as NSString).length - edit.range.length
        }
        func moved(_ position: Int) -> Int {
            var shift = 0
            for span in spans {
                if position < span.oldStart { break }
                if position <= span.oldStart + span.oldLength {
                    return span.newStart + span.offsets[position - span.oldStart]
                }
                shift = (span.newStart + span.offsets[span.oldLength]) - (span.oldStart + span.oldLength)
            }
            return position + shift
        }
        let selections = selections.map { selection -> NSRange in
            let start = moved(selection.location)
            let end = moved(NSMaxRange(selection))
            return NSRange(location: start, length: max(0, end - start))
        }
        return (adapted, selections)
    }
}

extension MarkdownEditing.Edit {
    /// This edit with its replacement in `ending`, its selection moved to match.
    public func adapted(to ending: LineEnding) -> MarkdownEditing.Edit {
        let result = ending.adapting([(range, replacement)], selections: [selection])
        return MarkdownEditing.Edit(
            range: range, replacement: result.edits[0].replacement, selection: result.selections[0]
        )
    }
}

extension TableEditing.Action {
    /// This action with its replacement in `ending`, its selection moved to match.
    public func adapted(to ending: LineEnding) -> TableEditing.Action {
        guard let replace else { return self }
        let result = ending.adapting([(replace, replacement)], selections: [selection])
        return TableEditing.Action(
            replace: replace, replacement: result.edits[0].replacement, selection: result.selections[0]
        )
    }
}
