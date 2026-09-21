import AppIntents
import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The Ask Siri item macOS adds to a context menu is AppKit's, so what
/// names the row has to reach AppKit.
@MainActor
@Suite("Naming a row's note to AppKit")
struct SiriEntityMarkerTests {

    private func hosted(_ view: some View) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: 200, height: 40))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func identifiers(in view: NSView) -> [String] {
        var found = view.appEntityIdentifier.map { [$0.identifier] } ?? []
        for subview in view.subviews { found += identifiers(in: subview) }
        return found
    }

    /// SwiftUI's own modifier keeps the entity in SwiftUI's tree: measured,
    /// a hosted view reports none of it to AppKit. That is why the marker
    /// exists, and this is the measurement, so a future SwiftUI that does
    /// surface it shows up here as a second identifier rather than a
    /// mystery.
    @Test("SwiftUI's own annotation does not reach an NSView")
    func swiftUIKeepsItToItself() {
        let host = hosted(
            Text("Row").appEntityIdentifier(
                EntityIdentifier(for: NoteEntity.self, identifier: "Alone.md")
            )
        )
        #expect(identifiers(in: host).isEmpty)
    }

    @Test("A row that names a note puts it where AppKit can read it")
    func theMarkerReachesAppKit() {
        let host = hosted(
            Text("Row").namesForSiri(
                EntityIdentifier(for: NoteEntity.self, identifier: "Projects/Roof.md")
            )
        )
        #expect(identifiers(in: host) == ["Projects/Roof.md"])
    }

    @Test("A row with no note names nothing")
    func nothingToName() {
        #expect(identifiers(in: hosted(Text("Row").namesForSiri(nil))).isEmpty)
    }
}
