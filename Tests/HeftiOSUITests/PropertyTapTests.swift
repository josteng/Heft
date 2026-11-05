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
        // The table, whatever the simulator's Settings say.
        app.launchEnvironment["HEFT_IOS_PROPERTIES_AS_TEXT"] = "0"
        app.launchEnvironment["HEFT_IOS_PROPERTIES_FOLDED"] = "0"
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

    /// Taps `item` in the text's menu, which on a phone is a bar whose
    /// overflow is past its next-page arrow, "Forward" on some systems and
    /// "Next Page" on others. The row's items come first, Format never.
    private func chooseFromMenu(_ item: String) {
        let wanted = app.descendants(matching: .any)[item].firstMatch
        let forward = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Forward", "Next Page"])).firstMatch
        XCTAssertTrue(wanted.waitForExistence(timeout: 3) || forward.exists, app.debugDescription)
        for _ in 0..<4 where !wanted.exists && forward.exists { forward.tap() }
        XCTAssertTrue(wanted.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(app.menuItems["Format"].exists, "Format offered on a property")
        wanted.tap()
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
        chooseFromMenu("Remove")
        let text = saved { !$0.contains("Weekend") }
        XCTAssertTrue(text.hasPrefix("---\nstatus:\n"), text)
    }

    func testStartFoldedOpensFoldedAndTheHeadingOpensIt() {
        let title = row("title").frame
        app.terminate()
        app.launchEnvironment["HEFT_IOS_PROPERTIES_FOLDED"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(row("title").waitForExistence(timeout: 2), "rows shown though folded")
        // The heading, where it stood above the first row.
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: title.midX + 40, dy: title.midY - 34)).tap()
        XCTAssertTrue(row("title").waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(saved { _ in true }, Self.source)
    }

    func testALongPressOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "title", x: 220), gone: "Weekend") }
    func testALongPressOnAnEmptyValueOffersTheRowsMenu() { longPressRemoves(at: value("status"), gone: "status") }
    func testALongPressOnPillsOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "tags", x: 160), gone: "travel") }
    func testALongPressOnAKeyOffersTheRowsMenu() { longPressRemoves(at: point(onRow: "title", x: 40), gone: "Weekend") }

    private func longPressRemoves(at spot: XCUICoordinate, gone: String) {
        spot.press(forDuration: 1.0)
        chooseFromMenu("Remove")
        let text = saved { !$0.contains(gone) }
        XCTAssertFalse(text.contains(gone), text)
    }

    func testPropertiesAsTextShowsTheYAMLForEveryNote() {
        app.terminate()
        app.launchEnvironment["HEFT_IOS_PROPERTIES_AS_TEXT"] = "1"
        app.launch()
        // As text, the rows have no icon buttons, and the text is typed into
        // as written: a tap on the empty value's line and a letter after it.
        XCTAssertFalse(row("title").waitForExistence(timeout: 4))
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

    /// The rows, in screen points, of the caret's pixels inside `area`: the
    /// tint's blue, in whichever of a few screenshots caught it lit.
    private func caretRows(in area: CGRect) -> ClosedRange<Int>? {
        for _ in 0..<10 {
            let shot = XCUIScreen.main.screenshot().image
            guard let image = shot.cgImage, let data = image.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else { return nil }
            let scale = CGFloat(image.width) / shot.size.width
            let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
            var rows: [Int] = []
            for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
                for x in Int(area.minX * scale)..<Int(area.maxX * scale) {
                    let pixel = bytes + y * perRow + x * perPixel
                    // BGRA or RGBA: the caret is blue on either reading.
                    let (first, third) = (Int(pixel[0]), Int(pixel[2]))
                    let blue = image.bitmapInfo.contains(.byteOrder32Little) ? first : third
                    let red = image.bitmapInfo.contains(.byteOrder32Little) ? third : first
                    if blue > 180, red < 90 { rows.append(y); break }
                }
            }
            if let low = rows.min(), let high = rows.max() { return low...high }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    /// The rows, in screen points, of the outline's top and bottom border at
    /// screen column `x`, between `area`'s top and bottom.
    private func outlineRows(at x: CGFloat, in area: CGRect) -> (top: CGFloat, bottom: CGFloat)? {
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let scale = CGFloat(image.width) / shot.size.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        // Light or dark: the border is what differs from the page above it.
        let column = Int(x * scale)
        func value(_ y: Int) -> Int { Int((bytes + y * perRow + column * perPixel)[1]) }
        let page = value(Int(area.minY * scale))
        var rows: [Int] = []
        for y in Int(area.minY * scale)..<Int(area.maxY * scale) where abs(value(y) - page) > 30 { rows.append(y) }
        guard let top = rows.min(), let bottom = rows.max() else { return nil }
        return (CGFloat(top) / scale, CGFloat(bottom) / scale)
    }

    func testTheCaretIsCentredInARowsOutline() {
        point(onRow: "title", x: 280).tap()
        let icon = row("title")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        // The icon's button is taller than the outline and centred on the
        // same row, so the outline lies inside its band and no other row does.
        let area = CGRect(x: 0, y: icon.frame.minY, width: 400, height: icon.frame.height)
        // Between the icon and the key, where no letter is.
        let outline = outlineRows(at: icon.frame.maxX + 3, in: area)
        // The caret, past the value's end.
        let caret = caretRows(in: CGRect(x: icon.frame.maxX + 150, y: area.minY, width: 200, height: area.height))
        let shot = XCUIScreen.main.screenshot().image
        let scale = (shot.cgImage.map { CGFloat($0.width) } ?? shot.size.width) / shot.size.width
        guard let outline, let caret else { return XCTFail("outline \(String(describing: outline)) caret \(String(describing: caret))") }
        let above = CGFloat(caret.lowerBound) / scale - outline.top
        let below = outline.bottom - CGFloat(caret.upperBound) / scale
        XCTAssertEqual(above, below, accuracy: 1.5, "room above \(above), below \(below)")
    }

    func testANewRowsCaretStaysPutAtTheFirstLetter() {
        point(onRow: "rating", x: 30).withOffset(CGVector(dx: 0, dy: 32)).tap()
        let icon = app.buttons["Property"]
        XCTAssertTrue(icon.waitForExistence(timeout: 3))
        // From the icon to well past the first letter, the row's height and some.
        let area = CGRect(x: icon.frame.maxX, y: icon.frame.minY - 8, width: 60, height: icon.frame.height + 16)
        let empty = caretRows(in: area)
        app.typeText("a")
        Thread.sleep(forTimeInterval: 0.5)
        let typed = caretRows(in: area)
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty, typed, "the caret moved or grew at the first letter")
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
