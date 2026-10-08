import XCTest

/// `ask_user` cards on the `ask` fixture — no model, no network. One answer flow per type; the fixture settles
/// the card and scripts the model's follow-up the way the Engine does live. Screenshots → LOOPL_SHOT_DIR: ask-<type>-<state>.png.
final class AskUserUITests: XCTestCase {
    private func launch(_ type: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "ask", "--design-ask", type] + extra
        app.launch()
        return app
    }
    private func card(_ app: XCUIApplication, _ type: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ask-card-\(type)").firstMatch
    }
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func settled(_ app: XCUIApplication, _ text: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 10)
    }

    func testSelectWaitsThenChoosesAndTheModelUsesIt() throws {
        let app = launch("select")
        let c = card(app, "select")
        XCTAssertTrue(c.waitForExistence(timeout: 10), "pending select card")
        XCTAssertTrue(el(app, "ask-waiting").exists, "visible waiting-for-you state")
        XCTAssertTrue(el(app, "ask-cancel").exists, "Cancel is always there")
        XCTAssertFalse(el(app, "ask-done").isEnabled, "Choose is disabled until a pick")
        shoot(app, "ask-select-pending")
        el(app, "ask-option-Oda").tap()
        XCTAssertTrue(el(app, "ask-done").isEnabled)
        el(app, "ask-done").tap()
        XCTAssertTrue(settled(app, "Booked") && settled(app, "Oda · Turkish"), "the follow-up uses the picked value")
        XCTAssertFalse(el(app, "ask-waiting").exists, "card folded")
        XCTAssertTrue(el(app, "ask-summary").label.contains("Oda"), el(app, "ask-summary").label)
        shoot(app, "ask-select-answered")
    }

    func testConfirmYesAndCancelAreHonest() throws {
        let app = launch("confirm")
        XCTAssertTrue(card(app, "confirm").waitForExistence(timeout: 10))
        shoot(app, "ask-confirm-pending")
        el(app, "ask-cancel").tap()
        XCTAssertTrue(settled(app, "I stopped there"), "cancel reaches the model as cancelled:true")
        XCTAssertTrue(el(app, "ask-summary").label.hasSuffix("Cancelled"), el(app, "ask-summary").label)
        shoot(app, "ask-confirm-cancelled")

        let app2 = launch("confirm")
        XCTAssertTrue(card(app2, "confirm").waitForExistence(timeout: 10))
        el(app2, "ask-yes").tap()
        XCTAssertTrue(settled(app2, "reminders are gone"))
        XCTAssertTrue(el(app2, "ask-summary").label.hasSuffix("Yes"), el(app2, "ask-summary").label)
    }

    func testMultiselectChecksAndDone() throws {
        let app = launch("multiselect")
        XCTAssertTrue(card(app, "multiselect").waitForExistence(timeout: 10))
        el(app, "ask-option-Mushrooms").tap()
        el(app, "ask-option-Basil").tap()
        XCTAssertTrue(app.staticTexts["2 picked"].exists)
        shoot(app, "ask-multiselect-pending")
        el(app, "ask-done").tap()
        XCTAssertTrue(settled(app, "Mushrooms, Basil"), "array answer in option order")
        shoot(app, "ask-multiselect-answered")
    }

    func testInputTypesAndSends() throws {
        let app = launch("input")
        XCTAssertTrue(card(app, "input").waitForExistence(timeout: 10))
        let field = el(app, "ask-input")
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText(" 🍕")
        shoot(app, "ask-input-pending")
        el(app, "ask-send").tap()
        XCTAssertTrue(settled(app, "Renamed it to"))
        XCTAssertTrue(el(app, "ask-summary").label.contains("🍕") && el(app, "ask-summary").label.contains("Pizza night planning"), el(app, "ask-summary").label)
    }

    func testButtonsChipAnswersAtOnce() throws {
        let app = launch("buttons")
        XCTAssertTrue(card(app, "buttons").waitForExistence(timeout: 10))
        shoot(app, "ask-buttons-pending")
        el(app, "ask-option-10 min").tap()
        XCTAssertTrue(settled(app, "Timer set for 10 min"))
    }

    func testFormRequiresThePasswordAndNeverShowsIt() throws {
        let app = launch("form")
        XCTAssertTrue(card(app, "form").waitForExistence(timeout: 10))
        el(app, "ask-submit").tap()
        XCTAssertTrue(el(app, "ask-missing").waitForExistence(timeout: 3), "required password missing → the form says so, nothing is sent")
        XCTAssertTrue(el(app, "ask-waiting").exists)
        let pw = el(app, "ask-field-password")
        pw.tap()
        pw.typeText("hunter2")
        shoot(app, "ask-form-pending")
        el(app, "ask-submit").tap()
        XCTAssertTrue(settled(app, "Connected to"))
        XCTAssertTrue(el(app, "ask-summary").label.hasSuffix("Submitted"), el(app, "ask-summary").label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hunter2'")).firstMatch.exists, "the password is nowhere on screen after submit")
        shoot(app, "ask-form-answered")
    }

    func testMessageContinues() throws {
        let app = launch("message")
        XCTAssertTrue(card(app, "message").waitForExistence(timeout: 10))
        shoot(app, "ask-message-pending")
        el(app, "ask-continue").tap()
        XCTAssertTrue(settled(app, "Starting the update"))
        XCTAssertTrue(el(app, "ask-summary").label.hasSuffix("Seen"), el(app, "ask-summary").label)
    }

    func testSettledStatesFromTheFixture() throws {
        let timeout = launch("select", ["--design-ask-state", "timeout"])
        XCTAssertTrue(card(timeout, "select").waitForExistence(timeout: 10))
        XCTAssertTrue(el(timeout, "ask-summary").label.hasSuffix("No answer in time"), el(timeout, "ask-summary").label)
        XCTAssertTrue(settled(timeout, "didn't get an answer"))
        shoot(timeout, "ask-select-timeout")
        // Settled card: the question is one tap away.
        timeout.buttons["show the question"].firstMatch.tap()
        XCTAssertTrue(timeout.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Where should I book'")).firstMatch.waitForExistence(timeout: 3))

        let answered = launch("form", ["--design-ask-state", "answered"])
        XCTAssertTrue(card(answered, "form").waitForExistence(timeout: 10))
        XCTAssertFalse(answered.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hunter2'")).firstMatch.exists, "a saved form answer never shows the password")
        shoot(answered, "ask-form-saved")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let shot = app.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
