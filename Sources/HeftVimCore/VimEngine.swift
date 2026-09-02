import Foundation

public struct VimEngine: Sendable {
    private enum Operator: Character, Sendable { case delete = "d", change = "c", yank = "y" }
    private struct Find: Sendable {
        var character: String
        var forward: Bool
        var till: Bool
    }

    public private(set) var mode: VimMode = .normal
    public private(set) var unnamedRegister = VimRegister()

    public var isAwaitingMoreKeys: Bool {
        count != nil
            || pendingOperator != nil
            || pendingPrefix != nil
            || pendingFind != nil
            || pendingTextObjectAround != nil
            || pendingReplacementCount != nil
    }

    private var count: Int?
    private var pendingOperator: Operator?
    private var operatorCount = 1
    private var pendingPrefix: Character?
    private var pendingFind: (forward: Bool, till: Bool)?
    private var pendingTextObjectAround: Bool?
    private var pendingReplacementCount: Int?
    private var lastFind: Find?
    private var visualAnchor: Int?
    private var visualCursor: Int?
    private var preferredColumn: Int?
    private var searchBackward = false
    private var blockInsertLocations: [Int] = []

    public init() {}

    public mutating func reset(mode: VimMode = .normal) {
        self.mode = mode
        count = nil
        pendingOperator = nil
        operatorCount = 1
        pendingPrefix = nil
        pendingFind = nil
        pendingTextObjectAround = nil
        pendingReplacementCount = nil
        visualAnchor = nil
        visualCursor = nil
        preferredColumn = nil
        blockInsertLocations = []
    }

    /// Synchronizes a selection created by the host's mouse handling with the
    /// modal state machine. AppKit owns hit-testing; Vim owns what subsequent
    /// operator keys do with the resulting characterwise selection.
    public mutating func adoptVisualSelection(_ selection: NSRange, in source: String) {
        reset()
        let text = VimText(source)
        guard selection.length > 0, text.length > 0 else { return }
        mode = .visual
        visualAnchor = text.clampedCursor(selection.location)
        visualCursor = text.previousCharacter(
            from: min(NSMaxRange(selection), text.length)
        )
    }

    public mutating func handle(_ key: VimKey, in snapshot: VimSnapshot) -> VimOutput {
        if key == .escape { return escape(in: snapshot) }
        if key == .control("c") || key == .control("[") { return escape(in: snapshot) }
        if mode == .insert {
            return VimOutput(consumed: false, mode: mode)
        }

        let text = VimText(snapshot.text)
        let rawCursor = (mode == .visual || mode == .visualLine || mode == .visualBlock)
            ? (visualCursor ?? snapshot.selection.location)
            : snapshot.selection.location
        let keepsInsertionEndpoint = mode == .replace
            || (mode == .visual && (rawCursor == text.length || text.isNewline(at: rawCursor)))
        let cursor = keepsInsertionEndpoint
            ? text.clampedInsertion(rawCursor)
            : text.clampedCursor(rawCursor)

        if mode == .blockInsert {
            guard case let .character(value) = key, !value.isEmpty else {
                return VimOutput(consumed: false, mode: mode)
            }
            let insertedLength = (value as NSString).length
            let edits = blockInsertLocations.map {
                VimEdit(range: NSRange(location: $0, length: 0), replacement: value)
            }
            blockInsertLocations = blockInsertLocations.enumerated().map { index, location in
                location + insertedLength * (index + 1)
            }
            return VimOutput(
                consumed: true,
                mode: mode,
                edits: edits,
                selection: blockInsertLocations.first.map { NSRange(location: $0, length: 0) },
                selections: blockInsertLocations.map { NSRange(location: $0, length: 0) }
            )
        }

        if mode == .replace {
            if case let .character(value) = key, !value.isEmpty {
                let range = cursor < NSMaxRange(text.lineContentRange(at: cursor))
                    ? text.composedRange(at: cursor)
                    : NSRange(location: cursor, length: 0)
                return output(
                    edits: [VimEdit(range: range, replacement: value)],
                    selection: cursor + (value as NSString).length
                )
            }
            return VimOutput(consumed: false, mode: mode)
        }

        if let repetitions = pendingReplacementCount {
            pendingReplacementCount = nil
            guard case let .character(replacement) = key, !replacement.isEmpty else {
                return output(selection: cursor, message: "replace cancelled")
            }
            var end = cursor
            for _ in 0..<repetitions { end = min(NSMaxRange(text.lineContentRange(at: cursor)), text.nextCharacter(from: end)) }
            guard end > cursor else { return output(selection: cursor) }
            let value = String(repeating: replacement, count: repetitions)
            clearCommand()
            return output(edits: [VimEdit(range: NSRange(location: cursor, length: end - cursor), replacement: value)], selection: cursor + max(0, (value as NSString).length - (replacement as NSString).length))
        }

        if let around = pendingTextObjectAround {
            pendingTextObjectAround = nil
            guard case let .character(value) = key, value.count == 1,
                  let object = value.first,
                  let range = textObject(object, around: around, text: text, cursor: cursor)
            else {
                clearCommand()
                return output(selection: cursor, message: "text object not found")
            }
            if let op = pendingOperator {
                return apply(op, range: range, linewise: false, text: text)
            }
            if mode == .visual || mode == .visualLine {
                guard range.length > 0 else {
                    return visualOutput(cursor: cursor, text: text)
                }
                mode = .visual
                visualAnchor = range.location
                visualCursor = text.previousCharacter(from: NSMaxRange(range))
                clearCommand(keepMode: true)
                return visualOutput(cursor: visualCursor ?? range.location, text: text)
            }
            clearCommand()
            return output(selection: cursor, message: "text object cancelled")
        }

        if let find = pendingFind {
            pendingFind = nil
            guard case let .character(character) = key, !character.isEmpty else {
                return output(selection: cursor, message: "find cancelled")
            }
            let command = Find(character: character, forward: find.forward, till: find.till)
            lastFind = command
            return performFind(command, text: text, cursor: cursor)
        }

        guard let character = character(for: key) else {
            return handleSpecial(key, text: text, cursor: cursor)
        }

        if character.isNumber, acceptCountDigit(character) {
            return output(selection: selection(for: cursor, text: text))
        }

        if let prefix = pendingPrefix {
            pendingPrefix = nil
            if (prefix == ">" || prefix == "<"), character == prefix {
                return shiftLines(
                    right: prefix == ">",
                    count: takeCount(default: 1),
                    text: text,
                    cursor: cursor
                )
            }
            if prefix == "g", character == "g" {
                let target = lineTarget(
                    text: text,
                    lineNumber: takeCount(default: 1),
                    column: text.column(at: cursor)
                )
                return finishMotion(VimMotionResult(target: target, kind: .linewise), text: text, cursor: cursor)
            }
            if prefix == "z" {
                clearCommand()
                switch character {
                case "z": return host(.scrollCenter, cursor: cursor)
                case "t": return host(.scrollTop, cursor: cursor)
                case "b": return host(.scrollBottom, cursor: cursor)
                default: return output(selection: cursor, message: "unknown command")
                }
            }
            clearCommand()
            return output(selection: selection(for: cursor, text: text), message: "unknown command")
        }

        if let op = pendingOperator {
            if character == op.rawValue {
                let total = operatorCount * takeCount(default: 1)
                return applyLineOperator(op, count: total, text: text, cursor: cursor)
            }
            if character == "f" || character == "F" || character == "t" || character == "T" {
                pendingFind = (character == "f" || character == "t", character == "t" || character == "T")
                return output(selection: cursor)
            }
            if character == "i" || character == "a" {
                pendingTextObjectAround = character == "a"
                return output(selection: cursor)
            }
            if character == "g" {
                pendingPrefix = "g"
                return output(selection: cursor)
            }
            if character == "G" {
                return applyOperator(
                    op,
                    motion: VimMotionResult(target: text.lastLineStart(), kind: .linewise),
                    text: text,
                    cursor: cursor
                )
            }
            let motionCount = operatorCount * takeCount(default: 1)
            if var motion = motion(for: character, text: text, cursor: cursor, count: motionCount) {
                // Vim defines `cw` as `ce` on a non-blank, and keeps a one-word
                // `dw` at the end of a line from consuming the newline.
                if (character == "w" || character == "W"), !text.whitespace(at: cursor) {
                    if op == .change {
                        motion = VimMotionResult(
                            target: text.wordEnd(from: cursor, count: motionCount, bigWord: character == "W"),
                            kind: .inclusive
                        )
                    } else if op == .delete, motionCount == 1,
                              motion.target >= NSMaxRange(text.lineRange(at: cursor)) {
                        motion = VimMotionResult(
                            target: text.lastCharacterOfLine(at: cursor), kind: .inclusive
                        )
                    }
                }
                return applyOperator(op, motion: motion, text: text, cursor: cursor)
            }
            clearCommand()
            return output(selection: cursor, message: "operator cancelled")
        }

        if mode == .visual || mode == .visualLine || mode == .visualBlock {
            return handleVisual(character, text: text, cursor: cursor)
        }

        return handleNormal(character, text: text, cursor: cursor)
    }

    private mutating func handleSpecial(_ key: VimKey, text: VimText, cursor: Int) -> VimOutput {
        if case .control("v") = key {
            if mode == .visualBlock { return leaveVisual(cursor: cursor, text: text) }
            return enterVisual(.visualBlock, cursor: cursor, text: text)
        }
        let mapped: Character?
        switch key {
        case .left: mapped = "h"
        case .right: mapped = "l"
        case .up: mapped = "k"
        case .down: mapped = "j"
        case .backspace: mapped = "h"
        case .delete: mapped = "x"
        case .control("r"): return host(.redo, cursor: cursor)
        case .control("f"), .control("d"): return host(.pageDown, cursor: cursor)
        case .control("b"), .control("u"): return host(.pageUp, cursor: cursor)
        case .enter: mapped = "+"
        default: mapped = nil
        }
        guard let mapped else { return output(selection: selection(for: cursor, text: text)) }
        return mode == .visual || mode == .visualLine || mode == .visualBlock
            ? handleVisual(mapped, text: text, cursor: cursor)
            : handleNormal(mapped, text: text, cursor: cursor)
    }

    private mutating func handleNormal(_ command: Character, text: VimText, cursor: Int) -> VimOutput {
        switch command {
        case "i": return enterInsert(at: cursor)
        case "I": return enterInsert(at: text.firstNonblank(at: cursor))
        case "a": return enterInsert(at: text.length == 0 ? 0 : text.nextCharacter(from: cursor))
        case "A": return enterInsert(at: NSMaxRange(text.lineContentRange(at: cursor)))
        case "o", "O": return openLine(below: command == "o", text: text, cursor: cursor)
        case "R":
            mode = .replace
            clearCommand(keepMode: true)
            return output(selection: cursor)
        case "v": return enterVisual(.visual, cursor: cursor, text: text)
        case "V": return enterVisual(.visualLine, cursor: cursor, text: text)
        case "d", "c", "y":
            pendingOperator = Operator(rawValue: command)
            operatorCount = takeCount(default: 1)
            mode = .operatorPending
            return output(selection: cursor)
        case "x": return deleteCharacters(text: text, cursor: cursor, backward: false)
        case "X": return deleteCharacters(text: text, cursor: cursor, backward: true)
        case "s":
            let result = deleteCharacters(text: text, cursor: cursor, backward: false)
            mode = .insert
            return withMode(result)
        case "S":
            return applyLineOperator(
                .change,
                count: takeCount(default: 1),
                text: text,
                cursor: cursor
            )
        case "D": return applyOperator(.delete, motion: VimMotionResult(target: text.lastCharacterOfLine(at: cursor), kind: .inclusive), text: text, cursor: cursor)
        case "C": return applyOperator(.change, motion: VimMotionResult(target: text.lastCharacterOfLine(at: cursor), kind: .inclusive), text: text, cursor: cursor)
        case "Y": return applyLineOperator(.yank, count: takeCount(default: 1), text: text, cursor: cursor)
        case "p", "P": return put(after: command == "p", text: text, cursor: cursor)
        case "r":
            pendingReplacementCount = takeCount(default: 1)
            return output(selection: cursor)
        case "~": return toggleCase(text: text, cursor: cursor)
        case "J": return joinLines(text: text, cursor: cursor)
        case "u": clearCommand(); return host(.undo, cursor: cursor)
        case "/", "?":
            searchBackward = command == "?"
            clearCommand()
            return host(.beginSearch(backward: searchBackward), cursor: cursor)
        case "n", "N":
            clearCommand()
            return host(.nextSearch(backward: command == "N" ? !searchBackward : searchBackward), cursor: cursor)
        case "*", "#":
            guard text.isKeyword(at: cursor),
                  let range = text.wordObject(at: cursor, bigWord: false, around: false)
            else {
                clearCommand()
                return output(selection: cursor, message: "no word under cursor")
            }
            searchBackward = command == "#"
            let query = text.value.substring(with: range)
            clearCommand()
            return host(
                .searchWord(query: query, backward: searchBackward, origin: cursor),
                cursor: cursor
            )
        case "g": pendingPrefix = "g"; return output(selection: cursor)
        case "G":
            let column = text.column(at: cursor)
            let target = count.map {
                lineTarget(text: text, lineNumber: $0, column: column)
            } ?? location(onLineAt: text.lastLineStart(), column: column, text: text)
            clearCommand()
            return output(selection: target)
        case "f", "F", "t", "T":
            pendingFind = (command == "f" || command == "t", command == "t" || command == "T")
            return output(selection: cursor)
        case ";", ",":
            guard var find = lastFind else { return output(selection: cursor) }
            if command == "," { find.forward.toggle() }
            return performFind(find, text: text, cursor: cursor)
        case "z": pendingPrefix = "z"; return output(selection: cursor)
        case ">", "<": pendingPrefix = command; return output(selection: cursor)
        default:
            if let motion = motion(for: command, text: text, cursor: cursor, count: takeCount(default: 1)) {
                let result = finishMotion(motion, text: text, cursor: cursor)
                // Vim remembers `$` as an unbounded desired column: later j/k
                // motions continue landing at line ends, even on longer lines.
                if command == "$" { preferredColumn = .max }
                return result
            }
            clearCommand()
            return output(selection: cursor, message: "unknown command")
        }
    }

    private mutating func handleVisual(_ command: Character, text: VimText, cursor: Int) -> VimOutput {
        switch command {
        case "I" where mode == .visualBlock:
            return enterBlockInsert(text: text, cursor: cursor)
        case "i" where mode != .visualBlock, "a" where mode != .visualBlock:
            pendingTextObjectAround = command == "a"
            return visualOutput(cursor: cursor, text: text)
        case "v":
            if mode == .visual { return leaveVisual(cursor: cursor, text: text) }
            mode = .visual
            return output(selection: visualSelection(cursor: cursor, text: text))
        case "V":
            mode = mode == .visualLine ? .normal : .visualLine
            if mode == .normal { return leaveVisual(cursor: cursor, text: text) }
            return output(selection: visualSelection(cursor: cursor, text: text))
        case "d", "D", "x", "c", "C", "y", "Y":
            let op: Operator = (command == "y" || command == "Y")
                ? .yank
                : ((command == "c" || command == "C") ? .change : .delete)
            return mode == .visualBlock
                ? applyBlockOperator(op, text: text, cursor: cursor)
                : applyVisualOperator(op, text: text, cursor: cursor)
        case "p", "P":
            return putOverVisualSelection(text: text, cursor: cursor)
        case "f", "F", "t", "T":
            pendingFind = (command == "f" || command == "t", command == "t" || command == "T")
            return visualOutput(cursor: cursor, text: text)
        case ";", ",":
            guard var find = lastFind else {
                return visualOutput(cursor: cursor, text: text)
            }
            if command == "," { find.forward.toggle() }
            return performFind(find, text: text, cursor: cursor)
        case "o":
            let oldAnchor = visualAnchor ?? cursor
            visualAnchor = cursor
            visualCursor = oldAnchor
            return visualOutput(cursor: oldAnchor, text: text)
        case ">", "<":
            return shiftVisualLines(right: command == ">", text: text, cursor: cursor)
        case "$":
            // Characterwise Visual `$` includes the line break when one is
            // present. A Normal-mode `$` stops on the final visible character.
            let content = text.lineContentRange(at: cursor)
            let line = text.lineRange(at: cursor)
            let target = NSMaxRange(content) < NSMaxRange(line)
                ? NSMaxRange(content)
                : text.lastCharacterOfLine(at: cursor)
            preferredColumn = .max
            visualCursor = target
            return visualOutput(cursor: target, text: text)
        default:
            if let motion = motion(for: command, text: text, cursor: cursor, count: takeCount(default: 1)) {
                return finishMotion(motion, text: text, cursor: cursor)
            }
            clearCommand(keepMode: true)
            var result = visualOutput(cursor: cursor, text: text)
            result.message = "unknown command"
            return result
        }
    }

    private func motion(for command: Character, text: VimText, cursor: Int, count: Int) -> VimMotionResult? {
        let count = max(1, count)
        switch command {
        case "h":
            var p = cursor
            for _ in 0..<count { p = max(text.lineContentRange(at: p).location, text.previousCharacter(from: p)) }
            return VimMotionResult(target: p, kind: .exclusive)
        case "l", " ":
            var p = cursor
            for _ in 0..<count { p = min(text.lastCharacterOfLine(at: p), text.nextCharacter(from: p)) }
            return VimMotionResult(target: p, kind: .exclusive)
        case "j", "k": return VimMotionResult(target: text.vertical(from: cursor, delta: command == "j" ? count : -count, preferredColumn: preferredColumn), kind: .linewise)
        case "+", "-", "_":
            let delta = command == "+" ? count : (command == "_" ? count - 1 : -count)
            let line = text.lineStart(from: cursor, offset: delta)
            return VimMotionResult(target: text.firstNonblank(at: line), kind: .linewise)
        case "w", "W": return VimMotionResult(target: text.wordForward(from: cursor, count: count, bigWord: command == "W"), kind: .exclusive)
        case "b", "B": return VimMotionResult(target: text.wordBackward(from: cursor, count: count, bigWord: command == "B"), kind: .exclusive)
        case "e", "E": return VimMotionResult(target: text.wordEnd(from: cursor, count: count, bigWord: command == "E"), kind: .inclusive)
        case "0": return VimMotionResult(target: text.lineContentRange(at: cursor).location, kind: .exclusive)
        case "^": return VimMotionResult(target: text.firstNonblank(at: cursor), kind: .exclusive)
        case "$":
            var target = cursor
            for _ in 1..<count { target = text.lineStart(from: target, offset: 1) }
            return VimMotionResult(target: text.lastCharacterOfLine(at: target), kind: .inclusive)
        case "{", "}": return VimMotionResult(target: text.paragraph(from: cursor, forward: command == "}", count: count), kind: .exclusive)
        case "%": return text.matchingBracket(from: cursor).map { VimMotionResult(target: $0, kind: .inclusive) }
        default: return nil
        }
    }

    private mutating func finishMotion(_ motion: VimMotionResult, text: VimText, cursor: Int) -> VimOutput {
        if let op = pendingOperator { return applyOperator(op, motion: motion, text: text, cursor: cursor) }
        let target = text.clampedCursor(motion.target)
        if mode == .visual || mode == .visualLine || mode == .visualBlock {
            preferredColumn = nil
            visualCursor = target
            return visualOutput(cursor: target, text: text)
        }
        preferredColumn = (motion.kind == .linewise) ? (preferredColumn ?? text.column(at: cursor)) : nil
        clearCommand()
        return output(selection: target)
    }

    private mutating func applyOperator(_ op: Operator, motion: VimMotionResult, text: VimText, cursor: Int) -> VimOutput {
        let range = operatorRange(motion: motion, text: text, cursor: cursor)
        return apply(op, range: range, linewise: motion.kind == .linewise, text: text)
    }

    private mutating func applyLineOperator(_ op: Operator, count: Int, text: VimText, cursor: Int) -> VimOutput {
        var endLine = text.lineRange(at: cursor)
        for _ in 1..<max(1, count) {
            let next = NSMaxRange(endLine)
            guard next < text.length else { break }
            endLine = text.lineRange(at: next)
        }
        let start = text.lineRange(at: cursor).location
        return apply(op, range: NSRange(location: start, length: NSMaxRange(endLine) - start), linewise: true, text: text)
    }

    private mutating func applyVisualOperator(_ op: Operator, text: VimText, cursor: Int) -> VimOutput {
        let range = visualRange(cursor: cursor, text: text)
        return apply(op, range: range, linewise: mode == .visualLine, text: text)
    }

    private mutating func applyBlockOperator(_ op: Operator, text: VimText, cursor: Int) -> VimOutput {
        let ranges = visualBlockRanges(cursor: cursor, text: text)
        guard !ranges.isEmpty else { return leaveVisual(cursor: cursor, text: text) }
        unnamedRegister = VimRegister(
            text: ranges.map { text.value.substring(with: $0) }.joined(separator: "\n"),
            linewise: false
        )
        let location = ranges[0].location
        visualAnchor = nil
        visualCursor = nil
        clearCommand()
        if op == .yank {
            mode = .normal
            return output(selection: location)
        }
        mode = op == .change ? .blockInsert : .normal
        if op == .change {
            var removedBefore = 0
            blockInsertLocations = ranges.map { range in
                defer { removedBefore += range.length }
                return range.location - removedBefore
            }
        }
        return VimOutput(
            consumed: true,
            mode: mode,
            edits: ranges.map { VimEdit(range: $0, replacement: "") },
            selection: NSRange(location: location, length: 0),
            selections: mode == .blockInsert
                ? blockInsertLocations.map { NSRange(location: $0, length: 0) }
                : nil
        )
    }

    private mutating func apply(_ op: Operator, range: NSRange, linewise: Bool, text: VimText) -> VimOutput {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        unnamedRegister = VimRegister(text: text.value.substring(with: safe), linewise: linewise)
        let location = safe.location
        clearCommand()
        visualAnchor = nil
        visualCursor = nil
        if op == .yank {
            mode = .normal
            return output(selection: text.clampedCursor(location))
        }
        mode = op == .change ? .insert : .normal
        if op == .change, linewise {
            let removed = text.value.substring(with: safe)
            let indent = String(removed.prefix { $0 == " " || $0 == "\t" })
            let replacement = removed.hasSuffix("\n") ? indent + "\n" : indent
            return output(
                edits: [VimEdit(range: safe, replacement: replacement)],
                selection: location + (indent as NSString).length
            )
        }
        return output(edits: [VimEdit(range: safe, replacement: "")], selection: location)
    }

    private func operatorRange(motion: VimMotionResult, text: VimText, cursor: Int) -> NSRange {
        if motion.kind == .linewise {
            let a = text.lineRange(at: cursor)
            let b = text.lineRange(at: motion.target)
            let start = min(a.location, b.location)
            return NSRange(location: start, length: max(NSMaxRange(a), NSMaxRange(b)) - start)
        }
        let start = min(cursor, motion.target)
        var end = max(cursor, motion.target)
        // An exclusive forward motion landing at the start of another line
        // excludes the intervening newline in Vim. Without this, counted word
        // yanks such as `2yw` unexpectedly become newline-containing puts.
        let targetLine = text.lineContentRange(at: motion.target)
        if motion.kind == .exclusive, motion.target > cursor,
           motion.target == text.firstNonblank(at: motion.target),
           targetLine.location > 0 {
            end = text.previousCharacter(from: targetLine.location)
        }
        if motion.kind == .inclusive { end = text.nextCharacter(from: end) }
        return NSRange(location: start, length: max(0, end - start))
    }

    private mutating func deleteCharacters(text: VimText, cursor: Int, backward: Bool) -> VimOutput {
        let repetitions = takeCount(default: 1)
        var start = cursor
        var end = cursor
        if backward {
            for _ in 0..<repetitions { start = max(text.lineContentRange(at: cursor).location, text.previousCharacter(from: start)) }
            end = cursor
        } else {
            end = text.nextCharacter(from: cursor)
            for _ in 1..<repetitions { end = min(NSMaxRange(text.lineContentRange(at: cursor)), text.nextCharacter(from: end)) }
        }
        guard end > start else { return output(selection: cursor) }
        return apply(.delete, range: NSRange(location: start, length: end - start), linewise: false, text: text)
    }

    private mutating func put(after: Bool, text: VimText, cursor: Int) -> VimOutput {
        let register = unnamedRegister
        guard !register.text.isEmpty else { clearCommand(); return output(selection: cursor, message: "register is empty") }
        let repetitions = takeCount(default: 1)
        let insertion: Int
        var caret: Int
        var value = String(repeating: register.text, count: repetitions)
        if register.linewise {
            let line = text.lineRange(at: cursor)
            insertion = after ? NSMaxRange(line) : line.location
            if !value.hasSuffix("\n") { value += "\n" }
            let hasLineTerminator = NSMaxRange(text.lineContentRange(at: cursor)) < NSMaxRange(line)
            if after, !hasLineTerminator {
                value = "\n" + value
                caret = insertion + 1
            } else {
                caret = insertion
            }
        } else {
            insertion = after && text.length > 0 ? text.nextCharacter(from: cursor) : cursor
            caret = insertion + max(0, (value as NSString).length - 1)
        }
        clearCommand()
        return output(
            edits: [VimEdit(range: NSRange(location: insertion, length: 0), replacement: value)],
            selection: caret
        )
    }

    private mutating func putOverVisualSelection(text: VimText, cursor: Int) -> VimOutput {
        guard mode != .visualBlock else {
            var result = visualOutput(cursor: cursor, text: text)
            result.message = "block put is not supported yet"
            return result
        }
        let range = visualRange(cursor: cursor, text: text)
        let replacement = unnamedRegister
        guard !replacement.text.isEmpty else {
            return leaveVisual(cursor: cursor, text: text)
        }
        let removed = text.value.substring(with: range)
        let removedWasLinewise = mode == .visualLine
        visualAnchor = nil
        visualCursor = nil
        mode = .normal
        clearCommand(keepMode: true)
        unnamedRegister = VimRegister(text: removed, linewise: removedWasLinewise)
        return output(
            edits: [VimEdit(range: range, replacement: replacement.text)],
            selection: range.location + (replacement.linewise
                ? 0
                : max(0, (replacement.text as NSString).length - 1))
        )
    }

    private mutating func openLine(below: Bool, text: VimText, cursor: Int) -> VimOutput {
        let line = text.lineRange(at: cursor)
        let content = text.lineContentRange(at: cursor)
        let source = text.value.substring(with: content)
        let indent = String(source.prefix { $0 == " " || $0 == "\t" })
        let hasTerminator = NSMaxRange(content) < NSMaxRange(line)
        let insertion = below ? NSMaxRange(line) : line.location
        let replacement = below
            ? (hasTerminator ? indent + "\n" : "\n" + indent)
            : indent + "\n"
        mode = .insert
        clearCommand(keepMode: true)
        let caret = below && !hasTerminator
            ? insertion + 1 + (indent as NSString).length
            : insertion + (indent as NSString).length
        return output(edits: [VimEdit(range: NSRange(location: insertion, length: 0), replacement: replacement)], selection: caret)
    }

    private mutating func performFind(_ find: Find, text: VimText, cursor: Int) -> VimOutput {
        let repetitions = (pendingOperator == nil ? 1 : operatorCount) * takeCount(default: 1)
        guard let target = text.find(character: find.character, from: cursor, forward: find.forward, till: find.till, count: repetitions) else {
            return output(selection: selection(for: cursor, text: text), message: "character not found")
        }
        // For operators, forward f/t include the character they land on;
        // backward F/T exclude the original cursor while including the target.
        let motion = VimMotionResult(
            target: target,
            kind: find.forward ? .inclusive : .exclusive
        )
        return finishMotion(motion, text: text, cursor: cursor)
    }

    private mutating func enterInsert(at location: Int) -> VimOutput {
        mode = .insert
        clearCommand(keepMode: true)
        return output(selection: location)
    }

    private mutating func enterVisual(_ newMode: VimMode, cursor: Int, text: VimText) -> VimOutput {
        clearCommand()
        mode = newMode
        visualAnchor = cursor
        visualCursor = cursor
        return visualOutput(cursor: cursor, text: text)
    }

    private mutating func enterBlockInsert(text: VimText, cursor: Int) -> VimOutput {
        blockInsertLocations = visualBlockRanges(cursor: cursor, text: text).map(\.location)
        visualAnchor = nil
        visualCursor = nil
        mode = .blockInsert
        clearCommand(keepMode: true)
        return VimOutput(
            consumed: true,
            mode: mode,
            selection: blockInsertLocations.first.map { NSRange(location: $0, length: 0) },
            selections: blockInsertLocations.map { NSRange(location: $0, length: 0) }
        )
    }

    private mutating func leaveVisual(cursor: Int, text: VimText) -> VimOutput {
        visualAnchor = nil
        visualCursor = nil
        mode = .normal
        clearCommand(keepMode: true)
        return output(selection: text.clampedCursor(cursor))
    }

    private mutating func escape(in snapshot: VimSnapshot) -> VimOutput {
        let text = VimText(snapshot.text)
        var cursor = snapshot.selection.location
        if (mode == .insert || mode == .replace || mode == .blockInsert), cursor > 0 {
            cursor = text.previousCharacter(from: cursor)
        }
        if mode == .visual || mode == .visualLine || mode == .visualBlock {
            cursor = visualAnchor ?? cursor
        }
        reset()
        return output(selection: text.clampedCursor(cursor))
    }

    private func visualRange(cursor: Int, text: VimText) -> NSRange {
        let anchor = visualAnchor ?? cursor
        if mode == .visualLine {
            let a = text.lineRange(at: anchor), b = text.lineRange(at: cursor)
            let start = min(a.location, b.location)
            return NSRange(location: start, length: max(NSMaxRange(a), NSMaxRange(b)) - start)
        }
        let start = min(anchor, cursor)
        let end = text.nextCharacter(from: max(anchor, cursor))
        return NSRange(location: start, length: end - start)
    }

    private func visualSelection(cursor: Int, text: VimText) -> NSRange { visualRange(cursor: cursor, text: text) }

    private func selection(for cursor: Int, text: VimText) -> NSRange {
        mode == .visual || mode == .visualLine
            ? visualSelection(cursor: cursor, text: text)
            : NSRange(location: cursor, length: 0)
    }

    private func visualBlockRanges(cursor: Int, text: VimText) -> [NSRange] {
        let anchor = visualAnchor ?? cursor
        let anchorLine = text.lineRange(at: anchor)
        let cursorLine = text.lineRange(at: cursor)
        let top = min(anchorLine.location, cursorLine.location)
        let bottom = max(anchorLine.location, cursorLine.location)
        let firstColumn = min(text.column(at: anchor), text.column(at: cursor))
        let lastColumn = max(text.column(at: anchor), text.column(at: cursor))
        var ranges: [NSRange] = []
        var lineStart = top
        while lineStart <= bottom {
            let content = text.lineContentRange(at: lineStart)
            if content.length > 0, firstColumn < content.length {
                let start = text.clampedCursor(content.location + firstColumn)
                let desiredEnd = min(content.location + lastColumn, NSMaxRange(content) - 1)
                let end = text.nextCharacter(from: text.clampedCursor(desiredEnd))
                ranges.append(NSRange(location: start, length: end - start))
            }
            let next = NSMaxRange(text.lineRange(at: lineStart))
            guard next > lineStart, next < text.length, next <= bottom else { break }
            lineStart = next
        }
        return ranges
    }

    private func visualOutput(cursor: Int, text: VimText) -> VimOutput {
        if mode == .visualBlock {
            let ranges = visualBlockRanges(cursor: cursor, text: text)
            return VimOutput(
                consumed: true,
                mode: mode,
                selection: ranges.first,
                selections: ranges
            )
        }
        return output(selection: visualSelection(cursor: cursor, text: text))
    }

    private mutating func acceptCountDigit(_ digit: Character) -> Bool {
        guard let value = digit.wholeNumberValue else { return false }
        if value == 0, count == nil { return false }
        count = min(999_999, (count ?? 0) * 10 + value)
        return true
    }

    private mutating func takeCount(default defaultValue: Int) -> Int {
        defer { count = nil }
        return count ?? defaultValue
    }

    private mutating func clearCommand(keepMode: Bool = false) {
        count = nil
        pendingOperator = nil
        operatorCount = 1
        pendingPrefix = nil
        pendingFind = nil
        pendingTextObjectAround = nil
        if !keepMode, mode == .operatorPending { mode = .normal }
    }

    private mutating func host(_ action: VimHostAction, cursor: Int) -> VimOutput {
        clearCommand()
        return output(selection: cursor, hostAction: action)
    }

    private mutating func withMode(_ value: VimOutput) -> VimOutput {
        var copy = value
        copy.mode = mode
        return copy
    }

    private func character(for key: VimKey) -> Character? {
        guard case let .character(value) = key, value.count == 1 else { return nil }
        return value.first
    }

    private func lineTarget(text: VimText, lineNumber: Int, column: Int) -> Int {
        var location = 0
        for _ in 1..<max(1, lineNumber) {
            let next = NSMaxRange(text.lineRange(at: location))
            if next >= text.length { break }
            location = next
        }
        return self.location(onLineAt: location, column: column, text: text)
    }

    private func location(onLineAt lineLocation: Int, column: Int, text: VimText) -> Int {
        let content = text.lineContentRange(at: lineLocation)
        guard content.length > 0 else { return content.location }
        return text.clampedCursor(min(content.location + column, NSMaxRange(content) - 1))
    }

    private func textObject(_ object: Character, around: Bool, text: VimText, cursor: Int) -> NSRange? {
        switch object {
        case "w": return text.wordObject(at: cursor, bigWord: false, around: around)
        case "W": return text.wordObject(at: cursor, bigWord: true, around: around)
        case "\"", "'", "`": return text.delimitedObject(at: cursor, opening: object, closing: object, around: around)
        case "(", ")", "b": return text.delimitedObject(at: cursor, opening: "(", closing: ")", around: around)
        case "[", "]": return text.delimitedObject(at: cursor, opening: "[", closing: "]", around: around)
        case "{", "}", "B": return text.delimitedObject(at: cursor, opening: "{", closing: "}", around: around)
        case "<", ">": return text.delimitedObject(at: cursor, opening: "<", closing: ">", around: around)
        default: return nil
        }
    }

    private mutating func toggleCase(text: VimText, cursor: Int) -> VimOutput {
        let repetitions = takeCount(default: 1)
        var end = cursor
        var replacement = ""
        for _ in 0..<repetitions {
            guard end < NSMaxRange(text.lineContentRange(at: cursor)) else { break }
            let range = text.composedRange(at: end)
            let value = text.value.substring(with: range)
            replacement += value == value.uppercased() ? value.lowercased() : value.uppercased()
            end = NSMaxRange(range)
        }
        guard end > cursor else { return output(selection: cursor) }
        clearCommand()
        return output(
            edits: [VimEdit(range: NSRange(location: cursor, length: end - cursor), replacement: replacement)],
            selection: min(max(0, text.length - 1), end)
        )
    }

    private mutating func joinLines(text: VimText, cursor: Int) -> VimOutput {
        let repetitions = max(2, takeCount(default: 2)) - 1
        var edits: [VimEdit] = []
        var line = text.lineRange(at: cursor)
        for _ in 0..<repetitions {
            let content = text.lineContentRange(at: line.location)
            let nextStart = NSMaxRange(line)
            guard nextStart < text.length else { break }
            let nextContent = text.lineContentRange(at: nextStart)
            var firstNonblank = nextContent.location
            while firstNonblank < NSMaxRange(nextContent) {
                let c = text.value.character(at: firstNonblank)
                if c != 32 && c != 9 { break }
                firstNonblank = text.nextCharacter(from: firstNonblank)
            }
            let replacement = content.length == 0 || nextContent.length == 0 ? "" : " "
            edits.append(VimEdit(
                range: NSRange(location: NSMaxRange(content), length: firstNonblank - NSMaxRange(content)),
                replacement: replacement
            ))
            line = text.lineRange(at: nextStart)
        }
        clearCommand()
        return output(edits: edits, selection: text.lastCharacterOfLine(at: cursor))
    }

    private mutating func shiftLines(
        right: Bool,
        count: Int,
        text: VimText,
        cursor: Int
    ) -> VimOutput {
        let start = text.lineRange(at: cursor).location
        var endLine = text.lineRange(at: cursor)
        for _ in 1..<max(1, count) {
            let next = NSMaxRange(endLine)
            guard next < text.length else { break }
            endLine = text.lineRange(at: next)
        }
        return shiftLineRange(
            right: right,
            start: start,
            end: NSMaxRange(endLine),
            text: text
        )
    }

    private mutating func shiftVisualLines(
        right: Bool,
        text: VimText,
        cursor: Int
    ) -> VimOutput {
        let anchor = visualAnchor ?? cursor
        let first = min(text.lineRange(at: anchor).location, text.lineRange(at: cursor).location)
        let last = max(text.lineRange(at: anchor).location, text.lineRange(at: cursor).location)
        let end = NSMaxRange(text.lineRange(at: last))
        visualAnchor = nil
        visualCursor = nil
        mode = .normal
        return shiftLineRange(right: right, start: first, end: end, text: text)
    }

    private mutating func shiftLineRange(
        right: Bool,
        start: Int,
        end: Int,
        text: VimText
    ) -> VimOutput {
        var edits: [VimEdit] = []
        var lineStart = start
        while lineStart < min(end, text.length) {
            let content = text.lineContentRange(at: lineStart)
            if content.length > 0 {
                if right {
                    edits.append(VimEdit(
                        range: NSRange(location: content.location, length: 0),
                        replacement: "\t"
                    ))
                } else if text.value.character(at: content.location) == 9 {
                    edits.append(VimEdit(
                        range: NSRange(location: content.location, length: 1),
                        replacement: ""
                    ))
                } else {
                    var spaces = 0
                    while spaces < min(4, content.length),
                          text.value.character(at: content.location + spaces) == 32 {
                        spaces += 1
                    }
                    if spaces > 0 {
                        edits.append(VimEdit(
                            range: NSRange(location: content.location, length: spaces),
                            replacement: ""
                        ))
                    }
                }
            }
            let next = NSMaxRange(text.lineRange(at: lineStart))
            guard next > lineStart else { break }
            lineStart = next
        }
        clearCommand()
        mode = .normal
        let firstNonblank = text.firstNonblank(at: start)
        let cursorAdjustment: Int
        if right {
            cursorAdjustment = 1
        } else if firstNonblank > start {
            cursorAdjustment = -min(4, firstNonblank - start)
        } else {
            cursorAdjustment = 0
        }
        return output(edits: edits, selection: max(start, firstNonblank + cursorAdjustment))
    }

    private func output(edits: [VimEdit] = [], selection: Int, hostAction: VimHostAction? = nil, message: String? = nil) -> VimOutput {
        VimOutput(consumed: true, mode: mode, edits: edits, selection: NSRange(location: selection, length: 0), hostAction: hostAction, message: message)
    }

    private func output(edits: [VimEdit] = [], selection: NSRange, hostAction: VimHostAction? = nil, message: String? = nil) -> VimOutput {
        VimOutput(consumed: true, mode: mode, edits: edits, selection: selection, hostAction: hostAction, message: message)
    }
}
