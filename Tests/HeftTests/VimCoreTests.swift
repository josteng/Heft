import AppKit
import Foundation
import HeftVimCore
import Testing
@testable import Heft

private struct VimHarness {
    var engine = VimEngine()
    var text: String
    var selection: NSRange

    init(_ text: String, cursor: Int = 0) {
        self.text = text
        selection = NSRange(location: cursor, length: 0)
    }

    mutating func send(_ keys: [VimKey]) {
        for key in keys { send(key) }
    }

    mutating func send(_ key: VimKey) {
        let output = engine.handle(key, in: VimSnapshot(text: text, selection: selection))
        if !output.consumed {
            if case let .character(value) = key {
                replace(selection, with: value)
                selection = NSRange(location: selection.location + (value as NSString).length, length: 0)
            }
            return
        }
        for edit in output.edits.sorted(by: { $0.range.location > $1.range.location }) {
            replace(edit.range, with: edit.replacement)
        }
        if let next = output.selection { selection = next }
    }

    mutating func type(_ commands: String) {
        send(commands.map { .character(String($0)) })
    }

    private mutating func replace(_ range: NSRange, with replacement: String) {
        let value = NSMutableString(string: text)
        value.replaceCharacters(in: range, with: replacement)
        text = value as String
    }
}

@Suite("Vim core")
struct VimCoreTests {
    @Test("TextKit adapter applies core transactions without replacing the buffer owner")
    @MainActor
    func textKitAdapter() throws {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isEditable = true
        view.string = "one two"
        view.vimEnabled = true
        view.setSelectedRange(NSRange(location: 0, length: 0))

        view.keyDown(with: try Self.keyEvent("d", keyCode: 2))
        view.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        #expect(view.string == "two")

        view.keyDown(with: try Self.keyEvent("i", keyCode: 34))
        view.insertText("new ", replacementRange: view.selectedRange())
        view.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        #expect(view.string == "new two")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))

        let block = HeftTextKit2View(usingTextLayoutManager: true)
        block.isEditable = true
        block.string = "one\ntwo\n"
        block.vimEnabled = true
        block.setSelectedRange(NSRange(location: 0, length: 0))
        block.keyDown(with: try Self.keyEvent("v", keyCode: 9, modifiers: .control))
        block.keyDown(with: try Self.keyEvent("j", keyCode: 38))
        block.keyDown(with: try Self.keyEvent("I", keyCode: 34, modifiers: .shift))
        block.keyDown(with: try Self.keyEvent("#", keyCode: 20, modifiers: .shift))
        block.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        #expect(block.string == "#one\n#two\n")

        let cursorView = HeftTextKit2View(usingTextLayoutManager: true)
        cursorView.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        cursorView.isEditable = true
        cursorView.string = "cursor"
        cursorView.vimEnabled = true
        let window = NSWindow(
            contentRect: cursorView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cursorView
        _ = window.makeFirstResponder(cursorView)
        cursorView.layoutSubtreeIfNeeded()
        cursorView.updateVimCursor()
        #expect(cursorView.insertionPointColor.alphaComponent == 0)
        #expect(cursorView.subviews.contains { !$0.isHidden && $0.frame.width >= 4 })

        cursorView.setFrameSize(NSSize(width: 1_200, height: 180))
        #expect(abs(cursorView.textContainerInset.width - 220) < 0.5)
        cursorView.setFrameSize(NSSize(width: 400, height: 180))
        #expect(cursorView.textContainerInset.width == 28)

        cursorView.string = "alarm\nnext"
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.layoutSubtreeIfNeeded()
        cursorView.setSelectedRange(NSRange(location: 4, length: 0))
        cursorView.updateVimCursor()
        let endOfLineCursor = try #require(cursorView.subviews.first {
            String(describing: type(of: $0)) == "VimBlockCursorView"
        })
        let finalCharacterFrame = endOfLineCursor.frame
        cursorView.setSelectedRange(NSRange(location: 5, length: 0))
        cursorView.updateVimCursor()
        #expect(endOfLineCursor.frame.width < 30)
        #expect(abs(endOfLineCursor.frame.minX - finalCharacterFrame.minX) < 1)
        #expect(abs(endOfLineCursor.frame.minY - finalCharacterFrame.minY) < 1)
        cursorView.setSelectedRange(NSRange(location: 5, length: 1))
        cursorView.normalizeVimDoubleClickSelection(at: NSPoint(
            x: finalCharacterFrame.maxX + 40,
            y: finalCharacterFrame.midY
        ))
        #expect(cursorView.selectedRange() == NSRange(location: 0, length: 5))

        cursorView.string = "eat breakfast)\nnext"
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.layoutSubtreeIfNeeded()
        cursorView.setSelectedRange(NSRange(location: 13, length: 0))
        cursorView.updateVimCursor()
        let punctuationFrame = endOfLineCursor.frame
        cursorView.setSelectedRange(NSRange(location: 14, length: 1))
        cursorView.normalizeVimDoubleClickSelection(at: NSPoint(
            x: punctuationFrame.maxX + 40,
            y: punctuationFrame.midY
        ))
        #expect(cursorView.selectedRange() == NSRange(location: 13, length: 1))

        cursorView.string = "[[2026-W33]]\n"
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.setSelectedRange(NSRange(location: 12, length: 0))
        cursorView.updateVimCursor()
        _ = LiveStyler.apply(
            to: cursorView.textStorage!,
            reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil)
        )
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.layoutSubtreeIfNeeded()
        // Matches the coordinator's post-restyle update: the overlay may have
        // been positioned while source markup still had ordinary geometry.
        cursorView.updateVimCursor()
        let collapsedLinkEndFrame = endOfLineCursor.frame
        cursorView.setSelectedRange(NSRange(location: 9, length: 0))
        cursorView.updateVimCursor()
        #expect(endOfLineCursor.frame.width < 30)
        #expect(abs(endOfLineCursor.frame.minX - collapsedLinkEndFrame.minX) < 1)
        #expect(abs(endOfLineCursor.frame.minY - collapsedLinkEndFrame.minY) < 1)
        cursorView.setSelectedRange(NSRange(location: 13, length: 0))
        cursorView.updateVimCursor()
        #expect(abs(endOfLineCursor.frame.minX - cursorView.textContainerInset.width) < 1)
        #expect(endOfLineCursor.frame.width < 30)

        cursorView.string = "one\n\nthree"
        _ = LiveStyler.apply(
            to: cursorView.textStorage!,
            reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil)
        )
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.layoutSubtreeIfNeeded()
        cursorView.setSelectedRange(NSRange(location: 4, length: 0))
        cursorView.updateVimCursor()
        let emptyLineFrame = endOfLineCursor.frame
        #expect(cursorView.vimEmptyLineLocation(at: NSPoint(
            x: cursorView.textContainerInset.width + 4,
            y: emptyLineFrame.midY
        )) == 4)
        #expect(cursorView.selectedRange() == NSRange(location: 4, length: 0))

        let dailyHeader = "*[[2026-W33]]*\n\n\n---\n\n## 📋 DAILY LOG\n"
        cursorView.string = dailyHeader
        _ = LiveStyler.apply(
            to: cursorView.textStorage!,
            reveal: .none,
            context: RenderContext(index: .empty, current: nil, vaultRoot: nil)
        )
        cursorView.textLayoutManager?.ensureLayout(
            for: cursorView.textLayoutManager!.textContentManager!.documentRange
        )
        cursorView.layoutSubtreeIfNeeded()
        var emptyFrames: [NSRect] = []
        for location in [15, 16, 21] {
            cursorView.setSelectedRange(NSRange(location: location, length: 0))
            cursorView.updateVimCursor()
            let frame = endOfLineCursor.frame
            emptyFrames.append(frame)
            #expect(abs(frame.minX - cursorView.textContainerInset.width) < 1)
            #expect(cursorView.vimEmptyLineLocation(at: NSPoint(
                x: cursorView.textContainerInset.width + 4,
                y: frame.midY
            )) == location)
        }
        #expect(emptyFrames[0].minY < emptyFrames[1].minY)
        #expect(emptyFrames[1].minY < emptyFrames[2].minY)

        cursorView.string = "abcdef\nx\nabcdef\n"
        cursorView.setSelectedRange(NSRange(location: 2, length: 0))
        cursorView.keyDown(with: try Self.keyEvent("j", keyCode: 38))
        #expect(cursorView.selectedRange().location == 7)
        cursorView.keyDown(with: try Self.keyEvent("j", keyCode: 38))
        #expect(cursorView.selectedRange().location == 11)
        cursorView.keyDown(with: try Self.keyEvent("k", keyCode: 40))
        cursorView.keyDown(with: try Self.keyEvent("k", keyCode: 40))
        #expect(cursorView.selectedRange().location == 2)
    }

    @Test("Dot repeats operators and native Insert transactions")
    @MainActor
    func textKitDotRepeat() throws {
        let operators = HeftTextKit2View(usingTextLayoutManager: true)
        operators.isEditable = true
        operators.string = "one two three"
        operators.vimEnabled = true
        operators.setSelectedRange(NSRange(location: 0, length: 0))
        operators.keyDown(with: try Self.keyEvent("d", keyCode: 2))
        operators.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        operators.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(operators.string == "three")

        let counted = HeftTextKit2View(usingTextLayoutManager: true)
        counted.isEditable = true
        counted.string = "one two three four five"
        counted.vimEnabled = true
        counted.setSelectedRange(NSRange(location: 0, length: 0))
        counted.keyDown(with: try Self.keyEvent("2", keyCode: 19))
        counted.keyDown(with: try Self.keyEvent("d", keyCode: 2))
        counted.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        counted.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(counted.string == "five")

        let insertion = HeftTextKit2View(usingTextLayoutManager: true)
        insertion.isEditable = true
        insertion.string = "one two"
        insertion.vimEnabled = true
        insertion.setSelectedRange(NSRange(location: 0, length: 0))
        insertion.keyDown(with: try Self.keyEvent("i", keyCode: 34))
        insertion.insertText("new ", replacementRange: insertion.selectedRange())
        insertion.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        insertion.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        insertion.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(insertion.string == "new new one two")
        #expect(insertion.selectedRange().location == 7)

        let change = HeftTextKit2View(usingTextLayoutManager: true)
        change.isEditable = true
        change.string = "one two three"
        change.vimEnabled = true
        change.setSelectedRange(NSRange(location: 0, length: 0))
        change.keyDown(with: try Self.keyEvent("c", keyCode: 8))
        change.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        change.insertText("item", replacementRange: change.selectedRange())
        change.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        change.keyDown(with: try Self.keyEvent("w", keyCode: 13))
        change.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(change.string == "item item three")

        let replace = HeftTextKit2View(usingTextLayoutManager: true)
        replace.isEditable = true
        replace.string = "abc"
        replace.vimEnabled = true
        replace.setSelectedRange(NSRange(location: 0, length: 0))
        replace.keyDown(with: try Self.keyEvent("r", keyCode: 15))
        replace.keyDown(with: try Self.keyEvent("X", keyCode: 7, modifiers: .shift))
        replace.keyDown(with: try Self.keyEvent("l", keyCode: 37))
        replace.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(replace.string == "XXc")

        let openLine = HeftTextKit2View(usingTextLayoutManager: true)
        openLine.isEditable = true
        openLine.string = "one\n"
        openLine.vimEnabled = true
        openLine.setSelectedRange(NSRange(location: 0, length: 0))
        openLine.keyDown(with: try Self.keyEvent("o", keyCode: 31))
        openLine.insertText("- item", replacementRange: openLine.selectedRange())
        openLine.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        openLine.keyDown(with: try Self.keyEvent(".", keyCode: 47))
        #expect(openLine.string == "one\n- item\n- item\n")

        if let nvim = Self.neovimURL {
            let operatorOracle = try Self.runNeovim(
                nvim, source: "one two three", command: "dw."
            )
            let countedOracle = try Self.runNeovim(
                nvim, source: "one two three four five", command: "2dw."
            )
            let replaceOracle = try Self.runNeovim(
                nvim, source: "abc", command: "rXl."
            )
            let insertionOracle = try Self.runNeovim(
                nvim,
                source: "one two",
                exCommand: #"+execute "normal! inew \<Esc>w.""#
            )
            let changeOracle = try Self.runNeovim(
                nvim,
                source: "one two three",
                exCommand: #"+execute "normal! cwitem\<Esc>w.""#
            )
            let openLineOracle = try Self.runNeovim(
                nvim,
                source: "one\n",
                exCommand: #"+execute "normal! o- item\<Esc>.""#
            )
            // Neovim's default 'fixendofline' adds an EOL while writing these
            // initially unterminated oracle files; the in-memory edits agree.
            #expect(operators.string + "\n" == operatorOracle)
            #expect(counted.string + "\n" == countedOracle)
            #expect(replace.string + "\n" == replaceOracle)
            #expect(insertion.string + "\n" == insertionOracle)
            #expect(change.string + "\n" == changeOracle)
            #expect(openLine.string == openLineOracle)
        }
    }

    @Test("Optional Vim edits preserve Markdown list and quote structure")
    @MainActor
    func markdownAwareVimEdits() throws {
        func editor(_ source: String, cursor: Int = 0, enabled: Bool = true) -> HeftTextKit2View {
            let view = HeftTextKit2View(usingTextLayoutManager: true)
            view.isEditable = true
            view.string = source
            view.vimEnabled = true
            view.vimContinuesMarkdownStructure = enabled
            view.setSelectedRange(NSRange(location: cursor, length: 0))
            return view
        }
        func send(_ command: String, to view: HeftTextKit2View) throws {
            for character in command {
                view.keyDown(with: try Self.keyEvent(String(character), keyCode: 0))
            }
        }

        let bullet = editor("- first\nplain")
        try send("o", to: bullet)
        #expect(bullet.string == "- first\n- \nplain")

        let above = editor("- first\n")
        try send("O", to: above)
        #expect(above.string == "- \n- first\n")

        let ordered = editor("9. first\n")
        try send("o", to: ordered)
        #expect(ordered.string == "9. first\n10. \n")

        let task = editor("- [x] done\n")
        try send("o", to: task)
        #expect(task.string == "- [x] done\n- [ ] \n")

        let quotedList = editor("> - item\n")
        try send("o", to: quotedList)
        #expect(quotedList.string == "> - item\n> - \n")

        let change = editor("- old item\n")
        try send("cc", to: change)
        change.insertText("new item", replacementRange: change.selectedRange())
        change.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        #expect(change.string == "- new item\n")

        let substituteLine = editor("- old item\n")
        try send("S", to: substituteLine)
        substituteLine.insertText("new item", replacementRange: substituteLine.selectedRange())
        substituteLine.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        #expect(substituteLine.string == "- new item\n")

        let visualLine = editor("- old item\n- next item\n")
        try send("Vc", to: visualLine)
        visualLine.insertText("new item", replacementRange: visualLine.selectedRange())
        visualLine.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        #expect(visualLine.string == "- new item\n- next item\n")

        let repeatedOrdered = editor("1. first\n")
        try send("o", to: repeatedOrdered)
        repeatedOrdered.insertText("second", replacementRange: repeatedOrdered.selectedRange())
        repeatedOrdered.keyDown(with: try Self.keyEvent("\u{1b}", keyCode: 53))
        try send(".", to: repeatedOrdered)
        #expect(repeatedOrdered.string == "1. first\n2. second\n3. second\n")

        let strict = editor("- first\n", enabled: false)
        try send("o", to: strict)
        #expect(strict.string == "- first\n\n")
    }

    @Test("Normal motions and counts use UTF-16 safely")
    func motionsAndCounts() {
        var vim = VimHarness("one 👩🏽‍💻 three\nshort\n")
        vim.type("w")
        #expect(vim.selection.location == 4)
        vim.type("l")
        #expect(vim.selection.location == 11)
        vim.type("2w")
        #expect(vim.selection.location == 18)
        vim.type("0")
        #expect(vim.selection.location == 18)
        vim.type("j$")
        #expect(vim.selection.location == 22)

        var uneven = VimHarness("abcdef\nx\nabcdef\n", cursor: 4)
        uneven.type("jj")
        #expect(uneven.selection.location == 13)
        uneven.type("kk")
        #expect(uneven.selection.location == 4)
    }

    @Test("Operators compose with motions and counts")
    func operators() {
        var vim = VimHarness("one two three\nsecond line\nthird\n")
        vim.type("dw")
        #expect(vim.text == "two three\nsecond line\nthird\n")
        vim.type("2dd")
        #expect(vim.text == "third\n")
        #expect(vim.engine.unnamedRegister == VimRegister(text: "two three\nsecond line\n", linewise: true))
    }

    @Test("Change enters Insert and Escape returns to Normal")
    func changeAndInsert() {
        var vim = VimHarness("hello world")
        vim.type("cw")
        #expect(vim.engine.mode == .insert)
        vim.type("goodbye")
        vim.send(.escape)
        #expect(vim.text == "goodbye world")
        #expect(vim.engine.mode == .normal)
        #expect(vim.selection.location == 6)

        var controlEscape = VimHarness("text")
        controlEscape.type("A")
        controlEscape.type("!")
        controlEscape.send(.control("["))
        #expect(controlEscape.text == "text!")
        #expect(controlEscape.engine.mode == .normal)
    }

    @Test("Visual and Visual Line operations retain their active endpoint")
    func visualModes() {
        var visual = VimHarness("one two three")
        visual.type("v2wd")
        #expect(visual.text == "hree")
        #expect(visual.engine.mode == .normal)

        var lines = VimHarness("one\ntwo\nthree\n")
        lines.type("Vjy")
        #expect(lines.engine.unnamedRegister == VimRegister(text: "one\ntwo\n", linewise: true))
        lines.type("p")
        #expect(lines.text == "one\none\ntwo\ntwo\nthree\n")

        var innerWord = VimHarness("alpha beta, gamma", cursor: 7)
        innerWord.type("viw")
        #expect(innerWord.selection == NSRange(location: 6, length: 4))
        innerWord.type("d")
        #expect(innerWord.text == "alpha , gamma")

        var innerWhitespace = VimHarness("one   two", cursor: 4)
        innerWhitespace.type("viwd")
        #expect(innerWhitespace.text == "onetwo")

        var aroundWord = VimHarness("one   two   three", cursor: 7)
        aroundWord.type("vawd")
        #expect(aroundWord.text == "one   three")

        var innerQuote = VimHarness("say \"hello there\" now", cursor: 6)
        innerQuote.type("vi\"d")
        #expect(innerQuote.text == "say \"\" now")

        var put = VimHarness("one two three")
        put.type("yiwwviwp")
        #expect(put.text == "one one three")
        #expect(put.engine.unnamedRegister == VimRegister(text: "two", linewise: false))

        var mouseSelection = VimEngine()
        mouseSelection.adoptVisualSelection(NSRange(location: 6, length: 4), in: "alpha beta")
        let deletedSelection = mouseSelection.handle(
            .character("d"),
            in: VimSnapshot(text: "alpha beta", selection: NSRange(location: 6, length: 4))
        )
        #expect(deletedSelection.mode == .normal)
        #expect(deletedSelection.edits == [
            VimEdit(range: NSRange(location: 6, length: 4), replacement: ""),
        ])
    }

    @Test("Visual Block deletes columns and inserts on every selected line")
    func visualBlock() {
        var insert = VimHarness("one\ntwo\nthree\n")
        insert.send(.control("v"))
        insert.type("jjI# ")
        insert.send(.escape)
        #expect(insert.text == "# one\n# two\n# three\n")
        #expect(insert.engine.mode == .normal)

        var delete = VimHarness("one\ntwo\nthree\n")
        delete.send(.control("v"))
        delete.type("jjld")
        #expect(delete.text == "e\no\nree\n")
    }

    @Test("Find, matching bracket, paragraph, and line-end motions")
    func additionalMotions() {
        var vim = VimHarness("(alpha beta) x\n\nlast")
        vim.type("%")
        #expect(vim.selection.location == 11)
        vim.type("Fx")
        #expect(vim.selection.location == 11)
        vim.type("fx")
        #expect(vim.selection.location == 13)
        vim.type("}")
        #expect(vim.selection.location == 15)

        var search = VimHarness("word other word")
        let searchOutput = search.engine.handle(
            .character("*"),
            in: VimSnapshot(text: search.text, selection: search.selection)
        )
        #expect(searchOutput.hostAction == .searchWord(query: "word", backward: false, origin: 0))
        #expect(search.engine.mode == .normal)
        #expect(search.selection.location == 0)
    }

    @Test("Text objects, replace, case, and join")
    func editingCommands() {
        var word = VimHarness("one two three", cursor: 5)
        word.type("diw")
        #expect(word.text == "one  three")

        var quote = VimHarness("before \"inside words\" after", cursor: 10)
        quote.type("ci\"")
        quote.type("new")
        quote.send(.escape)
        #expect(quote.text == "before \"new\" after")

        var other = VimHarness("one\n  two\nthree")
        other.type("J")
        #expect(other.text == "one two\nthree")
        other.type("0rX~")
        #expect(other.text == "xne two\nthree")

        var replace = VimHarness("abc")
        replace.type("Rhello")
        replace.send(.escape)
        #expect(replace.text == "hello")
        #expect(replace.engine.mode == .normal)
    }

    @Test("Line and Visual indentation use Heft's Markdown tab width")
    func indentation() {
        var lines = VimHarness("- one\n- two\nplain\n")
        lines.type("2>>")
        #expect(lines.text == "\t- one\n\t- two\nplain\n")
        lines.type("2<<")
        #expect(lines.text == "- one\n- two\nplain\n")

        var visual = VimHarness("one\ntwo\nthree\n")
        visual.type("Vj>")
        #expect(visual.text == "\tone\n\ttwo\nthree\n")
        #expect(visual.engine.mode == .normal)
    }

    @Test("Counted operators retain Vim boundary semantics without an external oracle")
    func countedOperatorBoundaries() {
        let source = "top row words here\n  alpha, beta gamma delta\nshort row\n  omega sigma tail\nlast row\n"
        let alpha = (source as NSString).range(of: "alpha").location

        var words = VimHarness(source, cursor: alpha + 1)
        words.type("2d3W")
        #expect(words.text == "top row words here\n  a\n  omega sigma tail\nlast row\n")

        var vertical = VimHarness("one\ntwo\nthree\n", cursor: 4)
        vertical.type("2dk")
        #expect(vertical.text == "three\n")

        var motion = VimHarness("one\ntwo\nthree\n", cursor: 4)
        motion.type("9j")
        #expect(motion.selection.location == 8)
        motion.type("9k")
        #expect(motion.selection.location == 0)
    }

    @Test("Coverage-map discoveries remain protected without Neovim")
    func coverageMapRegressions() {
        var blankWords = VimHarness("amber red\n\nblue cyan\ngreen\n", cursor: 2)
        blankWords.type("d3w")
        #expect(blankWords.text == "am\nblue cyan\ngreen\n")

        let columnsSource = "heading words\n\n  indented alpha,beta\nx\na considerably longer final row\n"
        let columnsText = columnsSource as NSString
        var stickyEnd = VimHarness(
            columnsSource,
            cursor: columnsText.range(of: "alpha").location + 3
        )
        stickyEnd.type("$2j")
        #expect(stickyEnd.selection.location == columnsText.length - 2)

        var paragraph = VimHarness(columnsSource, cursor: columnsText.range(of: "alpha").location + 3)
        let paragraphOrigin = paragraph.selection.location
        paragraph.type("2}")
        #expect(paragraph.selection.location == paragraphOrigin)

        var till = VimHarness("key: one, two, three\n", cursor: 5)
        till.type("dt,")
        #expect(till.text == "key: , two, three\n")

        var backwardFind = VimHarness("key: one, two, three\n", cursor: 18)
        backwardFind.type("dF,")
        #expect(backwardFind.text == "key: one, twoee\n")

        var multilineObject = VimHarness("lead [\n  first\n  second\n] tail\n", cursor: 12)
        multilineObject.type("di[")
        #expect(multilineObject.text == "lead [\n] tail\n")

        var visualEnd = VimHarness("alpha\nbeta gamma\n", cursor: 2)
        visualEnd.type("v$d")
        #expect(visualEnd.text == "albeta gamma\n")
    }

    @Test("External Neovim agrees on representative buffer edits")
    func neovimDifferential() throws {
        guard let nvim = Self.neovimURL else { return }
        let fixtures: [(String, String)] = [
            ("dw", "one two three\nsecond line\n"),
            ("dw", "one\nsecond line\n"),
            ("daw", "one two three\nsecond line\n"),
            ("diw", "one two three\nsecond line\n"),
            ("de", "one two three\nsecond line\n"),
            ("2dw", "one two three\nsecond line\n"),
            ("d2w", "one two three\nsecond line\n"),
            ("2x", "one two three\nsecond line\n"),
            ("3rX", "one two three\nsecond line\n"),
            ("3~", "one two three\nsecond line\n"),
            ("d$", "one two three\nsecond line\n"),
            ("dd", "one two three\nsecond line\n"),
            ("2dd", "one two three\nsecond line\nthird line\n"),
            ("dG", "one\nsecond line\nthird line\n"),
            ("ddp", "one two three\nsecond line\n"),
            ("yyP", "one two three\nsecond line\n"),
            ("yyp", "one"),
            ("ywp", "one two three\nsecond line\n"),
            ("v2wd", "one two three\nsecond line\n"),
            ("wviwd", "alpha beta, gamma\n"),
            ("f viwd", "one   two\n"),
            ("wvawd", "one   two   three\n"),
            ("f\"lvi\"d", "say \"hello there\" now\n"),
            ("yiwwviwp", "one two three\n"),
            ("Vjd", "one two three\nsecond line\nthird line\n"),
            ("J", "one two three\nsecond line\n"),
            ("2J", "one\n  two\nthree\n"),
            ("3J", "one\n  two\nthree\n"),
        ]
        for (command, source) in fixtures {
            var heft = VimHarness(source)
            heft.type(command)
            let oracle = try Self.runNeovim(nvim, source: source, command: command)
            #expect(heft.text == oracle, "Mismatch for normal! \(command)")
        }
    }

    @Test("External Neovim agrees on Visual Block insert and delete")
    func neovimVisualBlockDifferential() throws {
        guard let nvim = Self.neovimURL else { return }
        let source = "one\ntwo\nthree\n"

        var insert = VimHarness(source)
        insert.send(.control("v"))
        insert.type("jjI# ")
        insert.send(.escape)
        let inserted = try Self.runNeovim(
            nvim,
            source: source,
            exCommand: #"+execute "normal! \<C-v>jjI# \<Esc>""#
        )
        #expect(insert.text == inserted)

        var delete = VimHarness(source)
        delete.send(.control("v"))
        delete.type("jjld")
        let deleted = try Self.runNeovim(
            nvim,
            source: source,
            exCommand: #"+execute "normal! \<C-v>jjld""#
        )
        #expect(delete.text == deleted)
    }

    @Test("External Neovim agrees on a cursor-motion matrix")
    func neovimMotionMatrix() throws {
        guard let nvim = Self.neovimURL else { return }
        let source = "(alpha beta) x\nshort\nalpha beta gamma\n\nlast line\n"
        let thirdLine = (source as NSString).range(of: "alpha beta gamma").location
        let fixtures: [(cursor: Int, command: String)] = [
            (2, "h"), (2, "l"), (2, "w"), (2, "2w"), (2, "e"),
            (2, "0"), (2, "$"), (0, "%"), (2, "fx"), (2, "tx"),
            (2, "fx;"), (2, "fx,"), (7, "j"), (7, "2j"),
            (thirdLine + 7, "k"), (thirdLine + 7, "2k"),
            (thirdLine + 7, "gg"), (2, "G"), (2, "}"),
        ]
        for fixture in fixtures {
            var heft = VimHarness(source, cursor: fixture.cursor)
            heft.type(fixture.command)
            let oracle = try Self.runNeovimCursor(
                nvim,
                source: source,
                cursor: fixture.cursor,
                command: fixture.command
            )
            #expect(
                heft.selection.location == oracle,
                "Cursor mismatch for normal! \(fixture.command) from \(fixture.cursor)"
            )
        }
    }

    @Test("External Neovim agrees on text objects from every relevant cursor position")
    func neovimTextObjectMatrix() throws {
        guard let nvim = Self.neovimURL else { return }
        let fixtures: [(source: String, cursor: Int, commands: [String])] = [
            ("one   two, three\n", 0, ["diw", "daw"]),
            ("one   two, three\n", 2, ["diw", "daw"]),
            ("one   two, three\n", 3, ["diw", "daw"]),
            ("one   two, three\n", 5, ["diw", "daw"]),
            ("one   two, three\n", 6, ["diw", "daw"]),
            ("one   two, three\n", 9, ["diw", "daw"]),
            ("say \"hello there\" now\n", 6, ["di\"", "da\""]),
            ("say \"hello there\" now\n", 12, ["di\"", "da\""]),
            ("before (inside words) after\n", 10, ["di(", "da("]),
            ("before [inside words] after\n", 10, ["di[", "da["]),
            ("before {inside words} after\n", 10, ["di{", "da{"]),
            ("outer (inner (deep) tail) end\n", 15, ["di(", "da("]),
            (#"say "hello \"there\" now" end"# + "\n", 8, ["di\"", "da\""]),
            (#"say "hello \"there\" now" end"# + "\n", 18, ["di\"", "da\""]),
        ]
        for fixture in fixtures {
            for command in fixture.commands {
                var heft = VimHarness(fixture.source, cursor: fixture.cursor)
                heft.type(command)
                let oracle = try Self.runNeovim(
                    nvim,
                    source: fixture.source,
                    cursor: fixture.cursor,
                    command: command
                )
                #expect(
                    heft.text == oracle,
                    "Text-object mismatch for normal! \(command) from \(fixture.cursor) in \(fixture.source.debugDescription)"
                )
            }
        }
    }

    @Test("External Neovim agrees on operator-motion compositions away from column zero")
    func neovimOperatorMotionMatrix() throws {
        guard let nvim = Self.neovimURL else { return }
        let source = "first alpha beta\nsecond (inside) tail\n\nlast words here\n"
        let fixtures: [(cursor: Int, commands: [String])] = [
            (6, ["dw", "de", "d2w", "d$", "d0", "cw", "ce", "yw"]),
            (12, ["db", "dB", "d^", "c$", "ye"]),
            (23, ["d%", "di(", "da("]),
            (26, ["d$", "d0", "dgg", "dG"]),
            (42, ["db", "d2b", "d^", "dgg"]),
        ]
        for fixture in fixtures {
            for command in fixture.commands {
                var heft = VimHarness(source, cursor: fixture.cursor)
                heft.type(command)
                let oracle = try Self.runNeovim(
                    nvim,
                    source: source,
                    cursor: fixture.cursor,
                    command: command
                )
                #expect(
                    heft.text == oracle,
                    "Operator-motion mismatch for normal! \(command) from \(fixture.cursor)"
                )
            }
        }
    }

    @Test("Generated operator, motion, and count matrix agrees with Neovim")
    func neovimGeneratedOperatorMatrix() throws {
        guard let nvim = Self.neovimURL else { return }
        let source = "top row words here\n  alpha, beta gamma delta\nshort row\n  omega sigma tail\nlast row\n"
        let text = source as NSString
        let alpha = text.range(of: "alpha").location
        let gamma = text.range(of: "gamma").location

        // These dimensions are deliberately generated rather than maintained
        // as hand-picked command fixtures. Together they exercise both count
        // positions (`2d3w`), every word class, inclusive/exclusive motions,
        // line-end and vertical linewise ranges, from two nonzero columns.
        let cursors = [alpha + 1, gamma + 2]
        let operators = ["d", "c", "y"]
        let motions = ["w", "W", "e", "E", "b", "B", "$", "j", "k"]
        let counts = [
            (operatorCount: "", motionCount: ""),
            (operatorCount: "2", motionCount: ""),
            (operatorCount: "", motionCount: "2"),
            (operatorCount: "2", motionCount: "3"),
        ]

        for cursor in cursors {
            for op in operators {
                for motion in motions {
                    for count in counts {
                        let command = count.operatorCount + op + count.motionCount + motion
                        var heft = VimHarness(source, cursor: cursor)
                        let oracleCommand: String
                        switch op {
                        case "c":
                            heft.type(command)
                            heft.type("X")
                            heft.send(.escape)
                            // :normal returns to Normal mode when its argument
                            // ends, so no escaped key has to cross Process APIs.
                            oracleCommand = command + "X"
                        case "y":
                            // A yank alone leaves the buffer unchanged. Putting
                            // immediately before the cursor makes range errors
                            // observable without reading Neovim's registers.
                            heft.type(command + "P")
                            oracleCommand = command + "P"
                        default:
                            heft.type(command)
                            oracleCommand = command
                        }
                        let oracle = try Self.runNeovim(
                            nvim,
                            source: source,
                            cursor: cursor,
                            command: oracleCommand
                        )
                        #expect(
                            heft.text == oracle,
                            "Generated mismatch for normal! \(oracleCommand) from \(cursor)"
                        )
                    }
                }
            }
        }
    }

    @Test("Mature Vim-emulator coverage categories agree with Neovim")
    func neovimCoverageMapCorpus() throws {
        guard let nvim = Self.neovimURL else { return }

        // Original Heft fixtures covering the high-yield edge categories in
        // CodeMirror-Vim and VSCodeVim: whitespace/blank-line transitions,
        // only/last-line edits, puts at buffer edges, reverse Visual ranges,
        // find operators, and nested or multiline text objects. No upstream
        // fixture text or expected output is copied; Neovim supplies results.
        let fixtures: [(label: String, source: String, cursor: Int, command: String)] = [
            ("dw before blank lines", "amber\n\n  \nblue cyan\n", 0, "dw"),
            ("counted word delete across blanks", "amber red\n\nblue cyan\ngreen\n", 2, "d3w"),
            ("word-end delete across blanks", "amber red\n\nblue cyan\n", 1, "d2e"),
            ("backward word delete across blanks", "amber red\n\nblue cyan\n", 17, "d2b"),
            ("delete last line", "north\ncenter\nsouth\n", 13, "dd"),
            ("delete only terminated line", "solo\n", 0, "dd"),
            ("delete only unterminated line", "solo", 2, "dd"),
            ("counted delete clips at eof", "north\ncenter\nsouth\n", 6, "9dd"),
            ("change lines near eof", "north\n  center\n  south\n", 8, "3ccX"),
            ("delete characters clips at eol", "small\nnext\n", 3, "9x"),
            ("backspace characters clips at bol", "small\nnext\n", 2, "9X"),
            ("delete to line end", "prefix middle suffix\nnext\n", 7, "D"),
            ("change to line end", "prefix middle suffix\nnext\n", 7, "CX"),
            ("join indented line", "alpha\n    beta\ngamma\n", 0, "J"),
            ("counted join clips at eof", "alpha\n beta\n  gamma\n", 0, "9J"),
            ("find delete inclusive", "key: one, two, three\n", 5, "df,"),
            ("find delete exclusive", "key: one, two, three\n", 5, "dt,"),
            ("counted find delete", "key: one, two, three\n", 5, "d2f,"),
            ("backward find delete", "key: one, two, three\n", 18, "dF,"),
            ("matching pair delete", "before (alpha [beta] gamma) after\n", 9, "d%"),
            ("inner word amid tabs", "left \talpha\t right\n", 8, "diw"),
            ("around word amid punctuation", "left, alpha... right\n", 8, "daw"),
            ("inner WORD includes punctuation", "left alpha.beta right\n", 8, "diW"),
            ("around WORD includes punctuation", "left alpha.beta right\n", 8, "daW"),
            ("inner nested parentheses", "outer (middle (deep value) tail) end\n", 16, "di("),
            ("around nested braces", "outer {middle {deep value} tail} end\n", 17, "da{"),
            ("inner multiline brackets", "lead [\n  first\n  second\n] tail\n", 12, "di["),
            ("around multiline angles", "lead <\n  first\n  second\n> tail\n", 12, "da<"),
            ("inner escaped quotes", #"say "alpha \"beta\" gamma" tail"# + "\n", 14, "di\""),
            ("linewise put after", "north\ncenter\nsouth\n", 6, "ddp"),
            ("linewise put before", "north\ncenter\nsouth\n", 6, "ddP"),
            ("put after unterminated eof", "north\nsouth", 6, "yyp"),
            ("put before first line", "north\nsouth\n", 0, "yyP"),
            ("character put after", "alpha beta gamma\n", 6, "ywp"),
            ("character put before", "alpha beta gamma\n", 6, "ywP"),
            ("visual delete through eol", "alpha\nbeta gamma\n", 2, "v$d"),
            ("visual delete into next line", "alpha\nbeta gamma\n", 2, "vjld"),
            ("reverse visual delete", "alpha beta gamma\n", 12, "v2bd"),
            ("visual line delete at eof", "north\ncenter\nsouth\n", 6, "V9jd"),
            ("visual paste shorter register", "tiny replacement target\n", 0, "yiwwviwp"),
        ]

        for fixture in fixtures {
            var heft = VimHarness(fixture.source, cursor: fixture.cursor)
            heft.type(fixture.command)
            let oracle = try Self.runNeovim(
                nvim,
                source: fixture.source,
                cursor: fixture.cursor,
                command: fixture.command
            )
            #expect(
                heft.text == oracle,
                "Coverage-map mismatch for \(fixture.label): normal! \(fixture.command)"
            )
        }
    }

    @Test("Real-world motion boundary corpus agrees with Neovim")
    func neovimMotionBoundaryCorpus() throws {
        guard let nvim = Self.neovimURL else { return }
        let source = "heading words\n\n  indented alpha,beta\nx\na considerably longer final row\n"
        let text = source as NSString
        let indented = text.range(of: "alpha").location + 3
        let final = text.range(of: "considerably").location + 8
        let fixtures: [(cursor: Int, command: String)] = [
            (indented, "1000j"), (indented, "1000k"),
            (0, "1000w"), (final, "1000b"), (0, "1000e"),
            (indented, "$2j"), (indented, "2$"),
            (indented, "+"), (indented, "2+"),
            (indented, "-"), (indented, "2-"),
            (indented, "_"), (indented, "3_"),
            (final, "gg"), (final, "3gg"),
            (0, "G"), (0, "4G"),
            (indented, "{"), (indented, "}"),
            (indented, "2{"), (indented, "2}"),
            (indented, "fb"), (indented, "2fb"),
            (indented + 6, "Fb"), (indented, "tb"),
            (indented, "fb;"), (indented, "fb,"),
        ]
        for fixture in fixtures {
            var heft = VimHarness(source, cursor: fixture.cursor)
            heft.type(fixture.command)
            let oracle = try Self.runNeovimCursor(
                nvim,
                source: source,
                cursor: fixture.cursor,
                command: fixture.command
            )
            #expect(
                heft.selection.location == oracle,
                "Boundary-motion mismatch for normal! \(fixture.command) from \(fixture.cursor)"
            )
        }
    }

    private static var neovimURL: URL? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/nvim" }
        return (pathCandidates + ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/usr/bin/nvim"])
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func runNeovim(_ executable: URL, source: String, command: String) throws -> String {
        try runNeovim(executable, source: source, exCommand: "+normal! \(command)")
    }

    private static func runNeovim(
        _ executable: URL,
        source: String,
        cursor: Int,
        command: String
    ) throws -> String {
        precondition(source.unicodeScalars.allSatisfy { $0.isASCII })
        let bytes = Array(source.utf8)
        let safeCursor = min(max(0, cursor), bytes.count)
        let prefix = bytes[..<safeCursor]
        let line = prefix.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let lastNewline = prefix.lastIndex(of: 10)
        let byteColumn = safeCursor - ((lastNewline.map { $0 + 1 }) ?? 0)
        return try runNeovim(
            executable,
            source: source,
            exCommand: "+call cursor(\(line),\(byteColumn + 1))",
            additionalCommand: "+normal! \(command)"
        )
    }

    private static func runNeovim(
        _ executable: URL,
        source: String,
        exCommand: String,
        additionalCommand: String? = nil
    ) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-vim-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data(source.utf8).write(to: file)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--clean", "--headless", "-n", file.path, exCommand]
            + (additionalCommand.map { [$0] } ?? [])
            + ["+write", "+quit"]
        var environment = ProcessInfo.processInfo.environment
        environment["NVIM_LOG_FILE"] = directory.appendingPathComponent("nvim.log").path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw VimOracleError.failed(diagnostic)
        }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    private static func runNeovimCursor(
        _ executable: URL,
        source: String,
        cursor: Int,
        command: String
    ) throws -> Int {
        precondition(source.unicodeScalars.allSatisfy { $0.isASCII })
        let bytes = Array(source.utf8)
        let safeCursor = min(max(0, cursor), bytes.count)
        let prefix = bytes[..<safeCursor]
        let line = prefix.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let lastNewline = prefix.lastIndex(of: 10)
        let byteColumn = safeCursor - ((lastNewline.map { $0 + 1 }) ?? 0)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-vim-cursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        let stateFile = directory.appendingPathComponent("state.json")
        try Data(source.utf8).write(to: file)

        let lua = "lua local c=vim.api.nvim_win_get_cursor(0); "
            + "vim.fn.writefile({vim.fn.json_encode({line=c[1],column=c[2]})}, "
            + "'\(stateFile.path)')"
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--clean", "--headless", "-n", file.path,
            "+call cursor(\(line),\(byteColumn + 1))",
            "+normal! \(command)", "+\(lua)", "+quit!",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["NVIM_LOG_FILE"] = directory.appendingPathComponent("nvim.log").path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw VimOracleError.failed(diagnostic) }

        let state = try JSONDecoder().decode(
            NeovimCursorState.self,
            from: Data(contentsOf: stateFile)
        )
        let starts = source.utf8.indices.reduce(into: [0]) { result, index in
            if source.utf8[index] == 10 { result.append(source.utf8.distance(from: source.utf8.startIndex, to: index) + 1) }
        }
        guard state.line > 0, state.line <= starts.count else {
            throw VimOracleError.failed("Neovim returned invalid cursor line \(state.line)")
        }
        return starts[state.line - 1] + state.column
    }

    @MainActor
    private static func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw VimOracleError.eventCreationFailed }
        return event
    }
}

private enum VimOracleError: Error {
    case failed(String)
    case eventCreationFailed
}

private struct NeovimCursorState: Decodable {
    let line: Int
    let column: Int
}
