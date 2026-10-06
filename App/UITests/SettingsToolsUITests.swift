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
        // The row is one accessibility element: label "Tools", value "9 of 15, collapsed".
        let summaryText = { (row.value as? String) ?? "" }
        XCTAssertTrue(summaryText().contains(" of ") || summaryText().hasPrefix("off"), summaryText())
        XCTAssertFalse(app.staticTexts["On-device Apple tools"].exists, "the old section is gone")
        shot(app, "settings-collapsed")

        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap() }
        XCTAssertTrue(onHeader.waitForExistence(timeout: 5), "tapping the row expands the groups")
        let before = summaryText().components(separatedBy: ",").first ?? ""   // read while the row is on screen (the List is lazy)
        shot(app, "settings-tools-open")
        let offHeader = app.descendants(matching: .any)["settings-tools-group-off"].firstMatch   // a List is lazy: scroll until it exists
        for _ in 0..<8 where !offHeader.exists { app.swipeUp() }
        XCTAssertTrue(offHeader.exists, "an Off group follows the On group")
        for _ in 0..<8 where !row.isHittable { app.swipeDown() }

        // Portable and on-device tools in the same list, with their default tags.
        // (a List is lazy — check each row while it is on screen)
        for (name, asks) in [("current_time", false), ("http", true), ("clipboard_write", true), ("music", false)] {
            let t = app.switches["tool.\(name)"].firstMatch
            for _ in 0..<6 where !t.exists { app.swipeUp() }
            XCTAssertTrue(t.waitForExistence(timeout: 5), name)
            XCTAssertEqual(app.staticTexts["tool.\(name).default"].firstMatch.label, "on by default", name)
            XCTAssertEqual(app.staticTexts["tool.\(name).asksFirst"].firstMatch.exists, asks, "\(name) \(asks ? "carries" : "has no") approval note")
        }

        // Off group: the off-by-default ones (and whatever the Simulator cannot run).
        var found = false
        for _ in 0..<6 {
            if app.staticTexts["tool.location.default"].firstMatch.exists { found = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(found, "location is listed under Off")
        XCTAssertEqual(app.staticTexts["tool.location.default"].firstMatch.label, "off by default")
        shot(app, "settings-tools-off")

        // Switching a tool off moves it to the Off group and the summary follows. (`music` is greyed on the Simulator —
        // no player there — so flip a tool every device has.)
        let music = app.switches["tool.calculator"].firstMatch
        for _ in 0..<8 where !music.isHittable { app.swipeDown() }
        XCTAssertTrue(music.isHittable)
        // Tapping a Toggle's label does nothing on iOS — hit the switch itself (trailing edge).
        func flip() { let knob = music.switches.firstMatch; if knob.exists { knob.tap() } else { music.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() } }
        flip()
        for _ in 0..<8 where !row.exists { app.swipeDown() }
        XCTAssertNotEqual(summaryText().components(separatedBy: ",").first ?? "", before, "summary counts what the model gets")
        for _ in 0..<8 where !music.isHittable { app.swipeUp() }
        flip()   // leave the install as it was
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
