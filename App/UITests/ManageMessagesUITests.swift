import XCTest

/// P6-B `manage_messages`: when the model tidies its own context mid-turn, the transcript keeps every earlier row
/// (the user's record) and shows ONE quiet marker — never a gap, never a rewritten history.
final class ManageMessagesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCompactionShowsOneQuietMarkerAndKeepsEveryRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "compacted", "--design-tab", "chat"]
        app.launch()
        let marker = app.staticTexts["The model tidied 2 turns of notes · your conversation is unchanged"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15), "the quiet marker is on screen")
        // The user's record: all three questions and both earlier answers are still rows above the marker.
        for text in ["What time is it in Istanbul?", "And 23 × 47, then 2^10?", "The context is getting long — tidy it up, then tell me what you kept."] {
            XCTAssertTrue(app.staticTexts[text].firstMatch.exists, "user row kept: \(text)")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'just past midnight in Istanbul'")).firstMatch.exists, "earlier answer kept")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1081'")).firstMatch.exists, "earlier answer kept")
        // The tool row for manage_messages is there too (the model's call is honest, not hidden), and the marker is the only note.
        // Found by identifier, not by label: the row reads "Tidy context" since #140 (ToolLabel.table).
        XCTAssertTrue(app.descendants(matching: .any)["tool-row-manage_messages"].exists, "the manage_messages tool row is visible")
        XCTAssertEqual(app.staticTexts.matching(identifier: "transcript-note").count, 1, "exactly one quiet marker")
        // Marker sits BELOW the earlier rows (it marks the moment of the edit, the record above stays in place).
        let firstQuestion = app.staticTexts["What time is it in Istanbul?"].firstMatch
        XCTAssertLessThan(firstQuestion.frame.minY, marker.frame.minY)
    }

    func testToolIsListedInSettingsAsOnByDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        app.launch()
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), "Settings › Tools disclosure")
        if !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        let toggle = app.switches["tool.manage_messages"].firstMatch
        for _ in 0..<6 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "manage_messages has a row")
        XCTAssertEqual(app.staticTexts["tool.manage_messages.default"].firstMatch.label, "on by default")
        XCTAssertFalse(app.staticTexts["tool.manage_messages.asksFirst"].exists, "a read/edit of the model's own context needs no approval card")
    }
}
