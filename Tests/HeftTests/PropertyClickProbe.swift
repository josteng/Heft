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

        /// A full click at `point`, in view coordinates; returns the caret.
        func click(_ point: CGPoint) -> NSRange {
            let inWindow = view.convert(point, to: nil)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
            )!
            window.release = up
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
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
}

