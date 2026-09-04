import AppKit
import HeftCore
import SwiftUI

/// Custom entry point rather than `@main` on the `App` type, so the binary can
/// also provide headless vault diagnostics without starting the windowed app.
@main
enum HeftMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // Discovery first, so `heft` alone and `heft help` both answer.
        // Everything printed here comes from `CommandLineSpec`, which is also
        // what the shell wrapper is generated from.
        if CommandLineSpec.wantsHelp(arguments) {
            if arguments.contains("--json") {
                print(CommandLineSpec.helpJSON())
            } else if arguments.contains("--verbs") {
                // What `install.sh` reads to build the wrapper's verb list.
                print(CommandLineSpec.verbNames)
            } else {
                print(CommandLineSpec.helpText())
            }
            exit(0)
        }

        // Needs no vault: the keys are the app's, not a vault's. That is also
        // why it answers when Heft has never been pointed anywhere.
        if arguments.first == "keys" {
            if arguments.contains("--markdown") {
                print(KeyboardShortcuts.markdownTable(all: arguments.contains("--all")))
            } else {
                print(KeyboardShortcuts.rendered(), terminator: "")
            }
            exit(0)
        }

        // The agent verbs: propose, proposals, diff, drop, read, find.
        if AgentCLI.run(arguments) { return }

        if let verb = arguments.first,
           ["outline", "links", "backlinks", "tags", "config"].contains(verb) {
            runVaultQuery(verb: verb, arguments: Array(arguments.dropFirst()))
            return
        }

        // Renaming is the one structural edit worth doing from here. A typo in
        // a folder's name is a bad thing to fix by hand — every link into it
        // has to move with it — and it cannot be expressed as a proposal,
        // which carries the new body of one note.
        if arguments.first == "rename", arguments.count > 3 {
            runRename(
                vaultPath: arguments[1], target: arguments[2], newName: arguments[3],
                dryRun: arguments.contains("--dry-run")
            )
            return
        }

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
        // `export <vault> <note> <out.pdf>` writes the rendered note to PDF
        // without a window. The GUI's Export as PDF goes through exactly this,
        // so what a script produces is what the menu item produces.
        if arguments.first == "export", arguments.count > 3 {
            runExport(
                vaultPath: arguments[1], note: arguments[2], output: arguments[3],
                flags: Array(arguments.dropFirst(4))
            )
            return
        }
        // `files <vault> [--by-use] [--limit N] [--scores]`.
        //
        // `--by-use` is the same ranking Quick Open opens on: how often the
        // *reader* opens a note, discounted by how long ago. "Which notes is
        // this person actually working in" is a far better prior than
        // alphabetical order or a modification date, which every sync and
        // every reformat disturbs.
        //
        // `--by-agent` is the same question about the agent's own work, kept
        // in a separate index so neither can drown out the other.
        if arguments.first == "files", arguments.count > 1 {
            let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
                .standardizedFileURL
            let flags = Array(arguments.dropFirst(2))
            let byUse = flags.contains("--by-use")
            let byAgent = flags.contains("--by-agent")
            let showScores = flags.contains("--scores")
            var limit = Int.max
            if let index = flags.firstIndex(of: "--limit"), index + 1 < flags.count,
               let value = Int(flags[index + 1]) {
                limit = max(0, value)
            }

            let notes = VaultScanner.scan(root: root).flattened().filter { !$0.isFolder }
            guard byUse || byAgent || showScores else {
                for item in notes.prefix(limit) { print(item.relativePath) }
                exit(0)
            }

            // Two separate indices: what the reader opens, and what an agent
            // has proposed changes to. Never merged, because they answer
            // different questions for different readers.
            let store = MainActor.assumeIsolated {
                byAgent
                    ? FrecencyStore.agentNotes(forVaultAt: root.path)
                    : FrecencyStore.notes(forVaultAt: root.path)
            }
            let ranked = MainActor.assumeIsolated {
                store.ranked(notes, by: \.relativePath) {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
            }
            for item in (byUse || byAgent ? ranked : notes).prefix(limit) {
                if showScores {
                    let score = MainActor.assumeIsolated { store.score(item.relativePath) }
                    print(String(format: "%8.3f  %@", score, item.relativePath))
                } else {
                    print(item.relativePath)
                }
            }
            exit(0)
        }
        // `agent-setup <vault>` writes the vault's CLAUDE.md, so a coding
        // agent started in that folder knows to propose rather than write.
        // Without it the proposal verbs exist but nothing ever calls them.
        if arguments.first == "agent-setup", arguments.count > 1 {
            let root = URL(
                fileURLWithPath: PathInput.normalize(arguments[1]) ?? arguments[1]
            ).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder),
                  isFolder.boolValue else {
                FileHandle.standardError.write(Data("no such vault: \(arguments[1])\n".utf8))
                exit(1)
            }

            // The path an agent should call is this binary, wherever it is
            // installed, rather than a guess at /Applications.
            let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
            do {
                let outcome = try AgentGuide.install(in: root, binaryPath: binary)
                if let saved = outcome.backedUp {
                    print("saved your edits inside the guide to \(saved.path)")
                }
                for file in outcome.written {
                    print("\(file.created ? "wrote" : "updated") \(file.url.path)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data(("could not write into \(root.path): "
                        + error.localizedDescription + "\n").utf8)
                )
                exit(1)
            }
        }
        // `open [path]` is what the `heft` shell command runs. It resolves the
        // path and hands it to the *bundled* app as a URL rather than doing
        // anything itself: arguments given to `open --args` are dropped unless
        // the app is being launched fresh, and a running Heft is the usual
        // case. Run directly from a shell, this process inherits the working
        // directory, so a relative path — `heft .` above all — resolves
        // against where it was typed.
        if arguments.first == "open" {
            let requested = arguments.count > 1 ? arguments[1] : "."
            let expanded = PathInput.normalize(requested) ?? requested
            let resolved = URL(
                fileURLWithPath: expanded,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL

            guard FileManager.default.fileExists(atPath: resolved.path) else {
                FileHandle.standardError.write(
                    Data("heft: no such file or folder: \(requested)\n".utf8)
                )
                exit(1)
            }
            guard let url = HeftURL.open(path: resolved.path) else { exit(1) }
            exit(NSWorkspace.shared.open(url) ? 0 : 1)
        }
        HeftApp.main()
    }

    /// Read-only report over a vault. Exists so indexing and link resolution
    /// can be checked against a real vault without launching the editor, which
    /// autosaves and would risk writing to notes that matter.
    /// `--text-size N` (points on the page), `--paper a4|letter|legal|tabloid`,
    /// `--landscape`, `--margin narrow|normal|wide`, `--title`.
    ///
    /// `--scale N` is kept as a percentage of the editor's own size, which is
    /// what this took before the setting became absolute.
    private static func exportOptions(_ flags: [String]) -> PDFExportOptions {
        var options = PDFExportOptions()
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            let value = index + 1 < flags.count ? flags[index + 1] : nil
            switch flag {
            case "--text-size":
                if let value, let points = Double(value) {
                    options.bodyPointSize = points
                    index += 1
                }
            case "--scale":
                if let value, let percent = Double(value) {
                    options.bodyPointSize = percent / 100 * Double(Theme.bodySize)
                    index += 1
                }
            case "--paper":
                if let value, let paper = PDFExportOptions.Paper(rawValue: value.lowercased()) {
                    options.paper = paper
                    index += 1
                }
            case "--margin":
                if let value, let margin = PDFExportOptions.Margin(rawValue: value.lowercased()) {
                    options.margin = margin
                    index += 1
                }
            case "--landscape":
                options.isLandscape = true
            case "--title":
                options.includesTitle = true
            default:
                FileHandle.standardError.write(Data("ignoring \(flag)\n".utf8))
            }
            index += 1
        }
        return options
    }

    /// The read-only vault questions an agent cannot answer with grep.
    ///
    /// A resolved link index is the thing Heft knows that the filesystem does
    /// not: wikilinks with aliases, `#heading` and `#^block` targets, which
    /// notes point back, which point nowhere. Reimplementing that outside the
    /// app means reimplementing the parser, and getting it subtly wrong on the
    /// same real-vault syntax the parser was written for.
    private static func runVaultQuery(verb: String, arguments: [String]) {
        guard let vaultPath = arguments.first else {
            FileHandle.standardError.write(Data(
                "\(CommandLineSpec.verb(named: verb)?.usage ?? "heft \(verb)")\n".utf8
            ))
            exit(1)
        }
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))

        /// Resolved against **every** file, not only the Markdown ones.
        ///
        /// `heft files` lists attachments too, so a lookup that only searched
        /// notes rejected paths it had just offered. It also refused the
        /// question worth asking most about an attachment: what references
        /// this image, before I delete it.
        func file(_ name: String, markdownOnly: Bool = false) -> NoteRef {
            let candidates = markdownOnly ? index.notes : index.allFiles
            guard let ref = candidates.first(where: {
                $0.relativePath == name || $0.name == name
            }) else {
                let what = markdownOnly ? "no such note" : "no such file"
                FileHandle.standardError.write(Data("\(what): \(name)\n".utf8))
                exit(1)
            }
            return ref
        }

        switch verb {
        case "config":
            let settings = ObsidianSettings.load(vaultRoot: root)
            let daily = DailyNotes(vaultRoot: root, settings: settings)
            let config: [String: Any] = [
                "vault": root.path,
                "notes": index.notes.count,
                "dailyNotesFolder": daily.folder,
                "dailyNotesFolderIsConfigured": settings.dailyNotesFolderIsConfigured,
                "dailyNoteFormat": settings.dailyNoteFormat,
                "dailyNoteTemplate": settings.dailyNoteTemplate as Any,
                "attachmentFolderPath": settings.attachmentFolderPath,
                "templatesFolder": settings.templatesFolder as Any,
                "useWikilinks": settings.useWikilinks,
                "strictLineBreaks": settings.strictLineBreaks,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
            ), let text = String(data: data, encoding: .utf8) {
                print(text)
            }

        case "tags":
            if arguments.count > 1 {
                let tag = arguments[1].hasPrefix("#")
                    ? String(arguments[1].dropFirst()) : arguments[1]
                for ref in index.notes(taggedWith: tag) { print(ref.relativePath) }
            } else {
                for tag in index.allTags {
                    print("\(index.noteCount(forTag: tag))\t#\(tag)")
                }
            }

        case "outline":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: heft outline <vault> <note>\n".utf8))
                exit(1)
            }
            // Headings only exist in Markdown.
            let ref = file(arguments[1], markdownOnly: true)
            let source = (try? String(contentsOf: ref.url, encoding: .utf8)) ?? ""
            let document = MarkdownModel.parseDocument(source)
            for (offset, block) in document.blocks.enumerated() {
                guard case .heading(let level, let inlines, let anchor) = block else { continue }
                let line = document.lineRanges.indices.contains(offset)
                    ? document.lineRanges[offset].lowerBound + 1 : 0
                let indent = String(repeating: "  ", count: max(0, level - 1))
                print("\(line)\t\(indent)\(String(repeating: "#", count: level)) "
                    + "\(MarkdownModel.plainText(inlines))\t\(anchor)")
            }

        case "links":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: heft links <vault> <note>\n".utf8))
                exit(1)
            }
            let ref = file(arguments[1], markdownOnly: true)
            let unresolved = Set(
                index.unresolvedLinks(from: ref.relativePath, source: ref).map(\.target)
            )
            for link in index.outgoingLinks(from: ref.relativePath) {
                let target = index.resolve(link, from: ref)
                let mark = target == nil || unresolved.contains(link.target) ? "unresolved" : "ok"
                print("\(mark)\t\(link.target)\t\(target?.relativePath ?? "")")
            }

        case "backlinks":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: heft backlinks <vault> <note>\n".utf8))
                exit(1)
            }
            // Any file: "what references this image" is the question worth
            // asking before deleting an attachment.
            let ref = file(arguments[1])
            for backlink in index.backlinks(to: ref.relativePath) {
                let context = backlink.context.trimmingCharacters(in: .whitespaces)
                print("\(backlink.source.relativePath):\(backlink.line)\t\(context)")
            }

        default:
            break
        }
        exit(0)
    }

    private static func runExport(
        vaultPath: String, note: String, output: String, flags: [String] = []
    ) {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
        let index = VaultIndex.build(root: VaultScanner.scan(root: root))
        guard let ref = index.notes.first(where: {
            $0.relativePath == note || $0.name == note
        }) else {
            FileHandle.standardError.write(Data("no such note: \(note)\n".utf8))
            exit(1)
        }
        let source = (try? String(contentsOf: ref.url, encoding: .utf8)) ?? ""
        let context = RenderContext(index: index, current: ref, vaultRoot: root)
        let destination = URL(
            fileURLWithPath: (output as NSString).expandingTildeInPath
        ).standardizedFileURL

        let options = exportOptions(flags)
        let wrote = MainActor.assumeIsolated {
            PDFExport.write(
                text: source, context: context, to: destination,
                title: ref.name, options: options
            )
        }
        guard wrote else {
            FileHandle.standardError.write(Data("could not write \(destination.path)\n".utf8))
            exit(1)
        }
        print("wrote \(destination.path)")
        exit(0)
    }

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

        /// What a picture or transclusion took over from a list marker, so the
        /// headless report shows the bullet is still being drawn.
        func describeCarried(_ lead: BlockLead) -> String {
            var parts: [String] = []
            if let quote = lead.quote {
                parts.append("in quote depth \(quote.line.depth)")
            }
            if let bullet = lead.bullet { parts.append("on list \(bullet.glyph)") }
            guard !parts.isEmpty else { return "" }
            return " " + parts.joined(separator: " ") + " indent \(fmt(lead.indent))"
        }

        func describeNested(_ nested: QuotedBlock?, bullet: LeadingBullet?) -> String {
            switch nested {
            case .list(let kind, let depth, let marker):
                " + list \(kind) depth \(depth) marker \"\(marker)\""
                    + (bullet.map { " glyph \($0.glyph) offset \(fmt($0.markerOffset))" } ?? " NO GLYPH")
            case .heading(let level):
                " + heading h\(level)"
            case nil:
                ""
            }
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
            case .agentGuide(let isEnd): "agent guide \(isEnd ? "end" : "start")"
            case .blockMath(let image): "block math \(size(image.size))"
            case .image(_, let drawn, let lead):
                "image \(size(drawn))" + describeCarried(lead)
            case .table(let grid):
                "table \(size(grid.size)) rows \(grid.rowHeights.count) cols \(grid.columnWidths.count)"
                    + describeActiveCell(of: grid)
            case .properties(let card):
                "properties \(card.rows.count) rows \(size(card.size))"
            case .embed(let embed, let lead):
                "embed \"\(embed.title)\" \(size(embed.size))"
                    + (embed.isTruncated ? " truncated" : "")
                    + describeCarried(lead)
            case .quote(let quote, let indent, _, let bullet):
                "\(quote.rawCallout.map { "callout \($0)" } ?? "quote") depth \(quote.depth) \(quote.edge) indent \(fmt(indent))"
                    + describeNested(quote.nested, bullet: bullet)
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

        print(
            "fragment geometry (frame height / text height / lead / trail"
                + " / frame x / text x):"
        )
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
            // Where a widget drawn beside the text has to start. `draw` is
            // handed the fragment's own origin, and the paragraph's indent may
            // already be in either of these two, so both are reported: a widget
            // that adds an indent to an origin that already carries one lands
            // twice as far in, which is invisible in the model and obvious here.
            print(
                "  line \(line(offset)): \(fmt(frame.height)) / \(fmt(textHeight))"
                    + " / \(fmt(lead)) / \(fmt(trail))"
                    + " / \(fmt(frame.minX)) / \(fmt(first.typographicBounds.minX))"
            )
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

    /// `rename <vault> <path> <new>` — the sidebar's rename, without the
    /// sidebar. `<new>` is a name to keep the item where it is, or a
    /// vault-relative path to move it as well.
    private static func runRename(
        vaultPath: String, target: String, newName: String, dryRun: Bool
    ) {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        let tree = VaultScanner.scan(root: root)
        let index = VaultIndex.build(root: tree)

        let wanted = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let item = tree.flattened().first(where: {
            $0.relativePath == wanted || $0.name == wanted
        }) else {
            FileHandle.standardError.write(Data("no such note or folder: \(target)\n".utf8))
            exit(1)
        }

        // A bare name keeps the item where it is; anything with a slash is a
        // move as well as a rename. The rule, and the `.md` a note is
        // displayed without, are `VaultOperations` in HeftCore — the same ones
        // the sidebar renames by.
        guard let destination = VaultOperations.destination(for: item, named: newName) else {
            FileHandle.standardError.write(Data("the new name is empty\n".utf8))
            exit(1)
        }

        let changes = VaultRename.changes(for: item, movingTo: destination)
        do {
            if dryRun {
                let planned = try VaultRename.rewrites(for: changes, in: index) {
                    try String(contentsOf: $0.url, encoding: .utf8)
                }
                print("would rename: \(item.relativePath) -> \(destination)")
                if changes.count > 1 { print("files moved:  \(changes.count)") }
                for rewrite in planned {
                    print("  \(rewrite.note.relativePath): \(rewrite.links) link"
                        + VaultOperations.plural(rewrite.links))
                }
                let links = planned.reduce(0) { $0 + $1.links }
                print("would repoint \(links) link" + VaultOperations.plural(links)
                    + " in \(planned.count) note" + VaultOperations.plural(planned.count))
                return
            }

            let summary = try VaultRename.perform(
                item: item, to: destination, index: index, vaultRoot: root
            )
            print("renamed: \(item.relativePath) -> \(destination)")
            if changes.count > 1 { print("files moved: \(changes.count)") }
            // One wording, shared with the sidebar's status line, so the two
            // cannot drift apart again.
            let repointed = VaultOperations.repointSummary(summary)
            print(repointed.isEmpty ? "no links needed repointing" : repointed)
        } catch let failure as VaultRename.Failure {
            let message: String = switch failure {
            case .noSuchItem(let path): "no such note or folder: \(path)"
            case .alreadyExists(let path): "already exists: \(path)"
            case .emptyName: "the new name is empty"
            case .unreadable(let path): "could not read \(path) before updating its links"
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(
                Data("rename failed: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

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
        let dailyFolder = DailyNotes(vaultRoot: root, settings: settings).folder
        print("  folder    \(dailyFolder.isEmpty ? "(vault root)" : dailyFolder)")
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
