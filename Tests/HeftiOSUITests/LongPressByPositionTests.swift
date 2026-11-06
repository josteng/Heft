import XCTest

/// A long press on a property row by its place on screen, which works on
/// systems where the row's buttons are not in the accessibility tree.
@MainActor
final class LongPressByPositionTests: XCTestCase {
    func testALongPressOnARowsValueOpensItsMenu() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("placed for a 13-inch iPad") }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "---\ntitle: Lisbon\nrating: 4\n---\n\nPacking list\n".write(
            to: vault.appendingPathComponent("Trip.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_OPEN"] = "Trip.md"
        app.launchEnvironment["HEFT_IOS_PROPERTIES_AS_TEXT"] = "0"
        app.launchEnvironment["HEFT_IOS_PROPERTIES_FOLDED"] = "0"
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        // Measured from the text view, once its place has settled: pressed
        // while the bars were still laying out, the touch went to scrolling.
        // The note opens past its frontmatter and settles its scroll a
        // moment later; a press during that is a scroll, not a press.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        // The title row's value on a 13-inch iPad: right of the keys, one
        // row under the heading, below the bars the text runs under.
        let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 330, dy: 145))
        spot.press(forDuration: 1.0)
        let menu = app.menuItems["Property type"]
        let shown = menu.waitForExistence(timeout: 3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        print("LONGPRESS menuItems: \(app.menuItems.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(shown, "no row menu after a long press")
    }
}
