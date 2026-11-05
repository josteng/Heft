import XCTest

/// The properties table on iOS, through real taps: UIKit places the caret,
/// the editor settles it, the keyboard types, and the saved file is read
/// back. Calling the editor's handlers directly passed on the Mac while the
/// table was broken on screen, so nothing here does.
///
/// Each test opens a fresh copy of a small invented vault in the runner's
/// temporary folder, which the simulator's app reads as it is. A row is
/// found by its icon's menu button, the one control the table puts in the
/// accessibility tree; the value column and the pills are measured from it.
/// Nothing here copies or pastes: the simulator's pasteboard is the Mac's.
///
///     xcodebuild test -scheme HeftiOSUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
@MainActor
final class PropertyTapTests: XCTestCase {
    private var app: XCUIApplication!
    private var note: URL!

    private static let source = """
        ---
        title: Weekend trip
        status:
        tags:
          - travel
          - planning
        rating: 4
        ---
        Pack the tent and the stove.

        """

    override func setUp() async throws {
        continueAfterFailure = false
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try #"{"types":{"rating":"number"}}"#.write(
            to: vault.appendingPathComponent(".obsidian/types.json"), atomically: true, encoding: .utf8
        )
        note = vault.appendingPathComponent("Trip.md")
        try Self.source.write(to: note, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_OPEN"] = "Trip.md"
        app.launch()
        XCTAssertTrue(row("title").waitForExistence(timeout: 10))
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: Finding the table

    private func row(_ key: String) -> XCUIElement { app.buttons["\(key) property"] }

    /// A point on the row of `key`, `x` points right of its icon's middle.
    private func point(onRow key: String, x: CGFloat) -> XCUICoordinate {
        let icon = row(key)
        return icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: x, dy: 0))
    }

    /// The value column, past the widest key in this vault's note.
    private func value(_ key: String) -> XCUICoordinate { point(onRow: key, x: 150) }

    /// The file as saved, once it says what `done` wants or the wait is up.
    private func saved(until done: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(8)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
            if done(text) { return text }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return text
    }

    private func finishTyping() {
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
    }

    // MARK: Tests

    func testTappingAnEmptyValueTypesIntoIt() {
        value("status").tap()
        app.typeText("draft")
        finishTyping()
        let text = saved { $0.contains("status: draft\n") }
        XCTAssertTrue(text.contains("status: draft\n"), text)
    }

    func testTappingAValueWithTextPlacesTheCaretInTheValue() {
        // Far right of the value: the caret at its end.
        point(onRow: "title", x: 280).tap()
        app.typeText("s")
        finishTyping()
        let text = saved { $0.contains("trips") }
        XCTAssertTrue(text.contains("title: Weekend trips\n"), text)
    }

    func testTappingTheLastRowsValueTypesIntoIt() {
        // The last row's line is followed by the hidden closing fence, where
        // UIKit put a caret tapped past the value's end.
        point(onRow: "rating", x: 280).tap()
        app.typeText("5")
        finishTyping()
        let text = saved { $0.contains("45") || $0.contains("5\n---") || $0.contains("\n5") }
        XCTAssertTrue(text.contains("rating: 45\n---\n"), text)
    }

    func testTappingTheKeyColumnStaysInTheKey() {
        point(onRow: "rating", x: 40).tap()
        app.typeText("X")
        finishTyping()
        let text = saved { $0.contains("X") }
        XCTAssertTrue(text.range(of: #"\nr[a-z]*X[a-z]*: 4\n"#, options: .regularExpression) != nil, text)
    }

    func testTypingIntoAListAddsAPill() {
        value("tags").tap()
        app.typeText("camping\n")
        finishTyping()
        let text = saved { $0.contains("- camping") }
        XCTAssertTrue(text.contains("tags:\n  - travel\n  - planning\n  - camping\n"), text)
    }

    func testBackspaceOnAListTakesTheLastPill() {
        value("tags").tap()
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        finishTyping()
        let text = saved { !$0.contains("planning") }
        XCTAssertTrue(text.contains("tags:\n  - travel\nrating"), text)
    }

    func testAPillsCrossRemovesIt() {
        // "travel ×" starts at the value column; its × is its last 18 points.
        point(onRow: "tags", x: 195).tap()
        let text = saved { !$0.contains("travel") }
        XCTAssertTrue(text.contains("tags:\n  - planning\nrating"), text)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a × is a button, not a place to type")
    }

    func testTheIconMenuRemovesAProperty() {
        row("rating").tap()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        let text = saved { !$0.contains("rating") }
        XCTAssertFalse(text.contains("rating"), text)
        XCTAssertTrue(text.contains("  - planning\n---\n"), text)
    }

    func testTappingTheCaretOffersTheRowsMenu() {
        // Once to place the caret, again on it for the text's menu.
        point(onRow: "title", x: 280).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        point(onRow: "title", x: 280).tap()
        // On a phone the menu is a bar; what does not fit is past Forward.
        let property = app.descendants(matching: .any)["Property"].firstMatch
        let forward = app.descendants(matching: .any)["Forward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 3) || property.exists)
        for _ in 0..<4 where !property.exists && forward.exists { forward.tap() }
        XCTAssertTrue(property.waitForExistence(timeout: 2), app.debugDescription)
        property.tap()
        let remove = app.descendants(matching: .any)["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), app.debugDescription)
        remove.tap()
        let text = saved { !$0.contains("Weekend") }
        XCTAssertTrue(text.hasPrefix("---\nstatus:\n"), text)
    }

    func testALongPressOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "title", x: 220), gone: "Weekend") }
    func testALongPressOnAnEmptyValueOffersTheRowsMenu() { longPressRemoves(at: value("status"), gone: "status") }
    func testALongPressOnPillsOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "tags", x: 160), gone: "travel") }
    func testALongPressOnAKeyOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "title", x: 40), gone: "Weekend") }

    private func longPressRemoves(at spot: XCUICoordinate, gone: String) {
        spot.press(forDuration: 1.0)
        let property = app.descendants(matching: .any)["Property"].firstMatch
        let forward = app.descendants(matching: .any)["Forward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 3) || property.exists, app.debugDescription)
        for _ in 0..<4 where !property.exists && forward.exists { forward.tap() }
        XCTAssertTrue(property.waitForExistence(timeout: 2))
        property.tap()
        let remove = app.descendants(matching: .any)["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        let text = saved { !$0.contains(gone) }
        XCTAssertFalse(text.contains(gone), text)
    }

    func testTheIconMenuSaysWhyARowIsRed() {
        try? "---\nrating: lots\n---\nBody\n".write(to: note, atomically: true, encoding: .utf8)
        app.terminate()
        app.launch()
        XCTAssertTrue(row("rating").waitForExistence(timeout: 10))
        row("rating").tap()
        XCTAssertTrue(app.buttons["\u{201C}rating\u{201D} is a number, and this isn\u{2019}t one"].waitForExistence(timeout: 3))
    }

    func testAddPropertyMakesARowAndTheValueColumnGivesItsColon() {
        // "Add property" is drawn a row's height under the last row.
        point(onRow: "rating", x: 30).withOffset(CGVector(dx: 0, dy: 32)).tap()
        app.typeText("mood")
        // Its value column, on the new row, a row under rating.
        point(onRow: "rating", x: 150).withOffset(CGVector(dx: 0, dy: 36)).tap()
        app.typeText("calm")
        finishTyping()
        let text = saved { $0.contains("mood: calm") }
        XCTAssertTrue(text.contains("rating: 4\nmood: calm\n---\n"), text)
    }

    func testAddPropertyLeftEmptyLeavesNoRow() {
        point(onRow: "rating", x: 30).withOffset(CGVector(dx: 0, dy: 32)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3) || app.buttons["Done"].exists)
        finishTyping()
        let text = saved { _ in true }
        XCTAssertEqual(text, Self.source)
    }

    func testTappingTheHeadingFoldsWithoutTheKeyboard() {
        // "Properties" sits a row above the first property, measured now:
        // folded, the rows' buttons are gone.
        let title = row("title").frame
        let heading = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: title.midX + 40, dy: title.midY - 34))
        heading.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row("rating"))
        wait(for: [gone], timeout: 3)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // And open again.
        heading.tap()
        XCTAssertTrue(row("rating").waitForExistence(timeout: 3))
        XCTAssertEqual(saved { _ in true }, Self.source)
    }
}
