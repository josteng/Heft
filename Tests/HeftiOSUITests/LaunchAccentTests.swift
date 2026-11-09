import XCTest

/// The vault's accent is on screen from the first frame of a launch, not
/// after the scan: a large vault drew its first second in the system's blue.
@MainActor
final class LaunchAccentTests: XCTestCase {
    func testTheVaultsAccentShowsBeforeTheScanLands() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        let heft = vault.appendingPathComponent(".heft")
        try FileManager.default.createDirectory(at: heft, withIntermediateDirectories: true)
        // Pure green, which nothing in Heft draws by default.
        try ##"{"accent": "#00FF00"}"##.write(to: heft.appendingPathComponent("appearance.json"),
                                             atomically: true, encoding: .utf8)
        try "A note\n".write(to: vault.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        // As a large vault in iCloud: the first scan lands well after launch.
        app.launchEnvironment["HEFT_IOS_SCAN_DELAY"] = "6"
        // The iPad's sidebar, where today's date is in the accent; portrait
        // hides it, and the empty pane beside it has no accent at all.
        app.launchEnvironment["HEFT_IOS_PAD_SIDEBAR"] = "1"
        app.launch()
        // The first look, while the scan is still running.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let green = Self.greenPixels(in: app.screenshot())
        XCTAssertGreaterThan(green, 20, "no accent-colored pixels on the first screen")
    }

    private static func greenPixels(in shot: XCUIScreenshot) -> Int {
        let image = UIImage(data: shot.pngRepresentation)!.cgImage!
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 1] > 180 && data[i] < 90 && data[i + 2] < 90 {
            count += 1
        }
        return count
    }
}
