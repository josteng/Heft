import XCTest

/// Renaming the open note from the iPad's sidebar: the pane follows it to
/// its new name and stays there, through the rescan the rename starts.
@MainActor
final class PadRenameTests: XCTestCase {
    func testRenamingTheOpenNoteFromTheSidebarKeepsItOpen() throws {
        try renameKeepsItOpen(from: "Files", manyNotes: true)
    }

    func testRenamingTheOpenNoteFromRecentKeepsItOpen() throws {
        try renameKeepsItOpen(from: "Recent", manyNotes: false)
    }

    private func renameKeepsItOpen(from list: String, manyNotes: Bool) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("the iPad's sidebar") }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Trips"), withIntermediateDirectories: true)
        try "# Lisbon\n\nPacking list\n".write(to: vault.appendingPathComponent("Trips/Lisbon.md"), atomically: true, encoding: .utf8)
        try "# Other\n".write(to: vault.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        // Enough notes that the rescan a rename starts takes a while, as in
        // a real vault: the pane closed while it ran.
        let archive = vault.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for number in 0..<(manyNotes ? 3000 : 0) {
            try "# Day \(number)\n\nA line about [[Other]] and #tag\(number % 40).\n"
                .write(to: archive.appendingPathComponent("Day \(number).md"), atomically: false, encoding: .utf8)
        }
        let app = XCUIApplication()
        app.launchEnvironment["HEFT_IOS_VAULT"] = vault.path
        app.launchEnvironment["HEFT_IOS_OPEN"] = "Trips/Lisbon.md"
        app.launch()

        let show = app.buttons["Show Sidebar"].firstMatch
        if show.waitForExistence(timeout: 10) { show.tap() }
        // The tree, whichever list the sidebar was left on.
        let files = app.buttons[list].firstMatch
        if files.waitForExistence(timeout: 5) { files.tap() }
        let row = app.collectionViews.staticTexts["Lisbon"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), app.debugDescription)
        row.press(forDuration: 1.0)
        let rename = app.buttons["Rename…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 3), app.debugDescription)
        rename.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.press(forDuration: 0.6)
        if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
        field.typeText("Porto")
        app.buttons["Rename"].firstMatch.tap()

        let moved = vault.appendingPathComponent("Trips/Porto.md")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: moved.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "not renamed")
        // Through the rescan, which is what closed the pane: looked at
        // several times, since it could close and come back.
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertFalse(app.buttons["Quick Open…"].exists, "the pane closed during the rescan")
        }
        XCTAssertTrue(app.navigationBars["Porto"].exists || app.staticTexts["Porto"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Quick Open…"].exists, "the pane closed")
    }
}
