import AppIntents
import AppKit
import HeftCore
import Testing
@testable import Heft

/// A right-click leaves one row named, the one under the pointer, until a
/// left-click or a minute gives the rest their names back.
@MainActor
@Suite("Pointing Siri at a right-clicked row")
struct SiriPointerTests {

    private func marker(_ path: String, in window: NSWindow, pointer: SiriPointer) -> SiriMarkerView {
        let view = SiriMarkerView()
        view.entity = EntityIdentifier(for: NoteEntity.self, identifier: path)
        window.contentView?.addSubview(view)
        pointer.register(view)
        return view
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test("A registered row tells the system its note")
    func aRowNamesItself() {
        let pointer = SiriPointer()
        let row = marker("Garden.md", in: window(), pointer: pointer)
        #expect(row.appEntityIdentifier?.identifier == "Garden.md")
    }

    @Test("Pointing at a row silences every other row and names it as the window's activity")
    func pointingNarrowsToOneRow() {
        let pointer = SiriPointer()
        let window = window()
        let garden = marker("Garden.md", in: window, pointer: pointer)
        let reading = marker("Reading.md", in: window, pointer: pointer)
        pointer.point(at: reading.entity, in: window)
        #expect(garden.appEntityIdentifier == nil)
        #expect(reading.appEntityIdentifier?.identifier == "Reading.md")
        #expect(window.userActivity?.appEntityIdentifier?.identifier == "Reading.md")
        pointer.point(at: nil, in: window)
    }

    @Test("Pointing at nothing gives every row its name back and drops the activity")
    func releasingRestoresEveryRow() {
        let pointer = SiriPointer()
        let window = window()
        let garden = marker("Garden.md", in: window, pointer: pointer)
        let reading = marker("Reading.md", in: window, pointer: pointer)
        pointer.point(at: reading.entity, in: window)
        pointer.point(at: nil, in: window)
        #expect(garden.appEntityIdentifier?.identifier == "Garden.md")
        #expect(reading.appEntityIdentifier?.identifier == "Reading.md")
        #expect(window.userActivity == nil)
    }

    @Test("A row that appears while another is pointed at stays silent until the release")
    func aLateRowFollowsThePointer() {
        let pointer = SiriPointer()
        let window = window()
        let reading = marker("Reading.md", in: window, pointer: pointer)
        pointer.point(at: reading.entity, in: window)
        let late = marker("Late.md", in: window, pointer: pointer)
        #expect(late.appEntityIdentifier == nil)
        pointer.point(at: nil, in: window)
        #expect(late.appEntityIdentifier?.identifier == "Late.md")
    }

    @Test("A row that changes its note while pointed at elsewhere stays silent")
    func aRenamedRowStaysSilent() {
        let pointer = SiriPointer()
        let window = window()
        let reading = marker("Reading.md", in: window, pointer: pointer)
        let other = marker("Other.md", in: window, pointer: pointer)
        pointer.point(at: reading.entity, in: window)
        other.entity = EntityIdentifier(for: NoteEntity.self, identifier: "Renamed.md")
        pointer.refresh(other)
        #expect(other.appEntityIdentifier == nil)
        pointer.point(at: nil, in: window)
    }
}
