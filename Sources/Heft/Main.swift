import AppKit
import HeftCore
import SwiftUI

/// Custom entry point rather than `@main` on the `App` type, so the binary can
/// also provide headless vault diagnostics without starting the windowed app.
@main
enum HeftMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "stats", arguments.count > 1 {
            runStats(vaultPath: arguments[1])
            return
        }
        // `daily <vault> [YYYY-MM-DD]` exercises template expansion and path
        // resolution without the GUI. Same code path the calendar uses.
        if arguments.first == "daily", arguments.count > 1 {
            let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            let settings = ObsidianSettings.load(vaultRoot: root)
            let daily = DailyNotes(vaultRoot: root, settings: settings)

            var date = Date()
            if arguments.count > 2 {
                let parser = DateFormatter()
                parser.dateFormat = "yyyy-MM-dd"
                parser.timeZone = .current
                date = parser.date(from: arguments[2]) ?? date
            }

            do {
                let existed = daily.exists(for: date)
                let url = try daily.ensureNote(for: date)
                print("path:    \(url.path)")
                print("existed: \(existed)")
                print("--- contents ---")
                print((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>")
                exit(0)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        // `render <vault> <note>` reports what the live surface would draw for
        // a note: which widgets, at what size, and how much height each line
        // reserves. Exists so the editor's rendering can be checked without
        // launching a window over whatever the user is doing.
        if arguments.first == "render", arguments.count > 2 {
            runRenderProbe(
                vaultPath: arguments[1], note: arguments[2],
                caret: arguments.count > 3 ? Int(arguments[3]) : nil
            )
            return
        }
        if arguments.first == "files", arguments.count > 1 {
            let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            for item in VaultScanner.scan(root: root).flattened() where !item.isFolder {
                print(item.relativePath)
            }
            exit(0)
        }
        HeftApp.main()
    }

    /// Read-only report over a vault. Exists so indexing and link resolution
    /// can be checked against a real vault without launching the editor, which
    /// autosaves and would risk writing to notes that matter.
    private static func runRenderProbe(vaultPath: String, note: String, caret: Int?) {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        guard let ref = index.notes.first(where: {
            $0.relativePath == note || $0.name == note
        }) else {
            print("no such note: \(note)")
            exit(1)
        }
        let source = (try? String(contentsOf: ref.url, encoding: .utf8)) ?? ""
        let context = RenderContext(index: index, current: ref, vaultRoot: root)

        let storage = NSTextStorage(string: source)
        // A caret offset reveals its line's block markup and whichever inline
        // span it lands in, the way clicking into it does.
        let reveal = caret.map {
            Reveal(
                selection: NSRange(location: min($0, storage.length), length: 0),
                in: source as NSString
            )
        } ?? .none
        let layout = LiveStyler.apply(to: storage, reveal: reveal, context: context)
        if let caret { print("caret \(caret) reveals line \(reveal.line)") }

        // Cost of one restyle. The editor does this on every caret move, so a
        // slow one is felt directly as click latency.
        var samples: [Double] = []
        for _ in 0..<12 {
            let probe = NSTextStorage(string: source)
            let start = Date()
            _ = LiveStyler.apply(to: probe, reveal: reveal, context: context)
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        samples.sort()
        print("chars \((source as NSString).length), restyle median \(fmt(CGFloat(samples[6])))ms, worst \(fmt(CGFloat(samples.last!)))ms")

        let text = source as NSString
        func line(at offset: Int) -> Int {
            var number = 1
            text.enumerateSubstrings(
                in: NSRange(location: 0, length: offset), options: [.byLines, .substringNotRequired]
            ) { _, _, _, _ in number += 1 }
            return number
        }

        print("decorations: \(LiveDecorator.decorations(in: source).count)")
        print("block widgets: \(layout.blocks.count)")
        for offset in layout.blocks.keys.sorted() {
            let described: String = switch layout.blocks[offset]! {
            case .list(let glyph, let markerOffset, _):
                "list \(glyph) marker offset \(markerOffset)"
            case .headingAccent(let level, _): "heading accent h\(level)"
            case .codeBlock(let edge, let language):
                "code block \(edge)\(language.map { " \($0)" } ?? "")"
            case .thematicBreak: "thematic break"
            case .blockMath(let image): "block math \(size(image.size))"
            case .image(let image): "image \(size(image.size))"
            case .table(let grid):
                "table \(size(grid.size)) rows \(grid.rowHeights.count) cols \(grid.columnWidths.count)"
                    + describeActiveCell(of: grid)
            case .properties(let card):
                "properties \(card.rows.count) rows \(size(card.size))"
            case .embed(let embed):
                "embed \"\(embed.title)\" \(size(embed.size))\(embed.isTruncated ? " truncated" : "")"
            case .quote(let quote, let indent, _):
                "\(quote.rawCallout.map { "callout \($0)" } ?? "quote") depth \(quote.depth) \(quote.edge) indent \(fmt(indent))"
            }
            // Reserved height is what the paragraph style actually gives the
            // line; if it is ~0 the widget has nowhere to draw.
            let style = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
            let reserved = (style as? NSParagraphStyle)?.minimumLineHeight ?? 0
            print("  line \(line(at: offset)): \(described), reserves \(fmt(reserved))pt")
        }

        reportFragmentGeometry(storage: storage, contentWidth: Theme.contentMaxWidth, line: line)

        print("inline math: \(layout.inlineMath.values.map(\.count).reduce(0, +))")
        for offset in layout.inlineMath.keys.sorted() {
            // The gap is bought with kerning on the formula's last character,
            // so the widest kern on the line is what was actually reserved.
            var widest: CGFloat = 0
            storage.enumerateAttribute(.kern, in: text.lineRange(for: NSRange(location: offset, length: 0))) {
                value, _, _ in widest = max(widest, (value as? CGFloat) ?? 0)
            }
            for item in layout.inlineMath[offset]! {
                print("  line \(line(at: offset)): \(size(item.image.size)), gap \(fmt(widest))pt")
            }
        }
        exit(0)
    }

    /// Lays the styled text out in a headless TextKit 2 stack and reports, per
    /// paragraph, the fragment's box against the text line inside it.
    ///
    /// Exists because "is `paragraphSpacing` part of the layout fragment or
    /// not" decides where a block widget may paint, and getting it wrong shows
    /// up only as a card overhanging the next paragraph — or as padding that
    /// looks even on one edge and not the other. Guessing it twice was enough.
    private static func reportFragmentGeometry(
        storage: NSTextStorage, contentWidth: CGFloat, line: (Int) -> Int
    ) {
        let content = NSTextContentStorage()
        content.textStorage?.setAttributedString(storage)
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        )
        manager.textContainer = container
        manager.ensureLayout(for: content.documentRange)

        print("fragment geometry (frame height / text height / lead / trail):")
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(
                from: content.documentRange.location, to: fragment.rangeInElement.location
            )
            let frame = fragment.layoutFragmentFrame
            guard let first = fragment.textLineFragments.first else { return true }
            let textHeight = fragment.textLineFragments
                .reduce(0) { $0 + $1.typographicBounds.height }
            // How much of the fragment sits above the first line of text, and
            // how much below the last: this is where paragraph spacing lands.
            let lead = first.typographicBounds.minY
            let trail = frame.height - textHeight - lead
            print("  line \(line(offset)): \(fmt(frame.height)) / \(fmt(textHeight)) / \(fmt(lead)) / \(fmt(trail))")
            return true
        }
    }

    /// Which cell of a drawn table the caret is in, and where the editor would
    /// paint the caret inside it. Reported here because it is the one part of
    /// the table surface that has no source of its own to inspect: the buffer
    /// still holds plain pipes whichever cell is active.
    private static func describeActiveCell(of grid: TableGrid) -> String {
        guard let active = grid.active,
              let cell = grid.cell(row: active.row, column: active.column)
        else { return "" }
        let caret = grid.caretRect(in: cell, offset: cell.text.length)
        return ", active cell r\(active.row)c\(active.column)"
            + " source \(cell.source) caret at \(fmt(caret.minX)),\(fmt(caret.minY))"
    }

    private static func size(_ s: CGSize) -> String { "\(fmt(s.width))x\(fmt(s.height))" }
    private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }

    private static func runStats(vaultPath: String) {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("No such folder: \(root.path)")
            exit(1)
        }

        let settings = ObsidianSettings.load(vaultRoot: root)
        let scanStart = Date()
        let tree = VaultScanner.scan(root: root)
        let scanTime = Date().timeIntervalSince(scanStart)

        let indexStart = Date()
        let index = VaultIndex.build(root: tree)
        let indexTime = Date().timeIntervalSince(indexStart)

        let files = tree.flattened().filter { !$0.isFolder }
        print("Vault: \(root.path)")
        print("  scan   \(String(format: "%.0f", scanTime * 1000)) ms")
        print("  index  \(String(format: "%.0f", indexTime * 1000)) ms")
        print("  \(index.notes.count) notes, \(files.count - index.notes.count) attachments")
        print("")
        print("Daily notes")
        print("  folder    \(settings.dailyNotesFolder.isEmpty ? "(vault root)" : settings.dailyNotesFolder)")
        print("  format    \(settings.dailyNoteFormat)")
        print("  template  \(settings.dailyNoteTemplate ?? "(none)")")
        let daily = DailyNotes(vaultRoot: root, settings: settings)
        print("  today ->  \(daily.relativePath(for: Date())) [\(daily.exists(for: Date()) ? "exists" : "would be created")]")
        print("  template resolves: \(daily.templateBody() != nil)")
        print("")

        var total = 0
        var unresolved: [String: Int] = [:]
        for note in index.notes {
            for link in index.outgoingLinks(from: note.relativePath) {
                total += 1
                if index.resolve(link, from: note) == nil, !link.target.isEmpty {
                    unresolved[link.target, default: 0] += 1
                }
            }
        }
        let resolved = total - unresolved.values.reduce(0, +)
        let percent = total == 0 ? 100.0 : Double(resolved) / Double(total) * 100
        print("Links")
        print("  \(total) wikilinks, \(resolved) resolved (\(String(format: "%.1f", percent))%)")

        if !unresolved.isEmpty {
            print("  \(unresolved.count) distinct unresolved targets, most referenced:")
            for (target, count) in unresolved.sorted(by: { $0.value > $1.value }).prefix(12) {
                print("    \(count)x  \(target)")
            }
        }

        let tags = index.allTags
        print("")
        print("Tags")
        print("  \(tags.count) distinct, most used:")
        for tag in tags.prefix(12) {
            print("    \(index.noteCount(forTag: tag))x  #\(tag)")
        }

        let mostLinked = index.notes
            .map { ($0.name, index.backlinks(to: $0.relativePath).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        print("")
        print("Most linked-to notes")
        for (name, count) in mostLinked.prefix(8) { print("  \(count)x  \(name)") }
        exit(0)
    }

}
