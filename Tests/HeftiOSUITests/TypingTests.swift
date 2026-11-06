import XCTest

/// Typing into a note on iOS replaces and pairs as the Mac does: real
/// keystrokes, the saved file read back.
@MainActor
final class TypingTests: XCTestCase {
    private var app: XCUIApplication!
    private var note: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        note = vault.appendingPathComponent("Plain.md")
        try "Start\n".write(to: note, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_OPEN"] = "Plain.md"
        app.launch()
    }

    override func tearDown() async throws { app?.terminate() }

    private func typeAtEnd(_ text: String) {
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(XCUIKeyboardKey.end.rawValue)
        editor.typeText(text)
    }

    private func saved(containing wanted: String) -> String {
        let deadline = Date().addingTimeInterval(8)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
            if text.contains(wanted) { return text }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return text
    }

    func testAnArrowIsReplacedAsItIsTyped() {
        typeAtEnd(" a -> b")
        let text = saved(containing: "a \u{2192} b")
        XCTAssertTrue(text.contains("a \u{2192} b"), text.debugDescription)
    }

    func testABracketGetsItsPartner() {
        typeAtEnd(" (x")
        let text = saved(containing: "(x)")
        XCTAssertTrue(text.contains("(x)"), text.debugDescription)
    }

    func testBackspaceRightAfterPutsBackWhatWasTyped() {
        typeAtEnd(" ->")
        _ = saved(containing: "\u{2192}")
        app.textViews.firstMatch.typeText(XCUIKeyboardKey.delete.rawValue)
        app.textViews.firstMatch.typeText("!")
        let text = saved(containing: "->!")
        XCTAssertTrue(text.contains("->!"), text.debugDescription)
    }
}

/// A replacement made in Settings on iOS is kept in the vault, where the
/// Mac and the other devices read it.
@MainActor
final class TypingSettingsTests: XCTestCase {
    func testAReplacementAddedInSettingsIsKeptInTheVault() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "Start\n".write(to: vault.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_SETTINGS"] = "typing"
        app.launch()

        let add = app.buttons["Add Replacement"]
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Arrows")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // Under the built-in groups, below the fold in a smaller sheet.
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3), app.debugDescription)
        add.tap()
        let typed = app.textFields["Typed"]
        XCTAssertTrue(typed.waitForExistence(timeout: 3))
        typed.tap()
        typed.typeText(":hi")
        let becomes = app.textFields["Becomes"]
        becomes.tap()
        becomes.typeText("Hello there")
        app.buttons["Done"].firstMatch.tap()

        let file = vault.appendingPathComponent(".heft/typing.json")
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if text.contains(":hi") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(text.contains(":hi") && text.contains("Hello there"), text)
    }

    func testTheReplacementSheetStaysWhereItOpened() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "Start\n".write(to: vault.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_SETTINGS"] = "typing"
        app.launch()
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the phone's sheet") }
        let add = app.buttons["Add Replacement"]
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Arrows")).firstMatch
            .waitForExistence(timeout: 10))
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        add.tap()
        let typed = app.textFields["Typed"]
        XCTAssertTrue(typed.waitForExistence(timeout: 3))
        let last = app.switches["On"]
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let first = (typed.frame.minY, last.frame.minY)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        print("SHEET typed \(first.0) -> \(typed.frame.minY), on \(first.1) -> \(last.frame.minY)")
        XCTAssertEqual(typed.frame.minY, first.0, accuracy: 1, "the sheet moved after it opened")
        XCTAssertEqual(last.frame.minY, first.1, accuracy: 1, "its rows moved after it opened")
    }
}

