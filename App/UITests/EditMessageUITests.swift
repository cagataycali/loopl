import XCTest

/// Hold-to-edit (lane EDIT-MESSAGE): on the `edit` design fixture, long-press the second user message →
/// Edit · Copy · Delete from here → Edit turns the row into an inline editor → Save & regenerate replaces
/// the turn, drops the old answer and streams a new one. Also: hold an answer → Copy · Retry, and the
/// context menu is disabled with a hint while the agent runs. Screenshots are attached at every step
/// (the lane's captures come from these attachments).
final class EditMessageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "edit", "--design-tab", "chat"]
        if reduceMotion { app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "1"] }   // honoured by the fixture host
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func row(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testHoldEditSaveRegenerates() {
        let app = launch()
        let tokyo = row(app, containing: "And in Tokyo?")
        XCTAssertTrue(tokyo.waitForExistence(timeout: 10), "fixture thread on screen")
        shot(app, "1-thread")

        tokyo.press(forDuration: 0.8)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "hold menu shows Edit")
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Delete from here"].exists)
        shot(app, "2-hold-menu")
        edit.tap()

        let field = app.textViews["edit.field"].exists ? app.textViews["edit.field"] : app.textFields["edit.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "inline editor appears in place")
        shot(app, "3-inline-editor")
        let save = app.buttons["edit.save"]
        XCTAssertFalse(save.isEnabled, "unchanged text cannot be saved")

        app.buttons["edit.clear"].tap()          // the editor's ⓧ empties the field
        XCTAssertFalse(save.isEnabled, "empty text cannot be saved either")
        field.tap()
        field.typeText("And in London?")
        XCTAssertTrue(save.isEnabled)
        shot(app, "4-edited-text")
        save.tap()

        let london = row(app, containing: "And in London?")
        XCTAssertTrue(london.waitForExistence(timeout: 5), "the edited turn replaces the old one")
        XCTAssertFalse(row(app, containing: "And in Tokyo?").exists, "the old turn is gone")
        XCTAssertTrue(row(app, containing: "London is").waitForExistence(timeout: 10), "a new answer streams in")
        XCTAssertFalse(row(app, containing: "12:14").exists, "the old answer is gone")
        XCTAssertTrue(row(app, containing: "06:14").exists, "the earlier turn is untouched")
        shot(app, "5-regenerated")
    }

    func testHoldAssistantRetryAndCancelEdit() {
        let app = launch()
        let answer = row(app, containing: "six hours ahead")
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), "assistant hold menu shows Retry")
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertFalse(app.buttons["Edit"].exists, "no Edit on an answer")
        shot(app, "6-assistant-menu")
        app.buttons["Retry"].tap()
        XCTAssertTrue(row(app, containing: "And in Tokyo?").waitForExistence(timeout: 5), "the user turn stays")
        XCTAssertTrue(row(app, containing: "12:14").waitForExistence(timeout: 10), "a fresh answer arrives")

        // Cancel restores the row untouched.
        let tokyo = row(app, containing: "And in Tokyo?")
        tokyo.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["edit.cancel"].waitForExistence(timeout: 5))
        app.buttons["edit.cancel"].tap()
        XCTAssertTrue(row(app, containing: "And in Tokyo?").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["edit.save"].exists, "editor is gone after Cancel")
        shot(app, "7-after-cancel")
    }

    func testDeleteFromHere() {
        let app = launch()
        let tokyo = row(app, containing: "And in Tokyo?")
        XCTAssertTrue(tokyo.waitForExistence(timeout: 10))
        tokyo.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Delete from here"].waitForExistence(timeout: 5))
        app.buttons["Delete from here"].tap()
        XCTAssertTrue(row(app, containing: "06:14").waitForExistence(timeout: 5), "the first exchange stays")
        XCTAssertFalse(row(app, containing: "And in Tokyo?").waitForExistence(timeout: 2))
        XCTAssertFalse(row(app, containing: "12:14").exists)
        shot(app, "8-deleted-from-here")
    }

    func testReduceMotionPath() {
        let app = launch(reduceMotion: true)
        let tokyo = row(app, containing: "And in Tokyo?")
        XCTAssertTrue(tokyo.waitForExistence(timeout: 10))
        tokyo.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["edit.save"].waitForExistence(timeout: 5))
        shot(app, "9-reduce-motion-editor")
        app.buttons["edit.cancel"].tap()
        XCTAssertTrue(row(app, containing: "And in Tokyo?").waitForExistence(timeout: 5))
    }
}
