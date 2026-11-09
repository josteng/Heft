import XCTest

/// What the iPad shows before a launch's first scan lands is what it shows
/// after: the empty pane counted 0 notes until the index was built.
@MainActor
final class PadLaunchTests: XCTestCase {
    func testTheNoteCountIsRightBeforeTheScanLands() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The empty pane is the iPad's.") }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("counted-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for name in ["One", "Two", "Three"] {
            try "\(name)\n".write(to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        let label = "3 notes in \(vault.lastPathComponent)"
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launch()
        // A first run scans and keeps its list for the next launch.
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()

        app.launchEnvironment["HEFT_IOS_SCAN_DELAY"] = "8"
        app.launch()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 3),
                      "while the scan is held back: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }
}
