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

    /// Opens History and returns its Select button. The device-shaped part, and the 0x0 ⌘Y proxy that made all
    /// four of these tests fail on an iPad, live in `XCUIApplication.reachHistory()` (HistoryAccess.swift).
    @discardableResult
    private func openHistory(_ app: XCUIApplication) -> XCUIElement { app.reachHistory() }

    private var emptyState: XCUIElement { XCUIApplication().staticTexts["Your conversations appear here."] }

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
        app.assertSelectionCount(3)
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
        again.reachHistory(expectSelect: false)
        XCTAssertTrue(again.staticTexts["Your conversations appear here."].waitForExistence(timeout: 5), "still empty after relaunch")
    }

    /// A row in a lazy List that is below the fold is not merely unreachable — it does not EXIST to XCUITest. On an
    /// iPhone SE the third thread sits off screen where an iPhone 16 Pro shows all three, so `exists` was a claim
    /// about screen height. Scroll until it is realised (bounded), then assert. Found by running this suite on an
    /// SE: the CI runner picks the tallest iPhone it has, so a test can quietly require a tall phone forever.
    private func reachRow(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        let el = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        for _ in 0..<3 where !el.exists { app.swipeUp() }
        return el
    }

    func testCancelKeepsEverythingAndSingleRowCounts() {
        let app = launch()
        openHistory(app).tap()
        // Tick one row, not all. The NEWEST thread, because it is the first row under the first date section
        // (#162 grouped the list by day): an element lower down can exist and still not be on screen, and
        // XCUITest taps a button's centre regardless — so tapping "Explain what an agent loop is", which now
        // sits under "Yesterday", landed on the bottom bar and selected nothing.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What time is it in Istanbul'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "the row the test ticks must be on screen: \(row.frame)")
        row.tap()
        app.assertSelectionCount(1)
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
        XCTAssertTrue(reachRow(app, startingWith: "Explain what an agent loop is").exists)
        XCTAssertTrue(reachRow(app, startingWith: "Fetch https://loopl.dev").exists)
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
