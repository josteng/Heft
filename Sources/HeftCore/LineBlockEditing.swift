import Foundation

/// The phone's quote and indent buttons, over every line the selection
/// touches. Here rather than in the editor so a Windows note can be tested
/// without one: split on `\n`, each of its lines kept a `\r`, so a blank line
/// was not empty and took a `> ` or a tab it should have been left without.
extension MarkdownEditing {

    /// `> ` in front of every selected line, or off them all when every one
    /// already has it. Blank lines in a selection of several are left blank.
    public static func toggleQuote(in source: String, range selection: NSRange) -> Edit {
        let text = source as NSString
        let block = text.lineRange(for: selection)
        var (lines, trailing) = blockLines(text.substring(with: block))
        let quoted = lines.allSatisfy { $0.body.hasPrefix(">") || $0.body.isEmpty }
            && lines.contains { $0.body.hasPrefix(">") }
        var shift = 0
        for index in lines.indices where !(lines[index].body.isEmpty && lines.count > 1) {
            if quoted {
                let body = lines[index].body
                let drop = body.hasPrefix("> ") ? 2 : (body.hasPrefix(">") ? 1 : 0)
                lines[index].body.removeFirst(drop)
                if index == 0 { shift = -drop }
            } else {
                lines[index].body = "> " + lines[index].body
                if index == 0 { shift = 2 }
            }
        }
        return Edit(
            range: block, replacement: joined(lines, trailing: trailing),
            selection: NSRange(location: max(block.location, selection.location + shift),
                               length: selection.length)
        )
    }

    /// A tab more or less at the start of every selected line, which is how
    /// Obsidian nests a list item. A blank line takes its tab at the caret,
    /// so a list can be nested from the line Return just made.
    public static func shiftLines(in source: String, range selection: NSRange, outdent: Bool) -> Edit {
        let text = source as NSString
        let block = text.lineRange(for: selection)
        var (lines, trailing) = blockLines(text.substring(with: block))
        if !outdent, selection.length == 0, lines.count <= 1,
           (lines.first?.body ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(
                range: NSRange(location: selection.location, length: 0), replacement: "\t",
                selection: NSRange(location: selection.location + 1, length: 0)
            )
        }
        // The caret only moves by what was put in front of it on its line.
        var shift = 0
        for index in lines.indices {
            if outdent {
                let drop = lines[index].body.hasPrefix("\t") ? 1
                    : (lines[index].body.hasPrefix("  ") ? 2 : 0)
                lines[index].body.removeFirst(drop)
                if index == 0 { shift = -drop }
            } else if !lines[index].body.isEmpty {
                lines[index].body = "\t" + lines[index].body
                if index == 0 { shift = 1 }
            }
        }
        return Edit(
            range: block, replacement: joined(lines, trailing: trailing),
            selection: NSRange(location: max(block.location, selection.location + shift),
                               length: selection.length)
        )
    }

    /// A line's text, and the `\r` of a Windows break when it has one.
    private struct BlockLine {
        var body: String
        let ending: String
    }

    /// The lines of a block, and whether it ended in a break.
    private static func blockLines(_ block: String) -> ([BlockLine], Bool) {
        var parts = block.components(separatedBy: "\n")
        let trailing = parts.last == ""
        if trailing { parts.removeLast() }
        let lines = parts.map { part in
            part.hasSuffix("\r")
                ? BlockLine(body: String(part.dropLast()), ending: "\r")
                : BlockLine(body: part, ending: "")
        }
        return (lines, trailing)
    }

    private static func joined(_ lines: [BlockLine], trailing: Bool) -> String {
        var parts = lines.map { $0.body + $0.ending }
        if trailing { parts.append("") }
        return parts.joined(separator: "\n")
    }
}
