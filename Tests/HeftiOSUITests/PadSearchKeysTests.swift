import XCTest

/// The Mac's keys into the search work on an iPad with a keyboard: ⌘T,
/// ⌘O, ⌘P and ⇧⌘F open it on their scope, ⌘1 to ⌘5 choose one inside
/// it, and ⇧⌘D shows or hides the calendar once per press. The menu bar's
/// items for them never got the keys.
@MainActor
final class PadSearchKeysTests: XCTestCase {
    private var app: XCUIApplication!

    /// The calendar test needs the sidebar, which portrait hides.
    private var showsSidebar: Bool { name.contains("Calendar") }

    override func setUp() async throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The iPad's keys.") }
        // On the iPadOS 26.5 simulator typeKey reached the app now and then
        // only, the window's shortcuts and the menu's alike.
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        else { throw XCTSkip("typeKey is unreliable on the iPadOS 26 simulator.") }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# Plain\n\nSome text\n".write(to: vault.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        if showsSidebar { app.launchEnvironment["HEFT_IOS_PAD_SIDEBAR"] = "1" }
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.exists || app.staticTexts.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
    }

    override func tearDown() async throws { app?.terminate() }

    private func field(_ placeholder: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    private func close() {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        sleep(1)
    }

    func testEachKeyOpensTheSearchOnItsScope() {
        for (key, modifiers, placeholder) in [
            ("t", XCUIElement.KeyModifierFlags.command, "Search everything"),
            ("o", .command, "Search notes, or paste a path"),
            ("p", .command, "Search commands"),
            ("f", [.command, .shift], "Search text in notes"),
        ] {
            app.typeKey(key, modifierFlags: modifiers)
            XCTAssertTrue(field(placeholder).waitForExistence(timeout: 3), "\(key): \(app.textFields.allElementsBoundByIndex.map(\.placeholderValue))")
            close()
        }
    }

    func testNumbersChooseAScopeInsideTheSearch() {
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(field("Search everything").waitForExistence(timeout: 3))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(field("Search tags").waitForExistence(timeout: 3), "\(app.textFields.allElementsBoundByIndex.map(\.placeholderValue))")
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(field("Search text in notes").waitForExistence(timeout: 3), "\(app.textFields.allElementsBoundByIndex.map(\.placeholderValue))")
    }

    func testShiftCommandDTogglesTheCalendarOnce() {
        let month = app.staticTexts[Date().formatted(.dateTime.month(.wide).year())]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: [.command, .shift])
        sleep(1)
        XCTAssertFalse(month.exists, "the calendar is still shown")
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(month.waitForExistence(timeout: 3), "the calendar did not come back")
    }
}
