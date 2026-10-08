import XCTest

/// Controls: a tool result's live control — tap "Turn off" under a flashlight result and the SAME row shows
/// "flashlight: off" with a "Turn on" switch (the real FlashlightTool ran, through the fixture torch). No new row, no
/// model turn, a quiet "updated by your tap" caption.
final class ToolControlsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "controls", "--design-tab", "chat"] + extra
        app.launch()
        return app
    }

    func testTapTurnOffRunsTheFlashlightAndUpdatesTheRow() {
        let app = launch(["--design-controls", "flashlight"])
        let turnOff = app.buttons["control-toggle"].firstMatch
        XCTAssertTrue(turnOff.waitForExistence(timeout: 15), "the flashlight result carries a Turn off switch")
        XCTAssertEqual(turnOff.label, "Turn off, currently on", "VoiceOver reads the state")
        let rowsBefore = app.descendants(matching: .any).matching(identifier: "tool-row-flashlight").count
        turnOff.tap()
        let turnOn = app.buttons.matching(identifier: "control-toggle").matching(NSPredicate(format: "label == 'Turn on, currently off'")).firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "after the tap the switch reads Turn on (flashlight: off)")
        XCTAssertTrue(app.staticTexts["control-taps"].firstMatch.waitForExistence(timeout: 5), "'updated by your tap' caption")
        XCTAssertEqual(app.staticTexts["control-taps"].firstMatch.label, "updated by your tap")
        let rowsAfter = app.descendants(matching: .any).matching(identifier: "tool-row-flashlight").count
        XCTAssertEqual(rowsAfter, rowsBefore, "no new row: the tapped row is the row")
        // Open the row: the result text is the fresh one and the arguments are still the ORIGINAL call's.
        app.descendants(matching: .any)["tool-row-flashlight"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'flashlight: off'")).firstMatch.waitForExistence(timeout: 5), "fresh result text")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'state: on'")).firstMatch.exists, "original arguments kept")
        // And back on again — the control is a real toggle.
        turnOn.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "control-toggle").matching(NSPredicate(format: "label == 'Turn off, currently on'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["control-taps"].firstMatch.label, "updated by your taps (2)")
    }

    func testEveryControlKindIsOnScreenWithStableIdentifiers() {
        let app = launch()
        XCTAssertTrue(app.buttons["control-toggle"].firstMatch.waitForExistence(timeout: 15), "flashlight toggle")
        XCTAssertTrue(app.buttons["control-button"].firstMatch.exists, "Vibrate again")
        XCTAssertEqual(app.buttons["control-button"].firstMatch.label, "Vibrate again")
        let playPause = app.buttons["control-play-pause"].firstMatch
        for _ in 0..<4 where !playPause.exists { app.swipeUp() }
        XCTAssertTrue(playPause.exists, "music mini player")
        XCTAssertTrue(app.staticTexts["control-player-title"].firstMatch.exists, "title line")
        XCTAssertEqual(app.buttons["control-play-pause"].firstMatch.label, "Pause", "playing → the button pauses")
        XCTAssertTrue(app.buttons["control-next"].firstMatch.exists); XCTAssertTrue(app.buttons["control-previous"].firstMatch.exists)
        XCTAssertTrue(app.sliders["control-volume"].firstMatch.exists, "volume known → slider")
        // Pause through the player: the REAL MusicTool runs against the fixture source and the card flips to Play.
        app.buttons["control-play-pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "control-play-pause").matching(NSPredicate(format: "label == 'Play'")).firstMatch.waitForExistence(timeout: 10), "paused → Play")
        let map = app.descendants(matching: .any)["control-map"].firstMatch
        for _ in 0..<4 where !map.exists { app.swipeUp() }
        XCTAssertTrue(map.exists, "location pin")
        let link = app.buttons["control-link"].firstMatch
        for _ in 0..<4 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.exists, "Open in Reminders")
        XCTAssertEqual(link.label, "Open in Reminders")
    }
}
