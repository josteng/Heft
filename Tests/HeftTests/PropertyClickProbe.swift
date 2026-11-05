import AppKit
import Foundation
import Testing
@testable import HeftCore
@testable import Heft

/// Real clicks on the properties table: a full `mouseDown`, AppKit's tracking
/// loop and all, on a styled editor in a window, with the release queued
/// first so the loop ends. What a reader's click does, not what a function
/// called by hand does.
@MainActor
@Suite("Property clicks, real", .serialized)
struct PropertyRealClickTests {
    nonisolated static let note = "---\nAuthor: Jane Doe\nEmpty:\ntags:\n  - x\naliases: [A, B]\n---\nBody text.\n"

    /// Hands AppKit's tracking loop the click's release itself, so a real
    /// `mouseDown` ends without anything going through the app's queue.
    final class ClickWindow: NSWindow {
        /// What the tracking loop is handed, in order: a drag on the spot,
        /// as a real click carries, then the release.
        var queued: [NSEvent] = []
        var release: NSEvent? {
            get { queued.last }
            set { queued = newValue.map { up in [Self.drag(like: up), up].compactMap { $0 } } ?? [] }
        }
        static func drag(like up: NSEvent) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: up.locationInWindow, modifierFlags: [],
                timestamp: up.timestamp, windowNumber: up.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 1
            )
        }
        override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?,
                                inMode mode: RunLoop.Mode, dequeue deqFlag: Bool) -> NSEvent? {
            guard let next = queued.first else { return nil }
            if deqFlag { queued.removeFirst() }
            return next
        }
        override func nextEvent(matching mask: NSEvent.EventTypeMask) -> NSEvent? {
            queued.isEmpty ? nil : queued.removeFirst()
        }
    }

    final class Harness {
        let view: HeftTextKit2View
        let window: ClickWindow
        let coordinator: LiveTextEditor.Coordinator

        init(vim: Bool, note: String = PropertyRealClickTests.note, width: CGFloat = 700) {
            _ = NSApplication.shared
            let context = RenderContext(index: .empty, current: nil, vaultRoot: nil)
            let editor = LiveTextEditor(
                text: .constant(note), documentIdentity: "probe.md", generation: 0,
                generationKeepsPosition: false, findSelection: nil, insertion: nil,
                context: context, onAttachment: { _ in nil }, onFollowLink: { _ in }, onVimSearch: { _ in }
            )
            coordinator = LiveTextEditor.Coordinator(editor)
            view = HeftTextKit2View(usingTextLayoutManager: true)
            view.isVerticallyResizable = true
            view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            view.textContainerInset = NSSize(width: 28, height: 28)
            view.textContainer?.size = NSSize(width: width - 56, height: CGFloat.greatestFiniteMagnitude)
            view.textLayoutManager?.delegate = coordinator
            view.delegate = coordinator
            view.string = note
            window = ClickWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeFirstResponder(view)
            if vim {
                view.vimEnabled = true
                view.resetVim()
            }
            view.setSelectedRange(NSRange(location: (note as NSString).range(of: "Body").location, length: 0))
            // As `makeNSView` wires them: a click's end and a needed restyle
            // reach the coordinator, which restyles what a click held back.
            let coordinator = self.coordinator
            let view = self.view
            view.onTrackingEnded = { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.trackingEnded(view)
            }
            view.onNeedsRestyle = { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.restyle(view)
            }
            // Focused, as the editor of a key window is: it reveals the
            // caret's line only then.
            coordinator.focusChanged(true, in: view)
            coordinator.restyle(view)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        /// The drawn row at `lineStart`: its fragment's frame in the view and
        /// where its value column starts.
        func row(_ lineStart: Int) -> (frame: CGRect, column: CGFloat, textX: CGFloat)? {
            guard let manager = view.textLayoutManager, let content = manager.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: lineStart),
                  let fragment = manager.textLayoutFragment(for: location),
                  case .propertyRow(let row)? = view.liveLayout.blocks[lineStart]
            else { return nil }
            var frame = fragment.layoutFragmentFrame
            frame.origin.x += view.textContainerOrigin.x
            frame.origin.y += view.textContainerOrigin.y
            return (frame, frame.minX - row.indent + row.column, frame.minX)
        }

        /// Where the caret is drawn: the insertion indicator TextKit puts up
        /// as a subview, or Vim's block, in view coordinates.
        func drawnCaretX() -> CGFloat? {
            func indicators(in view: NSView) -> [NSView] {
                view.subviews.flatMap { sub -> [NSView] in
                    (String(describing: Swift.type(of: sub)).contains("InsertionIndicator") ? [sub] : []) + indicators(in: sub)
                }
            }
            // A list being edited draws its own caret after its pills.
            if let list = view.listInputCaretRect() { return list.minX }
            if let block = view.vimBlockFrameForTesting { return block.minX }
            if let indicator = indicators(in: view).first(where: { !$0.isHidden }) {
                return indicator.convert(indicator.bounds, to: view).midX
            }
            // Not key, no indicator: the number TextKit places it from.
            return caretX(at: view.selectedRange().location)
        }

        /// Where TextKit puts an insertion point at `location`: its line
        /// fragment's `locationForCharacter`, which the caret is placed from.
        func caretX(at location: Int) -> CGFloat? {
            guard let manager = view.textLayoutManager, let content = manager.textContentManager,
                  let place = content.location(content.documentRange.location, offsetBy: location),
                  let fragment = manager.textLayoutFragment(for: place)
            else { return nil }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let offset = location - start
            guard let line = fragment.textLineFragments.first(where: {
                NSLocationInRange(offset, $0.characterRange) || offset == NSMaxRange($0.characterRange)
            }) else { return nil }
            return fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x
                + line.typographicBounds.minX + line.locationForCharacter(at: offset).x
        }

        /// Where TextKit puts the insertion point at `location`, as a rect
        /// in the view: the selection segment of an empty range, which the
        /// caret is drawn from, height included.
        func caretRect(at location: Int) -> CGRect? {
            guard let manager = view.textLayoutManager, let content = manager.textContentManager,
                  let place = content.location(content.documentRange.location, offsetBy: location),
                  let range = NSTextRange(location: place, end: place)
            else { return nil }
            var found: CGRect?
            manager.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
                found = frame
                return false
            }
            return found.map { $0.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y) }
        }

        /// A full click at `point`, in view coordinates; returns the caret.
        func click(_ point: CGPoint, count: Int = 1) -> NSRange {
            let inWindow = view.convert(point, to: nil)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 0
            )!
            window.release = up
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1
            )!
            view.mouseDown(with: down)
            // What the selection-change path settles once the click is over.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            return view.selectedRange()
        }
    }

}

extension PropertyRealClickTests {
    enum Mode: String, CaseIterable { case plain, normal, insert }

    private func harness(_ mode: Mode, note: String = PropertyRealClickTests.note) async throws -> Harness {
        let harness = Harness(vim: mode != .plain, note: note)
        if mode == .insert { harness.view.enterVimInsertForTesting() }
        try await Task.sleep(for: .milliseconds(30))
        return harness
    }

    /// A click, then the work it leaves for just after it.
    private func click(_ harness: Harness, line: Int, at spot: KeyPath<(frame: CGRect, column: CGFloat, textX: CGFloat), CGFloat>, plus offset: CGFloat) async throws -> (caret: Int, drawn: CGFloat, column: CGFloat) {
        let row = try #require(harness.row(line))
        _ = harness.click(CGPoint(x: row[keyPath: spot] + offset, y: row.frame.minY + 14))
        try await Task.sleep(for: .milliseconds(60))
        return (harness.view.selectedRange().location, try #require(harness.drawnCaretX()), row.column)
    }

    private func type(_ text: String, in harness: Harness, mode: Mode) async throws {
        if mode == .normal {
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
            ))
            harness.view.keyDown(with: key)
        }
        for character in text {
            if character == "\n" { harness.view.insertNewline(nil) }
            else { harness.view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        try await Task.sleep(for: .milliseconds(60))
    }

    private func line(_ harness: Harness, at start: Int) -> String {
        let text = harness.view.string as NSString
        return text.substring(with: text.lineRange(for: NSRange(location: start, length: 0)))
    }

    @Test("A click in the key column stays in the key, drawn there", arguments: Mode.allCases)
    func keyColumn(mode: Mode) async throws {
        for line in [4, 21, 28] {
            let h = try await harness(mode)
            let gap = try await click(h, line: line, at: \.column, plus: -20)
            #expect(gap.drawn < gap.column - 20, "line \(line), \(mode)")
            #expect(self.line(h, at: line).contains(":"))
        }
    }

    @Test("A click on a value lands in it, drawn where it is", arguments: Mode.allCases)
    func valueColumn(mode: Mode) async throws {
        let h = try await harness(mode)
        let hit = try await click(h, line: 4, at: \.column, plus: 12)
        #expect(hit.caret == 14)
        #expect(hit.drawn > hit.column && hit.drawn < hit.column + 40)
    }

    @Test("An empty value takes the caret and the typing at its column, and is left as it was", arguments: Mode.allCases)
    func emptyValue(mode: Mode) async throws {
        let h = try await harness(mode)
        let hit = try await click(h, line: 21, at: \.column, plus: 40)
        #expect(abs(hit.drawn - hit.column) < 8, "drawn at \(hit.drawn), column \(hit.column)")
        try await type("x", in: h, mode: mode)
        #expect(line(h, at: 21) == "Empty: x\n")

        let left = try await harness(mode)
        _ = try await click(left, line: 21, at: \.column, plus: 40)
        _ = try await click(left, line: 4, at: \.column, plus: 12)
        #expect(line(left, at: 21) == "Empty:\n")
    }

    @Test("A list takes the caret after its pills, and Return makes what is typed one", arguments: Mode.allCases)
    func list(mode: Mode) async throws {
        let h = try await harness(mode)
        let hit = try await click(h, line: 28, at: \.column, plus: 60)
        #expect(hit.drawn > hit.column + 20, "drawn at \(hit.drawn), column \(hit.column)")
        try await type("y\n", in: h, mode: mode)
        #expect(h.view.string.contains("\n  - x\n  - y\n"), "\(h.view.string.debugDescription)")
        // Left, the key line is as it was, without the space its input had.
        _ = try await click(h, line: 4, at: \.column, plus: 12)
        #expect(h.view.string.contains("tags:\n  - x\n  - y\n"), "\(h.view.string.debugDescription)")
    }

    @Test("An inline list clicked becomes pills, the caret after them", arguments: Mode.allCases)
    func inlineList(mode: Mode) async throws {
        let h = try await harness(mode)
        let hit = try await click(h, line: 40, at: \.column, plus: 200)
        #expect(h.view.string.contains("aliases: \n  - A\n  - B\n") || h.view.string.contains("aliases:\n  - A\n  - B\n"))
        #expect(hit.drawn > hit.column + 40)
    }

    private static let bareNote = "---\nAuthor: Jane Doe\nasdfas\n---\nBody text.\n"

    @Test("A key with no colon yet: its value column clicked gives it one, and typing goes there", arguments: Mode.allCases)
    func bareKeyValue(mode: Mode) async throws {
        let h = try await harness(mode, note: Self.bareNote)
        let hit = try await click(h, line: 21, at: \.column, plus: 30)
        #expect(line(h, at: 21) == "asdfas: \n")
        #expect(abs(hit.drawn - hit.column) < 8, "drawn at \(hit.drawn), column \(hit.column)")
        try await type("v", in: h, mode: mode)
        #expect(line(h, at: 21) == "asdfas: v\n")
    }

    @Test("A key left without its colon gets one, so the block stays YAML", arguments: Mode.allCases)
    func bareKeyLeft(mode: Mode) async throws {
        let h = try await harness(mode, note: Self.bareNote)
        _ = try await click(h, line: 21, at: \.textX, plus: 6)
        #expect(line(h, at: 21) == "asdfas\n")
        // Into the body, which is not a property row.
        let body = (h.view.string as NSString).range(of: "Body").location
        let place = try #require(h.view.rect(forSelection: NSRange(location: body + 2, length: 1)))
        _ = h.click(CGPoint(x: place.midX, y: place.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(line(h, at: 21) == "asdfas:\n")
    }

    @Test("A click into the body tidies the empty value it left", arguments: Mode.allCases)
    func bodyClickTidies(mode: Mode) async throws {
        let h = try await harness(mode)
        _ = try await click(h, line: 21, at: \.column, plus: 40)
        #expect(line(h, at: 21) == "Empty: \n")
        let body = (h.view.string as NSString).range(of: "Body").location
        let place = try #require(h.view.rect(forSelection: NSRange(location: body + 2, length: 1)))
        _ = h.click(CGPoint(x: place.midX, y: place.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(line(h, at: 21) == "Empty:\n")
    }

    @Test("A list or an empty value is given its place at once, with nothing drawn before it", arguments: Mode.allCases)
    func noCaretInBetween(mode: Mode) async throws {
        for line in [21, 28, 40] {
            let h = try await harness(mode)
            let row = try #require(h.row(line))
            let caret = h.click(CGPoint(x: row.column + 40, y: row.frame.minY + 14))
            // Straight from mouseDown, before anything queued after it ran.
            let immediately = try #require(h.drawnCaretX())
            #expect(immediately > row.column - 8, "line \(line), \(mode): drawn at \(immediately) right after the click, caret \(caret.location)")
        }
    }

    private func focusInKey(_ h: Harness, line: Int) -> Bool? {
        if case .propertyRow(let row)? = h.view.liveLayout.blocks[line] {
            if row.focus == nil { Issue.record("no focus on line \(line), caret \(h.view.selectedRange().location)") }
            return row.focus == nil ? nil : row.focusInKey
        }
        Issue.record("no row at \(line)")
        return nil
    }

    @Test("The shaded cell is the caret's: the key's from a key click, the value's from a value click or a move across", arguments: Mode.allCases)
    func shadedCell(mode: Mode) async throws {
        let h = try await harness(mode)
        _ = try await click(h, line: 4, at: \.textX, plus: 6)
        #expect(focusInKey(h, line: 4) == true)
        _ = try await click(h, line: 4, at: \.column, plus: 12)
        #expect(focusInKey(h, line: 4) == false)
        // Across the gap by key, from the key's end.
        let plain = try await harness(.plain)
        _ = try await click(plain, line: 4, at: \.column, plus: -20)
        #expect(focusInKey(plain, line: 4) == true)
        plain.view.moveRight(nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(plain.view.selectedRange().location == 12)
        #expect(focusInKey(plain, line: 4) == false)
    }

    @Test("Every pill's x removes its item with one click, and the hand shows where it can be clicked", arguments: Mode.allCases)
    func removeByCross(mode: Mode) async throws {
        let h = try await harness(mode)
        let cross = try #require(h.view.propertyTargets().first { $0.target == .removeItem(lineStart: 28, index: 0) })
        #expect(h.view.pointerRects().contains(cross.rect))
        _ = h.click(CGPoint(x: cross.rect.midX, y: cross.rect.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!h.view.string.contains("  - x\n"), "\(h.view.string.debugDescription)")
        // An inline list's x too: it becomes a block list without the item.
        let inline = try #require(h.view.propertyTargets().first { $0.target == .removeItem(lineStart: 34, index: 1) }
            ?? h.view.propertyTargets().first { if case .removeItem(_, 1) = $0.target { return true } else { return false } })
        _ = h.click(CGPoint(x: inline.rect.midX, y: inline.rect.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.view.string.contains("aliases:\n  - A\n---"), "\(h.view.string.debugDescription)")
        #expect(h.view.selectedRange().location > (h.view.string as NSString).range(of: "Body").location - 1)
    }

    private func addProperty(_ h: Harness) async throws {
        let add = try #require(h.view.propertyTargets().first { $0.target == .addProperty })
        _ = h.click(CGPoint(x: add.rect.midX, y: add.rect.midY))
        try await Task.sleep(for: .milliseconds(60))
    }

    private func withKeys(_ h: Harness) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-click-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "---\nPublisher: North Press\nRead: true\n---\n".write(
            to: root.appendingPathComponent("Book.md"), atomically: true, encoding: .utf8
        )
        h.view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Add property after a key typed with no value opens the keys again", arguments: Mode.allCases)
    func addAfterBareKey(mode: Mode) async throws {
        let h = try await harness(mode)
        try withKeys(h)
        try await addProperty(h)
        #expect(!h.view.visibleCompletions.isEmpty)
        try await type("Foo", in: h, mode: mode == .normal ? .insert : mode)
        try await addProperty(h)
        #expect(h.view.string.contains("Foo:\n"), "\(h.view.string.debugDescription)")
        #expect(!h.view.visibleCompletions.isEmpty, "\(h.view.string.debugDescription)")
    }

    @Test("A new row is laid out where its first letter leaves it, caret and all", arguments: Mode.allCases)
    func newRowLayout(mode: Mode) async throws {
        let h = try await harness(mode)
        try await addProperty(h)
        let start = h.view.selectedRange().location
        let empty = try #require(h.row(start)?.frame)
        let emptyCaret = try #require(h.caretRect(at: start))
        try await type("a", in: h, mode: mode == .normal ? .insert : mode)
        h.coordinator.restyle(h.view)
        let typed = try #require(h.row(start)?.frame)
        let typedCaret = try #require(h.caretRect(at: h.view.selectedRange().location))
        // The row, which the outline is drawn from: neither moves nor grows.
        #expect(abs(empty.minY - typed.minY) < 0.5 && abs(empty.height - typed.height) < 0.5, "empty \(empty) typed \(typed)")
        #expect(abs(emptyCaret.midY - typedCaret.midY) < 0.5, "empty \(emptyCaret) typed \(typedCaret)")
        #expect(abs(emptyCaret.height - typedCaret.height) < 0.5, "empty \(emptyCaret) typed \(typedCaret)")
    }

    @Test("Add property with an empty row waiting goes to it, and makes no second", arguments: Mode.allCases)
    func addWithBlankWaiting(mode: Mode) async throws {
        let h = try await harness(mode)
        try withKeys(h)
        try await addProperty(h)
        let once = h.view.string
        try await addProperty(h)
        #expect(h.view.string == once, "\(h.view.string.debugDescription)")
        #expect(!h.view.visibleCompletions.isEmpty)
    }

    @Test("In tags a space ends the tag, and a # is dropped", arguments: Mode.allCases)
    func tagSpace(mode: Mode) async throws {
        let h = try await harness(mode)
        _ = try await click(h, line: 28, at: \.column, plus: 200)
        try await type("#deep work", in: h, mode: mode)
        #expect(h.view.string.contains("  - x\n  - deep\n"), "\(h.view.string.debugDescription)")
        _ = try await click(h, line: 4, at: \.column, plus: 12)
        #expect(h.view.string.contains("  - deep\n  - work\n"), "\(h.view.string.debugDescription)")
    }

    private static let looseNote = "---\nAuthor: Jane Doe\nup:[[Note]]\n---\nBody text.\n"

    @Test("A row left is made YAML: its colon's space, its link quoted", arguments: Mode.allCases)
    func tidyOnLeave(mode: Mode) async throws {
        let h = try await harness(mode, note: Self.looseNote)
        _ = try await click(h, line: 21, at: \.textX, plus: 4)
        _ = try await click(h, line: 4, at: \.column, plus: 12)
        #expect(line(h, at: 21) == "up: \"[[Note]]\"\n", "\(h.view.string.debugDescription)")
    }

    private func rowCount(_ h: Harness) -> Int {
        h.view.liveLayout.blocks.values.filter { if case .propertyRow = $0 { return true } else { return false } }.count
    }

    @Test("The arrow beside Properties shows on hover; a click folds the table to its heading and opens it again", arguments: Mode.allCases)
    func fold(mode: Mode) async throws {
        let h = try await harness(mode)
        h.view.noteIdentity = "fold-\(mode).md"
        HeftTextKit2View.foldedPropertyNotes.remove(h.view.noteIdentity)
        let rects = try #require(h.view.propertiesHeadingRect())
        h.view.updatePropertiesFoldButton(hovering: CGPoint(x: rects.heading.midX, y: rects.heading.midY))
        #expect(!h.view.propertiesFoldButton.isHidden)
        h.view.updatePropertiesFoldButton(hovering: CGPoint(x: rects.heading.midX, y: rects.heading.maxY + 120))
        #expect(h.view.propertiesFoldButton.isHidden)

        let open = rowCount(h)
        #expect(open > 0)
        _ = h.click(CGPoint(x: rects.arrow.midX, y: rects.arrow.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.view.propertiesFolded)
        #expect(rowCount(h) == 0)
        #expect(h.view.string == Self.note, "folding writes nothing")

        // Up from the body into the folded table opens it.
        h.view.moveUp(nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!h.view.propertiesFolded)
        #expect(rowCount(h) == open)
    }

    @Test("Start Folded opens a note folded; the arrow opens it, and that holds for the note")
    func startFolded() async throws {
        let h = try await harness(.plain)
        h.view.noteIdentity = "start-folded.md"
        HeftTextKit2View.foldedPropertyNotes.remove(h.view.noteIdentity)
        let open = rowCount(h)
        h.view.propertiesStartFolded = { true }
        h.coordinator.restyle(h.view)
        #expect(h.view.propertiesFolded)
        #expect(rowCount(h) == 0)
        let rects = try #require(h.view.propertiesHeadingRect())
        _ = h.click(CGPoint(x: rects.arrow.midX, y: rects.arrow.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!h.view.propertiesFolded)
        #expect(rowCount(h) == open)
        #expect(h.view.string == Self.note, "folding writes nothing")
    }

    @Test("Pills wrapped in a narrow window stay under their key's line and above the next row")
    func wrappedPills() async throws {
        let note = "---\naliases:\n  - ama\n  - asf\n  - asfd asfd sdf sadf sdf asdf\n  - one more\nMamba: asf\n---\nBody text.\n"
        let h = Harness(vim: false, note: note, width: 420)
        try await Task.sleep(for: .milliseconds(30))
        guard case .propertyRow(let row)? = h.view.liveLayout.blocks[4], let chips = row.chips else {
            Issue.record("no aliases row")
            return
        }
        #expect((chips.rows.max() ?? 0) >= 1, "the pills wrap at this width")
        let aliases = try #require(h.row(4))
        let next = try #require(h.row((note as NSString).range(of: "Mamba").location))
        let manager = try #require(h.view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: 4))
        let fragment = try #require(manager.textLayoutFragment(for: start))
        let line = try #require(fragment.textLineFragments.first)
        // The key's line at the top of its row, not pushed to its bottom.
        #expect(line.typographicBounds.minY < 12, "key line at \(line.typographicBounds.minY)")
        // The last row of pills ends above the next property.
        let baseline = aliases.frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let pillsBottom = baseline + CGFloat(chips.rows.max() ?? 0) * chips.rowPitch - chips.font.descender
        #expect(pillsBottom <= next.frame.minY + 2, "pills end at \(pillsBottom), next row starts at \(next.frame.minY)")
    }

    @Test("Shown as YAML, the properties go back to the table once the caret leaves them")
    func sourceReturns() async throws {
        let h = try await harness(.plain)
        h.view.noteIdentity = "source-return.md"
        HeftTextKit2View.sourcePropertyNotes.remove(h.view.noteIdentity)
        let source = try #require(h.view.propertyTargets().first { $0.target == .source })
        _ = h.click(CGPoint(x: source.rect.midX, y: source.rect.midY))
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.view.propertiesShownAsText)
        let body = (h.view.string as NSString).range(of: "Body").location
        let place = try #require(h.view.rect(forSelection: NSRange(location: body + 2, length: 1)))
        _ = h.click(CGPoint(x: place.midX, y: place.midY))
        try await Task.sleep(for: .milliseconds(80))
        #expect(!h.view.propertiesShownAsText)
    }

    @Test("The source button shows this note's properties as YAML, and the table again", arguments: Mode.allCases)
    func sourceToggle(mode: Mode) async throws {
        let h = try await harness(mode)
        h.view.noteIdentity = "source-\(mode).md"
        HeftTextKit2View.sourcePropertyNotes.remove(h.view.noteIdentity)
        let source = try #require(h.view.propertyTargets().first { $0.target == .source })
        _ = h.click(CGPoint(x: source.rect.midX, y: source.rect.midY))
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.view.propertiesShownAsText)
        #expect(rowCount(h) == 0)
        #expect(h.view.string == Self.note, "showing the YAML writes nothing")
        // Back from the YAML, by the same button on the fence's line.
        let back = try #require(h.view.propertyTargets().first { $0.target == .source })
        _ = h.click(CGPoint(x: back.rect.midX, y: back.rect.midY))
        try await Task.sleep(for: .milliseconds(80))
        #expect(!h.view.propertiesShownAsText)
        #expect(rowCount(h) > 0)
    }

    private static let brokenNote = "---\ntags:\n  - fine\n  - not fine\nN: 1\nN: 2\n---\nBody text.\n"

    @Test("A broken tag is red on its own pill; a red row's icon tells why on hover")
    func brokenAndTip() async throws {
        let h = try await harness(.plain, note: Self.brokenNote)
        guard case .propertyRow(let tags)? = h.view.liveLayout.blocks[4] else {
            Issue.record("no tags row")
            return
        }
        #expect(tags.chips?.invalid == [1])
        #expect(!tags.warns)
        let icon = try #require(h.view.propertyTargets().first { $0.target == .typeMenu(lineStart: 32) })
        h.view.updatePropertyToolTip(at: CGPoint(x: icon.rect.midX, y: icon.rect.midY))
        #expect(h.view.toolTip?.contains("twice") == true)
        h.view.updatePropertyToolTip(at: CGPoint(x: icon.rect.midX + 300, y: icon.rect.midY))
        #expect(h.view.toolTip == nil)
    }

    @Test("Editing a wrapped list, the typed item and caret are after the last pill, on its row", arguments: Mode.allCases)
    func wrappedListInput(mode: Mode) async throws {
        let note = "---\naliases:\n  - ama\n  - asf\n  - asfd asfd sdf sadf\n  - one more\nMamba: asf\n---\nBody text.\n"
        let h = Harness(vim: mode != .plain, note: note, width: 420)
        if mode == .insert { h.view.enterVimInsertForTesting() }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await click(h, line: 4, at: \.column, plus: 300)
        let first = try #require(h.view.listInputCaretRect())
        guard case .propertyRow(let row)? = h.view.liveLayout.blocks[4], let chips = row.chips, let input = chips.input else {
            Issue.record("no list being edited")
            return
        }
        let lastRow = chips.rows.max() ?? 0
        #expect(lastRow >= 1, "the pills wrap")
        #expect(input.row >= lastRow, "input on the last row or the one after")
        let rowTop = try #require(h.row(4)).frame.minY
        #expect(first.minY > rowTop + chips.rowPitch * CGFloat(lastRow) - 4, "caret on the last row: \(first.minY)")
        try await type("zz", in: h, mode: mode)
        let after = try #require(h.view.listInputCaretRect())
        #expect(after.minX > first.minX + 8, "the caret moves on as the item is typed")
        if case .propertyRow(let typed)? = h.view.liveLayout.blocks[4] {
            #expect(typed.chips?.input?.label.string == "zz")
        }
    }

    @Test("A short list's input is right after its pills, on the first row", arguments: Mode.allCases)
    func shortListInput(mode: Mode) async throws {
        let h = try await harness(mode)
        let hit = try await click(h, line: 28, at: \.column, plus: 200)
        let caret = try #require(h.view.listInputCaretRect())
        guard case .propertyRow(let row)? = h.view.liveLayout.blocks[28], let chips = row.chips else {
            Issue.record("no tags row")
            return
        }
        let pillEnd = hit.column + (chips.x.last ?? 0) + (chips.widths.last ?? 0)
        #expect(caret.minX > pillEnd && caret.minX < pillEnd + 20, "caret at \(caret.minX), pills end \(pillEnd)")
        #expect(chips.input?.row == 0)
    }

    @Test("The typed item on a line of its own is inside the row's outline and room")
    func inputLineInOutline() async throws {
        let note = "---\ntags:\n  - reading\n  - novels\n  - thesis\n  - green\nNext: 1\n---\nBody text.\n"
        // The width where the pills just fill one line, so the input takes
        // the next one.
        var found = false
        for width in stride(from: 900, through: 420, by: -15) {
            let h = Harness(vim: false, note: note, width: CGFloat(width))
            try await Task.sleep(for: .milliseconds(20))
            _ = try await click(h, line: 4, at: \.column, plus: 250)
            guard case .propertyRow(let row)? = h.view.liveLayout.blocks[4], let chips = row.chips, let input = chips.input,
                  (chips.rows.max() ?? 0) == 0, input.row == 1
            else { continue }
            found = true
            #expect(chips.lastLine == 1)
            let rows = PropertyEditing.rows(in: h.view.string)
            guard let caret = h.view.listInputCaretRect() else {
                Issue.record("no list caret: selection \(h.view.selectedRange()), row ends \(rows.map(\.valueEnd)), line \((h.view.string as NSString).substring(with: NSRange(location: 4, length: 8)).debugDescription)")
                break
            }
            let next = try #require(h.row((h.view.string as NSString).range(of: "Next").location))
            #expect(caret.maxY <= next.frame.minY + 2, "the input's line is room the row has, above the next")
            break
        }
        #expect(found, "some width puts the input on a line of its own")
    }

    @Test("The menu follows a list's input at once when a pill goes, not at the next key")
    func menuFollows() async throws {
        let note = "---\ntags:\n  - reading\n  - novels\n---\nBody text.\n"
        let h = Harness(vim: false, note: note)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Some #thesis and #theory notes.\n".write(to: root.appendingPathComponent("N.md"), atomically: true, encoding: .utf8)
        h.view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        try await Task.sleep(for: .milliseconds(30))
        _ = try await click(h, line: 4, at: \.column, plus: 300)
        try await type("th", in: h, mode: .plain)
        let before = try #require(h.view.completionAnchorForTesting, "the tag menu is open")
        // Gone without a click, which closes a menu as any click does: as an
        // undo or a key takes it.
        h.view.removeItem(at: 0, fromListAt: 4)
        try await Task.sleep(for: .milliseconds(80))
        let after = try #require(h.view.completionAnchorForTesting, "still open")
        let caret = try #require(h.view.listInputCaretRect())
        #expect(after.minX < before.minX - 20, "moved left with the pill gone: \(before.minX) to \(after.minX)")
        #expect(abs(after.minX - caret.minX) < 2, "at the input: menu \(after.minX), caret \(caret.minX)")
    }

    @Test("A space typed into a list's item shows at once, the caret after it", arguments: Mode.allCases)
    func spaceInAlias(mode: Mode) async throws {
        let note = "---\naliases:\n  - ama\n---\nBody text.\n"
        let h = Harness(vim: mode != .plain, note: note)
        if mode == .insert { h.view.enterVimInsertForTesting() }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await click(h, line: 4, at: \.column, plus: 300)
        try await type("new", in: h, mode: mode)
        let word = try #require(h.view.listInputCaretRect())
        try await type(" ", in: h, mode: mode == .normal ? .insert : mode)
        guard case .propertyRow(let row)? = h.view.liveLayout.blocks[4] else {
            Issue.record("no aliases row")
            return
        }
        #expect(row.chips?.input?.label.string == "new ")
        let spaced = try #require(h.view.listInputCaretRect())
        #expect(spaced.minX > word.minX + 2, "the caret moved past the space: \(word.minX) to \(spaced.minX)")
    }

    @Test("A pill's band holds the capitals and the descenders, with room on both sides")
    func pillBand() {
        let font = NSFont.systemFont(ofSize: 15)
        let band = HeftLayoutFragment.pillBand(x: 0, width: 40, baseline: 100, font: font)
        let capitalsTop = 100 - font.capHeight
        let descendersBottom = 100 - font.descender
        #expect(band.minY < capitalsTop - 2)
        #expect(band.maxY > descendersBottom + 2)
        // Not the old band, which held the whole ascender and sat high.
        #expect(band.minY > 100 - font.ascender - 1.5)
    }

    private func press(_ key: String, in h: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ))
        h.view.keyDown(with: event)
    }

    @Test("In Normal mode, i on a list's place or an empty value types into the value, not the key")
    func insertWithI() async throws {
        // A list: the typed item after its pills.
        let list = try await harness(.normal)
        _ = try await click(list, line: 28, at: \.column, plus: 200)
        try press("i", in: list)
        try await Task.sleep(for: .milliseconds(40))
        #expect(list.view.listInputCaretRect() != nil, "the caret is the list's, drawn after its pills")
        for character in "zz" { list.view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(list.view.string.contains("tags: zz\n") || list.view.string.contains("tags:zz\n"), "\(list.view.string.debugDescription)")
        #expect(!list.view.string.contains("tagszz"))

        // An empty value.
        let empty = try await harness(.normal)
        _ = try await click(empty, line: 21, at: \.column, plus: 40)
        try press("i", in: empty)
        try await Task.sleep(for: .milliseconds(40))
        let caret = try #require(empty.drawnCaretX())
        let row = try #require(empty.row(21))
        #expect(abs(caret - row.column) < 8, "drawn at the value column: \(caret), column \(row.column)")
        empty.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(60))
        #expect(line(empty, at: 21) == "Empty: x\n", "\(empty.view.string.debugDescription)")
    }

    @Test("A click into a list's input or an empty value opens its suggestions, every time", arguments: [Mode.plain, Mode.insert])
    func clickOpensSuggestions(mode: Mode) async throws {
        let h = try await harness(mode)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nEmpty: kept\n---\nSome #thesis note.\n".write(to: root.appendingPathComponent("N.md"), atomically: true, encoding: .utf8)
        h.view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        func start(of key: String) -> Int { (h.view.string as NSString).range(of: "\n" + key).location + 1 }
        for _ in 0..<2 {
            _ = try await click(h, line: start(of: "tags:"), at: \.column, plus: 200)
            #expect(h.view.visibleCompletions.contains("thesis"), "tags: \(h.view.visibleCompletions)")
            _ = try await click(h, line: start(of: "Empty:"), at: \.column, plus: 40)
            #expect(h.view.visibleCompletions == ["kept"], "empty value: \(h.view.visibleCompletions)")
        }
    }

    @Test("In Normal mode a click opens no menu: its keys are commands")
    func normalClickNoMenu() async throws {
        let h = try await harness(.normal)
        _ = try await click(h, line: 28, at: \.column, plus: 200)
        #expect(h.view.visibleCompletions.isEmpty)
    }

    @Test("A menu of tags is as wide as its tags need, in the properties and the text; a link's keeps its width")
    func menuWidths() async throws {
        let h = try await harness(.plain)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heft-width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Some #thesis and #theory notes.\n".write(to: root.appendingPathComponent("Long Note Name Here.md"), atomically: true, encoding: .utf8)
        h.view.completionIndex = VaultIndex.build(root: VaultScanner.scan(root: root))
        _ = try await click(h, line: 28, at: \.column, plus: 200)
        let properties = try #require(h.view.completionWidthForTesting, "the tags menu is open")
        #expect(properties < WikiCompletionMetrics.width)
        // The list inside is laid out at the panel's width, not the usual one.
        let content = try #require(h.view.completionContentWidthForTesting)
        #expect(abs(content - properties) < 1, "list \(content), panel \(properties)")
        #expect(properties >= WikiCompletionMetrics.narrowest)

        // In the text, after `#`.
        let body = (h.view.string as NSString).range(of: "Body text.").location + 10
        h.view.setSelectedRange(NSRange(location: body, length: 0))
        try await Task.sleep(for: .milliseconds(30))
        for character in " #th" { h.view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        try await Task.sleep(for: .milliseconds(60))
        let text = try #require(h.view.completionWidthForTesting, "the # menu is open: \(h.view.visibleCompletions)")
        #expect(text < WikiCompletionMetrics.width)
        let fitted = WikiCompletionMetrics.width(fitting: [
            WikiCompletionItem(title: "thesis", detail: "1", symbol: "number", destination: "thesis"),
        ])
        #expect(text >= fitted - 1, "wide enough for its rows")

        // A link's menu, for names and folders, keeps the usual width.
        for character in " [[" { h.view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.view.completionWidthForTesting == WikiCompletionMetrics.width)
    }

    private func escape(_ h: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        h.view.keyDown(with: event)
    }

    @Test("Esc in a value stays in the value: a list's place, an empty one, and a value's first letter")
    func escapeStaysInValue() async throws {
        // A list's input, then Esc.
        let list = try await harness(.insert)
        _ = try await click(list, line: 28, at: \.column, plus: 200)
        try escape(list)
        try await Task.sleep(for: .milliseconds(60))
        #expect(list.view.vimMode == .normal)
        #expect(list.view.listInputCaretRect() != nil, "block at the list's input, caret \(list.view.selectedRange().location)")

        // An empty value.
        let empty = try await harness(.insert)
        _ = try await click(empty, line: 21, at: \.column, plus: 40)
        try escape(empty)
        try await Task.sleep(for: .milliseconds(60))
        let row = try #require(empty.row(21))
        let block = try #require(empty.drawnCaretX())
        #expect(abs(block - row.column) < 8, "block at the value column: \(block), column \(row.column)")

        // A value's first letter, Esc from in front of it.
        let value = try await harness(.insert)
        value.view.setSelectedRange(NSRange(location: 12, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        try escape(value)
        try await Task.sleep(for: .milliseconds(60))
        #expect(value.view.selectedRange().location == 12, "on the J of Jane, not the key: \(value.view.selectedRange().location)")
    }

    /// The menu a right-click puts up, caught rather than popped; or the
    /// text's, from `menu(for:)`, when it puts up none of its own.
    private func rightClickMenu(_ h: Harness, at point: CGPoint) throws -> NSMenu? {
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: h.view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var shown: NSMenu?
        h.view.presentPropertyMenu = { menu, _ in shown = menu }
        // What `rightMouseDown` does first; never the rest of it, which pops
        // AppKit's own menu, a real one on the screen.
        if h.view.showPropertyMenu(for: event) { return shown }
        return h.view.menu(for: event)
    }

    @Test("A right-click on a property row puts up its own menu, nothing of AppKit's added; with text selected, the text's")
    func rightClick() async throws {
        let h = try await harness(.plain)
        let row = try #require(h.row(4))
        let onRow = try rightClickMenu(h, at: CGPoint(x: row.column + 12, y: row.frame.minY + 14))
        #expect(onRow?.items.map { $0.isSeparatorItem ? "-" : ($0.attributedTitle?.string ?? $0.title) }
            == ["Property type", "Cut Property", "Copy Property", "Paste Property", "-", "Remove"])
        h.view.setSelectedRange(NSRange(location: 12, length: 4))
        let selected = try rightClickMenu(h, at: CGPoint(x: row.column + 12, y: row.frame.minY + 14))
        #expect(selected?.items.first?.title != "Property type")
        // In the body, the text's menu as ever.
        h.view.setSelectedRange(NSRange(location: 0, length: 0))
        let body = (h.view.string as NSString).range(of: "Body").location
        let place = try #require(h.view.rect(forSelection: NSRange(location: body + 1, length: 1)))
        #expect(try rightClickMenu(h, at: CGPoint(x: place.midX, y: place.midY))?.items.first?.title != "Property type")
    }

    @Test("The caret never stands on a fence while the table is shown", arguments: Mode.allCases)
    func offFences(mode: Mode) async throws {
        let h = try await harness(mode)
        // Onto the opening fence, as gg or k from the first row puts it.
        h.view.setSelectedRange(NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        let first = try #require(PropertyEditing.rows(in: h.view.string).first)
        #expect(NSLocationInRange(h.view.selectedRange().location, first.range), "on the first property: \(h.view.selectedRange().location)")
        // Onto the closing fence from the body below: the last property.
        let block = try #require(PropertyEditing.blockRange(in: h.view.string))
        let body = NSMaxRange(block) + 2
        h.view.setSelectedRange(NSRange(location: body, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        h.view.setSelectedRange(NSRange(location: NSMaxRange(block) - 2, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        let last = try #require(PropertyEditing.rows(in: h.view.string).last)
        #expect(NSLocationInRange(h.view.selectedRange().location, NSRange(location: last.range.location, length: last.valueEnd - last.range.location + 1)),
                "on the last property: \(h.view.selectedRange().location)")
        // Shown as YAML, a fence is text like any other.
        HeftTextKit2View.sourcePropertyNotes.insert(h.view.noteIdentity)
        defer { HeftTextKit2View.sourcePropertyNotes.remove(h.view.noteIdentity) }
        h.view.setSelectedRange(NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.view.selectedRange().location == 1)
    }

    @Test("Tapping Properties twice quickly folds and opens it, and the caret never lands on its fence", arguments: Mode.allCases)
    func doubleTapHeading(mode: Mode) async throws {
        let h = try await harness(mode)
        h.view.noteIdentity = "double-\(mode).md"
        HeftTextKit2View.foldedPropertyNotes.remove(h.view.noteIdentity)
        let rects = try #require(h.view.propertiesHeadingRect())
        let point = CGPoint(x: rects.heading.midX, y: rects.heading.midY)
        _ = h.click(point, count: 1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.view.propertiesFolded)
        _ = h.click(point, count: 2)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!h.view.propertiesFolded)
        let opening = (h.view.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
        #expect(!NSLocationInRange(h.view.selectedRange().location, opening), "caret on the fence: \(h.view.selectedRange().location)")
        // On the heading's line but past its word, where a click is the
        // text's: still not on the fence once the click is over.
        _ = h.click(CGPoint(x: rects.heading.maxX + 200, y: rects.heading.midY))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!NSLocationInRange(h.view.selectedRange().location, opening), "caret on the fence after a click beside the heading")
    }
}

