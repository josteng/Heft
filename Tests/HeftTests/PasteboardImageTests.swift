import AppKit
import Foundation
import Testing
@testable import Heft
@testable import HeftCore

/// The clipboard half of inserting a picture. Dragging a file in was covered;
/// pasting one was not, and pasting is how a screenshot actually arrives.
@Suite("Pasteboard images")
struct PasteboardImageTests {

    /// A tiny real PNG, built rather than checked in so the test carries no
    /// binary fixture.
    private func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A pasteboard of our own, never the general one: a test must not reach
    /// into the clipboard the person running it is using.
    private func pasteboard(_ build: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: .init("dev.stenglein.Heft.tests.\(UUID().uuidString)"))
        board.clearContents()
        build(board)
        return board
    }

    /// The vault-root rule, so the test asserts the paste and not whatever
    /// attachment folder happens to be configured on this machine.
    private func destination(for root: URL) -> Attachments.Destination {
        Attachments.Destination(
            rules: AttachmentRules(rules: [.vaultRoot]),
            index: VaultIndex.build(root: VaultScanner.scan(root: root)),
            settings: ObsidianSettings()
        )
    }

    private func withVault(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// What a screenshot tool puts on the clipboard: image data, no file.
    @Test("A bare PNG on the clipboard is found")
    func findsRawPNG() {
        let data = pngData()
        let board = pasteboard { $0.setData(data, forType: .png) }
        let payload = Attachments.imagePayload(from: board)
        #expect(payload?.data == data)
        #expect(payload?.name == nil)
    }

    @Test("TIFF is found too")
    func findsTIFF() {
        let tiff = NSBitmapImageRep(data: pngData())!.tiffRepresentation!
        let board = pasteboard { $0.setData(tiff, forType: .tiff) }
        #expect(Attachments.imagePayload(from: board)?.data == tiff)
    }

    /// Some apps write the image alongside other representations, which lands
    /// it on a later pasteboard item.
    @Test("A PNG behind another item is still found")
    func findsPNGOnALaterItem() {
        let data = pngData()
        let board = pasteboard { board in
            let text = NSPasteboardItem()
            text.setString("a caption", forType: .string)
            let image = NSPasteboardItem()
            image.setData(data, forType: .png)
            board.writeObjects([text, image])
        }
        #expect(Attachments.imagePayload(from: board)?.data == data)
    }

    @Test("Text alone is not an image")
    func ignoresText() {
        let board = pasteboard { $0.setString("not a picture", forType: .string) }
        #expect(Attachments.imagePayload(from: board) == nil)
    }

    /// The whole paste, end to end: clipboard bytes in, a file in the vault
    /// and a link to insert out.
    @Test("Pasting a screenshot writes a file and returns its link")
    func savesAndLinks() throws {
        try withVault { root in
            let data = pngData()
            let board = pasteboard { $0.setData(data, forType: .png) }
            let payload = try #require(Attachments.imagePayload(from: board))

            let markdown = try Attachments.save(
                imageData: payload.data, preferredName: payload.name,
                vaultRoot: root, noteURL: root.appendingPathComponent("note.md"),
                settings: ObsidianSettings(), destination: destination(for: root)
            )

            let written = try FileManager.default
                .subpathsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".png") }
            #expect(written.count == 1)
            #expect(!markdown.isEmpty)
            // The link has to name the file that was actually written, or the
            // note points at nothing.
            let name = try #require(written.first.map { ($0 as NSString).lastPathComponent })
            #expect(markdown.contains((name as NSString).deletingPathExtension))
        }
    }

    /// The reason pasting a screenshot did nothing while dragging one worked.
    /// AppKit will not enable Paste unless the view claims it can read a type
    /// the pasteboard holds, and a screenshot is only `public.png` and
    /// `public.tiff`. Without these the menu item is disabled and command-V
    /// never reaches `paste(_:)` at all.
    @Test("The editor says it can read a picture, so Paste is offered")
    func offersPasteForAPicture() {
        let view = HeftTextKit2View(frame: .zero)
        view.isRichText = false
        let readable = view.readablePasteboardTypes
        #expect(readable.contains(.png))
        #expect(readable.contains(.tiff))
        // Nothing a plain-text view could already read was lost on the way.
        let plain = NSTextView(frame: .zero)
        plain.isRichText = false
        for type in plain.readablePasteboardTypes {
            #expect(readable.contains(type), "dropped \(type.rawValue)")
        }
    }

    /// Pasting the same screenshot twice is one file, not two for iCloud to
    /// carry around.
    @Test("The same picture pasted twice is stored once")
    func deduplicates() throws {
        try withVault { root in
            let data = pngData()
            let destination = destination(for: root)
            for _ in 0..<2 {
                _ = try Attachments.save(
                    imageData: data, preferredName: nil, vaultRoot: root,
                    noteURL: root.appendingPathComponent("note.md"),
                    settings: ObsidianSettings(), destination: destination
                )
            }
            let written = try FileManager.default
                .subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".png") }
            #expect(written.count == 1)
        }
    }
}
