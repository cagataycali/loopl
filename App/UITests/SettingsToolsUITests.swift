import XCTest

/// Settings › Tools is ONE collapsible row (owner, 2026-10-06): every tool under it, grouped On / Off, each with its
/// toggle, default tag and — where a card applies — the "Asks before …" note. Nothing tool-related elsewhere.
final class SettingsToolsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        app.launch()
        if !app.collectionViews["pane-settings"].waitForExistence(timeout: 8) {   // iPad: pick the pane from the sidebar
            let item = app.buttons["Settings"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
        }
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_TOOLS_SHOTS"] else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testOneCollapsibleToolsRowWithGroupsTagsAndNotes() {
        let app = launch()
        let row = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Tools row lives in Settings › Agent")
        let summary = app.staticTexts["settings-tools-summary"].firstMatch
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.contains(" of ") || summary.label == "off", summary.label)
        XCTAssertFalse(app.staticTexts["On-device Apple tools"].exists, "the old section is gone")
        shot(app, "settings-collapsed")

        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap() }
        XCTAssertTrue(onHeader.waitForExistence(timeout: 5), "tapping the row expands the groups")
        XCTAssertTrue(app.descendants(matching: .any)["settings-tools-group-off"].firstMatch.exists)
        shot(app, "settings-tools-open")

        // Portable and on-device tools in the same list, with their default tags.
        for name in ["current_time", "http", "music", "clipboard_write"] {
            let t = app.switches["tool.\(name)"].firstMatch
            if !t.exists { app.swipeUp() }
            XCTAssertTrue(t.waitForExistence(timeout: 5), name)
            XCTAssertEqual(app.staticTexts["tool.\(name).default"].firstMatch.label, "on by default", name)
        }
        XCTAssertTrue(app.staticTexts["tool.http.asksFirst"].firstMatch.exists, "http carries its approval note")
        XCTAssertTrue(app.staticTexts["tool.clipboard_write.asksFirst"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["tool.music.asksFirst"].exists, "music never stops at a card")

        // Off group: the off-by-default ones (and whatever the Simulator cannot run).
        var found = false
        for _ in 0..<6 {
            if app.staticTexts["tool.location.default"].firstMatch.exists { found = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(found, "location is listed under Off")
        XCTAssertEqual(app.staticTexts["tool.location.default"].firstMatch.label, "off by default")
        shot(app, "settings-tools-off")

        // Switching a tool off moves it to the Off group and the summary follows.
        let before = summary.label
        let music = app.switches["tool.music"].firstMatch
        for _ in 0..<6 where !music.isHittable { app.swipeDown() }
        XCTAssertTrue(music.isHittable)
        music.tap()
        XCTAssertTrue(app.staticTexts["tool.music.default"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertNotEqual(summary.label, before, "summary counts what the model gets")
        music.tap()   // leave the install as it was
    }

    func testCollapsedStateIsRemembered() {
        var app = launch()
        let row = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap(); XCTAssertTrue(onHeader.waitForExistence(timeout: 5)) }
        app.terminate()
        app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.waitForExistence(timeout: 10), "@AppStorage keeps it open")
        app.descendants(matching: .any)["settings-tools"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.waitForExistence(timeout: 2))
    }
}
