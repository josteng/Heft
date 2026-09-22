import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// A picture replaced on disk is drawn as it is now, not as it was first read.
///
/// The cache was keyed on the path alone, so a figure exported again with new
/// numbers kept showing the old one until the app quit, even after its embed
/// was deleted and written again.
@MainActor
@Suite("Replaced pictures are reloaded", .serialized)
struct ImageReplacementTests {

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func figureURL() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heft-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("figure.png")
    }

    @Test("A lookup after the file is replaced returns the new picture")
    func lookupReloads() throws {
        let store = ImageCache.Store()
        let url = try figureURL()
        try writePNG(width: 40, height: 20, to: url)
        #expect(store.image(at: url)?.size.width == 40)

        try writePNG(width: 90, height: 30, to: url)
        #expect(store.image(at: url)?.size.width == 90)
    }

    @Test("A disk event that replaced a cached picture moves the generation")
    func refreshMovesGeneration() throws {
        let store = ImageCache.Store()
        let url = try figureURL()
        try writePNG(width: 40, height: 20, to: url)
        _ = store.image(at: url)

        #expect(!store.refreshChanged())
        #expect(store.generation == 0)

        try writePNG(width: 90, height: 30, to: url)
        #expect(store.refreshChanged())
        #expect(store.generation == 1)
    }

    @Test("A context built after a replacement differs from one built before")
    func contextCarriesGeneration() throws {
        let url = try figureURL()
        try writePNG(width: 40, height: 20, to: url)
        _ = ImageCache.image(at: url)
        let before = RenderContext(index: .empty, current: nil, vaultRoot: nil)

        try writePNG(width: 90, height: 30, to: url)
        ImageCache.refreshChanged()
        let after = RenderContext(index: .empty, current: nil, vaultRoot: nil)
        #expect(after.imageGeneration > before.imageGeneration)
    }
}
