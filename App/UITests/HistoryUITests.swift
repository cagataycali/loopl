import XCTest

/// History › Select → **Delete** (lane HISTORY-DELETE): Select all ticks every thread, the bottom bar's *Delete N*
/// asks before anything happens, confirming empties the list (the empty state appears, Select disappears), and
/// Cancel keeps everything. The Share path next to it stays reachable (HubShareUITests covers the sheet itself).
/// Screenshots of every stage are attached (`SHOT <name>`) — the lane's hosted captures come from here.
final class HistoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "history"] + extra
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "SHOT \(name)"; a.lifetime = .keepAlways
        add(a)
    }

    /// Opens History (the sheet on iPhone; already there as the sidebar on iPad) and returns the Select button.
    @discardableResult
    private func openHistory(_ app: XCUIApplication) -> XCUIElement {
        let select = app.buttons["history.select"]
        if !select.waitForExistence(timeout: 3) {
            let history = app.buttons["History"].firstMatch
            XCTAssertTrue(history.waitForExistence(timeout: 15), "History button")
            history.tap()
        }
        XCTAssertTrue(select.waitForExistence(timeout: 10), "Select button in History")
        return select
    }

    private var emptyState: XCUIElement { XCUIApplication().staticTexts["Conversations you finish appear here."] }

    func testSelectAllDeleteConfirmEmpties() {
        let app = launch()
        let select = openHistory(app)
        shot("01-history")
        select.tap()

        let delete = app.buttons["history.delete"], share = app.buttons["history.share"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete in the bottom bar")
        XCTAssertTrue(share.exists, "Share stays next to it")
        XCTAssertFalse(delete.isEnabled, "nothing selected yet")
        XCTAssertFalse(share.isEnabled)

        let all = app.buttons["history.selectAll"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "Select all moved to the nav bar"); all.tap()
        XCTAssertTrue(delete.isEnabled); XCTAssertTrue(share.isEnabled)
        XCTAssertTrue(app.buttons["Delete 3"].waitForExistence(timeout: 3), "the count is in the label")
        XCTAssertTrue(app.navigationBars.staticTexts["3 selected"].exists)
        shot("02-selected-all")

        delete.tap()
        // confirmationDialog exposes its buttons twice to XCUITest on iOS 26 → firstMatch.
        let confirm = app.buttons["Delete 3 conversations"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation dialog")
        XCTAssertTrue(app.staticTexts["Delete 3 conversations?"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'messages, pictures and recordings'")).firstMatch.exists)
        shot("03-confirm")
        confirm.tap()

        XCTAssertTrue(emptyState.waitForExistence(timeout: 5), "the list is empty")
        XCTAssertTrue(app.buttons["history.select"].waitForNonExistence(timeout: 3), "nothing left to select")
        XCTAssertFalse(app.buttons["history.delete"].exists, "selection mode ended")
        shot("04-empty")

        // Gone for good: relaunch WITHOUT the fixture re-seeding and the archive is still empty.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["--design-fixture", "empty"]
        again.launch()
        let history = again.buttons["History"].firstMatch
        if history.waitForExistence(timeout: 15) { history.tap() }
        XCTAssertTrue(again.staticTexts["Conversations you finish appear here."].waitForExistence(timeout: 5), "still empty after relaunch")
    }

    func testCancelKeepsEverythingAndSingleRowCounts() {
        let app = launch()
        openHistory(app).tap()
        // Tick one row, not all.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Explain what an agent loop is'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["Delete 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars.staticTexts["1 selected"].exists)
        app.buttons["history.delete"].tap()
        let confirm = app.buttons["Delete conversation"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Delete this conversation?"].exists)
        shot("05-confirm-one")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete 1"].exists, "Cancel kept the selection and the thread")
        XCTAssertTrue(row.exists)

        // Now delete that one: two remain and selection mode ends.
        app.buttons["history.delete"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the row sprang out")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What time is it in Istanbul'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fetch https://loopl.dev'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["history.delete"].exists, "selection mode ended")
        XCTAssertTrue(app.buttons["history.select"].exists, "two threads left to select")
        shot("06-two-left")
    }

    /// The Share action is still one tap away in the same bar (the sheet is HubShareUITests' job).
    func testSharePathStillReachable() {
        let app = launch()
        openHistory(app).tap()
        app.buttons["history.selectAll"].tap()
        let share = app.buttons["history.share"]
        XCTAssertTrue(share.isEnabled)
        share.tap()
        XCTAssertTrue(app.buttons["hubshare.continue"].waitForExistence(timeout: 10), "review step of Share to Hugging Face")
    }

    /// `--design-history-delete confirm` is the screenshot fixture: selection on, dialog up, nothing deleted.
    func testFixtureConfirmScene() {
        let app = launch(["--design-history-delete", "confirm"])
        openHistory(app)
        XCTAssertTrue(app.buttons["Delete 3 conversations"].firstMatch.waitForExistence(timeout: 8), "fixture raised the dialog")
        shot("07-fixture-confirm")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Delete 3"].waitForExistence(timeout: 3))
    }
}
