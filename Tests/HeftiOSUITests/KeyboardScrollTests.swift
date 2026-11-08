import XCTest

/// Done after scrolling away from the caret leaves the page where it is.
/// The keyboard's hiding asked to keep the caret in view while the text
/// view still had focus, and the page jumped back to where the typing was.
@MainActor
final class KeyboardScrollTests: XCTestCase {
    func testDoneLeavesThePageWhereItWasScrolledTo() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let words = "garden window kettle river paper lantern bicycle orange meadow pencil harbor cloud"
            .split(separator: " ")
        var lines = ["# Ideas"]
        for i in 0..<70 {
            let count = 6 + (i * 7) % 40
            lines.append("- " + (0..<count).map { String(words[($0 + i) % words.count]) }.joined(separator: " "))
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: vault.appendingPathComponent("Ideas.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_OPEN"] = "Ideas.md"
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))

        editor.swipeUp()
        editor.swipeUp()
        sleep(1)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap()
        sleep(2)
        editor.typeText(" more")
        sleep(1)
        // Back to the top, the caret far below what shows.
        editor.swipeDown()
        editor.swipeDown()
        sleep(2)
        let before = band(of: app)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        sleep(2)
        let after = band(of: app)

        let changed = Self.changedFraction(before, after)
        XCTAssertLessThan(changed, 0.05, "the note's text moved after Done: \(changed) of the band's pixels changed")
    }

    /// A band of the note's text under the bar and above the keyboard.
    private func band(of app: XCUIApplication) -> CGImage {
        let image = UIImage(data: app.screenshot().pngRepresentation)!.cgImage!
        let height = image.height
        let rect = CGRect(x: 0, y: Int(Double(height) * 0.2), width: image.width, height: Int(Double(height) * 0.2))
        return image.cropping(to: rect)!
    }

    private static func changedFraction(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count, !pa.isEmpty else { return 1 }
        var changed = 0
        for i in stride(from: 0, to: pa.count, by: 4)
        where abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 30 {
            changed += 1
        }
        return Double(changed) / Double(pa.count / 4)
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
