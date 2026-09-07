import AppKit
import SwiftUI
import Testing
@testable import Heft

/// Whether a selected row actually looks selected.
///
/// Everything else about multi-select is a value and is checked as one. This
/// is the part that is only true in pixels: the rule can say a row is lit
/// and the row can still draw itself exactly like its neighbours.
@MainActor
@Suite("Sidebar row appearance")
struct SidebarRowSnapshotTests {

    private func image(selected: Bool) throws -> NSBitmapImageRep {
        let row = NoteRow(
            name: "Quarterly Notes",
            detail: nil,
            isSelected: selected,
            depth: 0,
            symbol: "doc.text",
            action: {}
        )
        .frame(width: 240, height: 28)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        let rendered = try #require(renderer.nsImage, "ImageRenderer produced nothing")
        let data = try #require(rendered.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        if let directory = ProcessInfo.processInfo.environment["HEFT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("NoteRow-\(selected ? "selected" : "plain").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return rep
    }

    /// How much of the row is painted, sampled on a grid.
    private func coverage(_ rep: NSBitmapImageRep) -> Int {
        var painted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.alphaComponent > 0.1 { painted += 1 }
            }
        }
        return painted
    }

    @Test("A row draws something at all")
    func rowDrawsSomething() throws {
        #expect(coverage(try image(selected: false)) > 50)
    }

    @Test("A selected row is filled behind its text")
    func selectionIsVisible() throws {
        // The band is the whole point: a selection nobody can see is how you
        // trash the wrong four notes.
        let plain = coverage(try image(selected: false))
        let selected = coverage(try image(selected: true))
        #expect(selected > plain * 2, "plain \(plain), selected \(selected)")
    }
}
