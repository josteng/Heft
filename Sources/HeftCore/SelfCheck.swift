import Foundation

/// Assertions over the pure logic in HeftCore.
///
/// This exists instead of a test target because XCTest and swift-testing both
/// ship with Xcode, and this project builds against the Command Line Tools
/// only, where `swift test` cannot run. Invoked by `swift run Heft selftest`.
/// If a full Xcode is ever installed, these move to a real test target as-is.
public enum SelfCheck {

    public struct Result: Sendable {
        public var passed: Int = 0
        public var failures: [String] = []
        public var ok: Bool { failures.isEmpty }
    }

    public static func run() -> Result {
        var r = Result()

        func expect(_ actual: String, _ expected: String, _ label: String) {
            if actual == expected { r.passed += 1 }
            else { r.failures.append("\(label): expected \"\(expected)\", got \"\(actual)\"") }
        }
        func expectTrue(_ condition: Bool, _ label: String) {
            if condition { r.passed += 1 } else { r.failures.append(label) }
        }

        // MARK: Date tokens
        // 2026-08-07 is a Friday in ISO week 32, day 219 of the year.
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = utc
        let day = cal.date(from: DateComponents(
            timeZone: utc, year: 2026, month: 8, day: 7, hour: 14, minute: 5, second: 9
        ))!

        func fmt(_ pattern: String) -> String {
            MomentFormat.format(day, pattern: pattern, timeZone: utc)
        }

        expect(fmt("YYYY-MM-DD"), "2026-08-07", "moment YYYY-MM-DD")
        expect(fmt("dddd"), "Friday", "moment dddd")
        expect(fmt("ddd"), "Fri", "moment ddd")
        // The vault's own weekly-link token. ICU would read [W] and WW very
        // differently, which is the reason this engine exists at all.
        expect(fmt("YYYY-[W]WW"), "2026-W32", "moment YYYY-[W]WW")
        // moment DD is day-of-month; moment DDD is day-of-year. ICU swaps these.
        expect(fmt("DD"), "07", "moment DD is day-of-month")
        expect(fmt("DDD"), "219", "moment DDD is day-of-year")
        expect(fmt("MMMM Do, YYYY"), "August 7th, 2026", "moment ordinals")
        expect(fmt("HH:mm:ss"), "14:05:09", "moment 24h time")
        expect(fmt("h:mm a"), "2:05 pm", "moment 12h time")
        expect(fmt("[Literal] YYYY"), "Literal 2026", "moment bracket literal")
        // Ordinal exceptions.
        let d11 = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 11))!
        expect(MomentFormat.format(d11, pattern: "Do", timeZone: utc), "11th", "ordinal 11th")

        // ISO week-year boundary: 2027-01-01 is a Friday, still ISO week 53 of 2026.
        let newYear = cal.date(from: DateComponents(timeZone: utc, year: 2027, month: 1, day: 1))!
        expect(MomentFormat.format(newYear, pattern: "GGGG-[W]WW", timeZone: utc), "2026-W53",
               "ISO week-year at boundary")

        // MARK: Template expansion
        let expanded = MomentFormat.expandTemplate(
            "# {{date:YYYY-MM-DD}} · {{date:dddd}}\n*[[{{date:YYYY-[W]WW}}]]*\n{{title}}",
            date: day, title: "2026-08-07"
        )
        expect(expanded, "# 2026-08-07 · Friday\n*[[2026-W32]]*\n2026-08-07", "template expansion")
        // Unknown placeholders must survive untouched rather than vanish.
        expect(MomentFormat.expandTemplate("{{unknown}}", date: day, title: "t"),
               "{{unknown}}", "unknown placeholder preserved")

        // MARK: Wikilink parsing
        func onlyLink(_ s: String) -> WikiLink? { WikiLinkParser.links(in: s).first }

        expect(onlyLink("[[Note]]")?.target ?? "", "Note", "plain wikilink")
        expect(onlyLink("[[folder/Note]]")?.target ?? "", "folder/Note", "path wikilink")
        expect(onlyLink("[[Note|Alias]]")?.alias ?? "", "Alias", "aliased wikilink")
        expect(onlyLink("[[Note#Heading]]")?.heading ?? "", "Heading", "heading wikilink")
        expect(onlyLink("[[Note#^abc123]]")?.blockID ?? "", "abc123", "block-id wikilink")
        expectTrue(onlyLink("![[img.png]]")?.isEmbed == true, "embed detected")
        expectTrue(onlyLink("![[img.png|300]]")?.embedWidth == 300, "embed width")
        expectTrue(onlyLink("![[img.png|300x200]]")?.embedHeight == 200, "embed height")
        // A pipe on an embed is a size, but a non-numeric pipe is still an alias.
        expect(onlyLink("![[img.png|caption]]")?.alias ?? "", "caption", "embed alias")
        // Obsidian escapes the separator inside tables, where a bare pipe would
        // end the cell. Found in the wild: `| ![[chart.png\|500]] |`.
        expect(onlyLink("![[chart.png\\|500]]")?.target ?? "", "chart.png", "escaped-pipe target")
        expectTrue(onlyLink("![[chart.png\\|500]]")?.embedWidth == 500, "escaped-pipe width")
        expect(onlyLink("[[Note\\|Alias]]")?.alias ?? "", "Alias", "escaped-pipe alias")
        // A literal bracket abutting a link: the link is the innermost pair.
        // Found in the wild as `- Fixed fusion \[[[Paper Name]]`.
        expect(onlyLink("\\[[[Paper]]")?.target ?? "", "Paper", "escaped bracket before link")
        expect(onlyLink("[[[Paper]]]")?.target ?? "", "Paper", "bracket-wrapped link")
        expectTrue(WikiLinkParser.links(in: "[not a link] and [also](url)").isEmpty,
                   "no false positives on markdown links")
        expectTrue(WikiLinkParser.links(in: "[[unterminated").isEmpty, "unterminated link ignored")
        expectTrue(WikiLinkParser.links(in: "[[a]] and [[b]]").count == 2, "multiple links per line")
        expect(onlyLink("[[#Heading]]")?.target ?? "x", "", "same-note heading link")
        expect(onlyLink("[[Note|Alias]]")?.displayText ?? "", "Alias", "display prefers alias")
        expect(onlyLink("[[folder/Note]]")?.displayText ?? "", "Note", "display strips folder")

        // Segments must preserve surrounding text exactly.
        let segs = WikiLinkParser.segments(in: "see [[A]] now")
        expectTrue(segs.count == 3, "segment count")
        if case .text(let t) = segs.first { expect(t, "see ", "leading literal") }
        else { r.failures.append("leading literal missing") }

        // MARK: Frontmatter and headings
        let doc = "---\ntitle: X\n---\n# Head\ntext\n```\n# not a heading\n```\n## Second\n"
        expect(NoteText.splitFrontmatter(doc).frontmatter ?? "", "title: X", "frontmatter split")
        let heads = NoteText.headings(in: doc)
        expectTrue(heads.count == 2, "headings skip fenced code (got \(heads.count))")
        expect(heads.first?.text ?? "", "Head", "first heading")
        expectTrue(NoteText.headings(in: "#tag alone").isEmpty, "tag is not a heading")

        // MARK: iCloud placeholders
        let (resolved, needs) = VaultScanner.resolvePlaceholder(".Note.md.icloud")
        expect(resolved, "Note.md", "icloud placeholder name")
        expectTrue(needs, "icloud placeholder flagged")
        let (plain, plainNeeds) = VaultScanner.resolvePlaceholder("Note.md")
        expect(plain, "Note.md", "normal filename untouched")
        expectTrue(!plainNeeds, "normal filename not flagged")

        // MARK: Block source ranges (foundation for block-based editing)
        let blockDoc = """
        ---
        title: T
        ---
        # Heading

        A paragraph.

        - item one
        - item two
        """
        let parsed = MarkdownModel.parseDocument(blockDoc)
        // A list contributes one editable unit per item, not one for the whole
        // list: focusing a bullet must not turn its siblings into raw source.
        expectTrue(parsed.blocks.count == 4, "heading, paragraph, two list items (got \(parsed.blocks.count))")
        expectTrue(parsed.lineRanges.count == parsed.blocks.count, "one line range per block")
        // Ranges must index the FULL source, frontmatter included.
        expect(parsed.source(ofBlock: 0, in: blockDoc) ?? "", "# Heading", "block 0 source")
        expect(parsed.source(ofBlock: 1, in: blockDoc) ?? "", "A paragraph.", "block 1 source")
        expect(parsed.source(ofBlock: 2, in: blockDoc) ?? "", "- item one", "list item 1 is its own unit")
        expect(parsed.source(ofBlock: 3, in: blockDoc) ?? "", "- item two", "list item 2 is its own unit")

        // MARK: Presentation slides
        let slideBlocks = MarkdownModel.parse("# One\n\n---\n\n## Two\n\n---\n\nThree").blocks
        let slides = PresentationDeck.slides(from: slideBlocks)
        expectTrue(slides.count == 3, "thematic breaks split presentation slides")
        expectTrue(slides.allSatisfy { !$0.contains(where: {
            if case .thematicBreak = $0 { true } else { false }
        }) }, "slide separators are not rendered")
        let fencedSlides = PresentationDeck.slides(
            from: MarkdownModel.parse("# Code\n\n```md\n---\n```").blocks
        )
        expectTrue(fencedSlides.count == 1, "thematic break inside code does not split slides")
        expectTrue(PresentationDeck.slides(from: []).count == 1, "empty note still has one slide")

        // Multi-line `$$…$$` is one paragraph split by soft breaks, so it has
        // to be detected at paragraph level or it renders as raw source.
        let mathDoc = "Before.\n\n$$\nE = mc^2\n$$\n\nAfter."
        let mathBlocks = MarkdownModel.parseDocument(mathDoc).blocks
        var foundDisplayMath = false
        for case .paragraph(let inlines) in mathBlocks {
            for case .math(let latex, true) in inlines where latex == "E = mc^2" { foundDisplayMath = true }
        }
        expectTrue(foundDisplayMath, "multi-line display math is recognised")

        // Splicing an edit back must leave every other byte untouched.
        let edited = parsed.replacing(block: 1, with: "A **better** paragraph.", in: blockDoc) ?? ""
        expect(
            edited,
            blockDoc.replacingOccurrences(of: "A paragraph.", with: "A **better** paragraph."),
            "block replacement preserves the rest of the file"
        )
        // A multi-line replacement must not corrupt following blocks.
        let grown = parsed.replacing(block: 1, with: "Line one.\nLine two.", in: blockDoc) ?? ""
        expectTrue(grown.contains("- item one\n- item two"), "list survives a growing edit above it")
        expectTrue(grown.contains("title: T"), "frontmatter survives a block edit")

        // MARK: Live-mode decorations
        func styles(_ source: String) -> [MarkdownDecoration.Style] {
            LiveDecorator.decorations(in: source).map(\.style)
        }
        func hiddenText(_ source: String) -> String {
            // What live mode would conceal when the cursor is elsewhere.
            let ns = source as NSString
            let ranges = LiveDecorator.decorations(in: source).flatMap(\.syntax)
            return ranges
                .sorted { $0.location < $1.location }
                .map { ns.substring(with: $0) }
                .joined()
        }

        expectTrue(styles("**bold**").contains(.bold), "decorator finds bold")
        expect(hiddenText("**bold**"), "****", "bold markers are hideable")
        expectTrue(styles("*italic*").contains(.italic), "decorator finds italic")
        expectTrue(styles("a_b_c").isEmpty, "underscores inside a word are not italic")
        expectTrue(styles("==hi==").contains(.highlight), "decorator finds highlight")
        expect(hiddenText("[[Note|Alias]]"), "[[Note|]]", "wikilink hides brackets and alias target")
        expect(hiddenText("# Heading"), "# ", "heading hides hashes and space")
        expectTrue(styles("#tag").contains(.tag), "decorator finds tag")

        // MARK: Inline formatting
        func format(_ f: InlineFormat, _ source: String, _ range: NSRange) -> String {
            MarkdownEditing.toggle(f, in: source, range: range).applied(to: source)
        }
        // "hello world", selecting "world".
        expect(format(.bold, "hello world", NSRange(location: 6, length: 5)),
               "hello **world**", "bold wraps the selection")
        // Selecting the marked-up run whole removes it.
        expect(format(.bold, "hello **world**", NSRange(location: 6, length: 9)),
               "hello world", "bold unwraps when the markers are selected")
        // Selecting only the words, with the markers just outside, also removes.
        expect(format(.bold, "hello **world**", NSRange(location: 8, length: 5)),
               "hello world", "bold unwraps when the markers surround the selection")
        expect(format(.italic, "a b", NSRange(location: 2, length: 1)), "a *b*",
               "italic uses one asterisk")
        expect(format(.code, "x", NSRange(location: 0, length: 1)), "`x`", "code uses backticks")
        // An empty selection gives an empty pair to type into.
        let empty = MarkdownEditing.toggle(.bold, in: "ab", range: NSRange(location: 1, length: 0))
        expect(empty.applied(to: "ab"), "a****b", "bold on an empty selection inserts a pair")
        expect("\(empty.selection.location)", "3", "the caret lands between the markers")

        let link = MarkdownEditing.makeLink(in: "see docs", range: NSRange(location: 4, length: 4))
        expect(link.applied(to: "see docs"), "see [docs]()", "a link wraps the selection as its label")
        expect("\(link.selection.location)", "11", "the caret lands inside the parentheses")

        // The edit must touch only the span it changes. Returning the whole
        // document made the editor replace every character to bold one word,
        // which relaid the document out and made the view jump.
        let long = String(repeating: "word ", count: 200) + "target"
        let target = NSRange(location: (long as NSString).length - 6, length: 6)
        let scoped = MarkdownEditing.toggle(.bold, in: long, range: target)
        expect("\(scoped.range.location)", "\(target.location)", "the edit starts at the selection")
        expect("\(scoped.range.length)", "6", "the edit spans the selection, not the document")
        expect(scoped.applied(to: long).hasSuffix("**target**") ? "yes" : "no", "yes",
               "the scoped edit still produces the right text")

        // MARK: Properties and tags
        let properties = Frontmatter.parse("""
        title: A Note
        tags: [alpha, beta]
        aliases:
          - one
          - two
        empty:
        quoted: "with: a colon"
        """)
        expect("\(properties.count)", "5", "every top-level key is a property")
        expect(properties.first?.key ?? "", "title", "keys keep file order")
        expect(properties.first(where: { $0.key == "tags" })?.value.items.joined(separator: ",") ?? "",
               "alpha,beta", "an inline list is parsed")
        expect(properties.first(where: { $0.key == "aliases" })?.value.items.joined(separator: ",") ?? "",
               "one,two", "a block list is parsed")
        expect(properties.first(where: { $0.key == "empty" })?.value.display ?? "nil", "",
               "a key with no value is empty, not missing")
        // Splitting on the first colon only, or the value loses its tail.
        expect(properties.first(where: { $0.key == "quoted" })?.value.display ?? "",
               "with: a colon", "a quoted value keeps its colon and loses its quotes")

        let tagged = """
        ---
        tags: [project, "#work/admin"]
        ---
        Body with #inline and #work/admin again.

        ```
        #notatag
        ```
        """
        let foundTags = NoteTags.all(in: tagged)
        expectTrue(foundTags.contains("project"), "frontmatter tags are found")
        expectTrue(foundTags.contains("inline"), "inline tags are found")
        // Both spellings of the same tag are one tag.
        expect("\(foundTags.count(where: { $0.lowercased() == "work/admin" }))", "1",
               "a tag written in both places is counted once")
        expectTrue(!foundTags.contains("notatag"), "tags inside a fence are not indexed")
        expect(NoteTags.normalise("  #work/admin "), "work/admin", "a tag normalises to its bare name")

        // MARK: Embed bodies
        let embedSource = """
        ---
        tag: x
        ---
        # Title

        Intro.

        ## Section A

        Alpha text. ^alpha

        ### Nested

        Deeper.

        ## Section B

        Beta text.
        """
        // A whole-note embed shows the body, never the frontmatter.
        expectTrue(NoteText.embedBody(of: embedSource, heading: nil, blockID: nil)?
            .hasPrefix("# Title") == true, "a whole-note embed drops frontmatter")
        // A section runs to the next heading of the same or higher level, so a
        // deeper subheading stays inside it.
        let sectionA = NoteText.embedBody(of: embedSource, heading: "Section A", blockID: nil) ?? ""
        expectTrue(sectionA.contains("Alpha text") && sectionA.contains("Deeper"),
                   "a section embed includes its subsections")
        expectTrue(!sectionA.contains("Beta text"),
                   "a section embed stops at the next heading of equal level")
        expect(NoteText.embedBody(of: embedSource, heading: nil, blockID: "alpha") ?? "nil",
               "Alpha text.", "a block embed shows the line without its anchor")
        expectTrue(NoteText.embedBody(of: embedSource, heading: "Nowhere", blockID: nil) == nil,
                   "an embed of a heading that does not exist resolves to nothing")

        // MARK: Link rewriting on rename
        func repoint(_ source: String, _ oldName: String, _ newPath: String) -> String {
            WikiLinkParser.rewriteTargets(
                in: source,
                matches: { $0.target.lowercased() == oldName.lowercased() },
                replacement: { WikiLinkParser.retargeted($0.target, to: newPath) }
            ).text
        }

        expect(repoint("see [[Old]] here", "Old", "New.md"), "see [[New]] here",
               "a bare link is repointed")
        expect(repoint("[[Old|the alias]]", "Old", "New.md"), "[[New|the alias]]",
               "an alias survives repointing")
        expect(repoint("[[Old#Section]]", "Old", "New.md"), "[[New#Section]]",
               "a heading reference survives repointing")
        expect(repoint("[[Old#^abc123]]", "Old", "New.md"), "[[New#^abc123]]",
               "a block reference survives repointing")
        expect(repoint("![[Old.png|500]]", "Old.png", "Renamed.png"), "![[Renamed.png|500]]",
               "an embed keeps its display width")
        // Obsidian writes `\|` inside tables. Rebuilding the link from its
        // parsed parts would flatten that back to a bare pipe and break the row.
        expect(repoint("| a | ![[Old.png\\|500]] |", "Old.png", "New.png"),
               "| a | ![[New.png\\|500]] |", "an escaped pipe survives repointing")
        // Shape is preserved rather than normalised to a full path.
        expect(repoint("[[sub/Old]]", "sub/Old", "sub/New.md"), "[[sub/New]]",
               "a path-shaped link stays a path")
        expect(repoint("[[Old.md]]", "Old.md", "New.md"), "[[New.md]]",
               "an explicit extension is kept")
        // A rename must never edit someone's code sample.
        expect(repoint("```\n[[Old]]\n```", "Old", "New.md"), "```\n[[Old]]\n```",
               "links inside a fence are left alone")
        expect(repoint("[[Other]]", "Old", "New.md"), "[[Other]]", "unrelated links are untouched")
        expect("\(WikiLinkParser.rewriteTargets(in: "[[Old]] and [[Old]]", matches: { $0.target == "Old" }, replacement: { _ in "New" }).count)",
               "2", "every occurrence is counted")
        // The bracket-abutting form real vaults contain.
        expect(repoint("\\[[[Old]]", "Old", "New.md"), "\\[[[New]]",
               "a bracket abutting a link is not absorbed into the target")

        // MARK: Quotes and callouts
        func quotes(_ source: String) -> [QuoteLine] {
            LiveDecorator.decorations(in: source).compactMap {
                if case .quoteLine(let quote) = $0.style { quote } else { nil }
            }
        }

        let plainQuote = quotes("> one\n> two\n")
        expect("\(plainQuote.count)", "2", "both quote lines are decorated")
        expect("\(plainQuote.first?.edge ?? .only)", "first", "first quote line opens the block")
        expect("\(plainQuote.last?.edge ?? .only)", "last", "last quote line closes the block")
        expectTrue(plainQuote.allSatisfy { !$0.isCallout }, "a plain quote is not a callout")
        expect(hiddenText("> quoted"), "> ", "quote marker is hideable")

        // A blank line ends the block, so two quotes in a row stay separate.
        let twoBlocks = quotes("> a\n\ntext\n\n> b\n")
        expectTrue(twoBlocks.count == 2 && twoBlocks.allSatisfy { $0.edge == .only },
                   "quotes separated by prose are separate blocks")

        let callout = quotes("> [!warning] Careful\n> body\n")
        expect("\(callout.first?.callout.map(String.init(describing:)) ?? "nil")", "warning",
               "callout kind is parsed")
        expect(callout.first?.title ?? "", "Careful", "callout title is parsed")
        expectTrue(callout.last?.isCallout == true && callout.last?.isCalloutHeader == false,
                   "the callout's kind carries to its body lines, its title does not")
        // `[!warning]` is markup and hides; the title beside it is prose.
        expectTrue(hiddenText("> [!warning] Careful").contains("[!warning] "),
                   "callout marker is hideable")
        expect(quotes("> [!tip]\n> x").first?.title ?? "nil", "",
               "a callout with no title reports an empty one, not nil")
        expectTrue(quotes("> [!nonsense] hi").first?.callout == nil
                   && quotes("> [!nonsense] hi").first?.rawCallout == "nonsense",
                   "an unknown callout kind is still recognised as a callout")
        expect("\(quotes("> a\n> > b").last?.depth ?? 0)", "2", "nested quote reports depth 2")

        // MARK: Reveal policy
        // A heading's hashes come back from anywhere on the line; a bold span
        // only when the caret is inside that span.
        let sentence = "a **one** b **two**"
        let spans = LiveDecorator.decorations(in: sentence).filter { $0.style == .bold }
        expect("\(spans.count)", "2", "two bold spans found")
        func revealed(at caret: Int) -> Int {
            let reveal = Reveal(
                selection: NSRange(location: caret, length: 0), in: sentence as NSString
            )
            return spans.count { reveal.reveals($0) }
        }
        expect("\(revealed(at: 0))", "0", "caret before any span reveals none")
        expect("\(revealed(at: 5))", "1", "caret inside the first span reveals only it")
        expect("\(revealed(at: 16))", "1", "caret inside the second span reveals only it")
        // Collapsed markup has no width, so a click lands beside a span far
        // more often than in it; the boundary has to count as inside.
        expect("\(revealed(at: 2))", "1", "caret at a span's leading edge reveals it")

        let headingLine = "# Title here"
        let heading = LiveDecorator.decorations(in: headingLine).first {
            if case .heading = $0.style { true } else { false }
        }
        expectTrue(Reveal(
            selection: NSRange(location: 10, length: 0), in: headingLine as NSString
        ).reveals(heading!), "a heading reveals from anywhere on its line")
        expectTrue(!Reveal.none.reveals(heading!), "nothing reveals without a caret")

        // Code must shield its contents from inline styling.
        let fenced = "```\n**not bold**\n```"
        expectTrue(styles(fenced).contains(where: { if case .codeBlock = $0 { true } else { false } }),
                   "decorator finds fenced code")
        expectTrue(!styles(fenced).contains(.bold), "no inline styling inside a fence")
        let unfinishedFence = LiveDecorator.decorations(in: "```python\nprint(1)")
        expectTrue(unfinishedFence.contains(where: {
            $0.style == .codeBlock(language: "python") && !$0.syntax.isEmpty
        }), "unfinished fenced code keeps its language and opening marker")
        let mixedFences = LiveDecorator.decorations(in: "```text\ndone\n```\n\n```swift\nlet x = 1")
        expectTrue(mixedFences.contains(where: {
            $0.style == .codeBlock(language: "swift")
        }), "unfinished fence after a completed block is detected")
        expectTrue(!styles("`**x**`").contains(.bold), "no inline styling inside a code span")

        // Math, and the currency false positive it must avoid.
        expectTrue(styles("$$x^2$$").contains(.blockMath("x^2")), "block math detected")
        // Mid-sentence `$$…$$` has no line of its own to draw into.
        expectTrue(styles("text $$x^2$$ more").contains(.inlineMath("x^2")),
                   "inline $$ stays inline")
        expect(hiddenText("[label](url)"), "[](url)", "markdown link hides bracket and target")
        expectTrue(styles("$x^2$").contains(.inlineMath("x^2")), "inline math detected")
        expectTrue(!styles("costs $5 and $10 today").contains(where: {
            if case .inlineMath = $0 { true } else { false }
        }), "currency is not math")
        expectTrue(!styles("```\n$x^2$\n```").contains(where: {
            if case .inlineMath = $0 { true } else { false }
        }), "no math inside a fence")

        // A heading keeps its decoration when it also holds an inline span.
        // Protection rejects any candidate that *intersects* a protected range,
        // so finding inline math or code before headings deleted the heading
        // outright instead of nesting inside it.
        func headingLevels(_ source: String) -> [Int] {
            styles(source).compactMap { if case .heading(let level) = $0 { level } else { nil } }
        }
        expect("\(headingLevels("# The $h(t)$ model"))", "[1]", "heading survives inline math")
        expect("\(headingLevels("## Use `swift build`"))", "[2]", "heading survives inline code")
        expect("\(headingLevels("# A **bold** title"))", "[1]", "heading survives bold")
        expectTrue(styles("# The $h(t)$ model").contains(.inlineMath("h(t)")),
                   "inline math inside a heading is still found")

        // Tables are claimed whole, so nothing inside is matched separately.
        let table = "| A | B |\n|---|--:|\n| 1 | 2 |\n"
        let tableStyles = styles(table)
        expectTrue(tableStyles.contains(where: { if case .table = $0 { true } else { false } }),
                   "decorator finds a table")
        expectTrue(tableStyles.count == 1, "a table emits exactly one decoration")
        if case .table(let layout)? = tableStyles.first {
            expect("\(layout.rows)", #"[["A", "B"], ["1", "2"]]"#, "table rows split on pipes")
            expect("\(layout.alignments.map { "\($0)" })", #"["leading", "trailing"]"#, "delimiter row sets alignment")
        }
        // Two pipe lines with no delimiter row are not a table.
        expectTrue(!styles("| A | B |\n| 1 | 2 |\n").contains(where: {
            if case .table = $0 { true } else { false }
        }), "pipes without a delimiter row are not a table")
        // Obsidian escapes a literal pipe inside a cell.
        if case .table(let escaped)? = styles("| A |\n|---|\n| x \\| y |\n").first {
            expect("\(escaped.rows.last ?? [])", #"["x | y"]"#, "escaped pipe stays inside its cell")
        }

        // `![alt](x.png)` must be an image, not a link with a stray `!`.
        expectTrue(styles("![alt](x.png)").contains(.image(source: "x.png", alt: "alt")),
                   "markdown image detected")
        expectTrue(!styles("![alt](x.png)").contains(where: {
            if case .link = $0 { true } else { false }
        }), "an image is not also matched as a link")

        // Every syntax range must fall inside its own decoration, or the editor
        // would hide characters belonging to unrelated text.
        let sample = "# H\n**b** *i* `c` [[L|A]] [t](u) ==h== $x$\n> quote\n- [ ] task\n"
        var rangesValid = true
        for decoration in LiveDecorator.decorations(in: sample) {
            for syntax in decoration.syntax
            where NSIntersectionRange(syntax, decoration.range).length != syntax.length {
                rangesValid = false
            }
        }
        expectTrue(rangesValid, "syntax ranges stay within their decoration")

        // MARK: Fuzzy matching
        expectTrue(FuzzyMatch.score(query: "dn", candidate: "daily notes") != nil, "fuzzy subsequence")
        expectTrue(FuzzyMatch.score(query: "zz", candidate: "daily notes") == nil, "fuzzy rejects")
        let wordBoundary = FuzzyMatch.score(query: "dn", candidate: "daily notes") ?? 0
        let midWord = FuzzyMatch.score(query: "dn", candidate: "dnxxxxxxx") ?? 0
        expectTrue(wordBoundary > 0 && midWord > 0, "fuzzy scores positive")
        expectTrue(wordBoundary >= max(36, 2 * 16), "compact fuzzy search clears threshold")
        let loose = FuzzyMatch.score(query: "eee", candidate: "2026-05-19 thesis meeting") ?? 0
        expectTrue(loose < max(36, 3 * 16), "loose repeated letters stay below threshold")

        return r
    }
}
