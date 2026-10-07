import XCTest

/// P6-F `system_prompt`: the model changes its OWN system prompt only through an approval card that shows the change,
/// the transcript gets ONE quiet marker, and Settings › System prompt says "changed by the agent" with a one-tap Revert.
final class SystemPromptUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testApprovalCardShowsTheChangeOpenByDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "sysprompt", "--design-tab", "chat"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Add to my instructions'")).firstMatch.waitForExistence(timeout: 15), "the card leads with what the model wants")
        let preview = app.staticTexts["approval-change-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the old → new preview is OPEN without a tap — it is the decision")
        XCTAssertTrue(preview.label.contains("+ Always answer in Turkish"), preview.label)
        XCTAssertTrue(preview.label.contains("instructions stay"), "append shows what stays: \(preview.label)")
        XCTAssertTrue(app.buttons["Approve"].firstMatch.exists); XCTAssertTrue(app.buttons["Deny"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "transcript-note").count, 0, "nothing changed yet — no marker")
    }

    func testApprovedChangeLeavesOneMarkerAndSettingsCanRevert() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "sysprompt", "--design-sysprompt", "approved", "--design-tab", "chat"]
        app.launch()
        let marker = app.staticTexts["The model added a rule to its instructions · undo in Settings › System prompt"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15), "the quiet marker")
        XCTAssertEqual(app.staticTexts.matching(identifier: "transcript-note").count, 1, "exactly one")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'system_prompt'")).firstMatch.exists, "the tool row is visible")

        app.tabBars.buttons["Settings"].firstMatch.tap()
        let origin = app.staticTexts["settings-system-prompt-origin"].firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 10), "the row carries the caption")
        XCTAssertTrue(origin.label.hasPrefix("changed by the agent"), origin.label)
        app.descendants(matching: .any)["settings-system-prompt"].firstMatch.tap()
        let revert = app.descendants(matching: .any)["system-prompt-revert"].firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: 10), "Revert is offered")
        XCTAssertTrue(revert.label.contains("Revert to the default prompt"), "names what comes back: \(revert.label)")
        XCTAssertTrue(app.descendants(matching: .any)["system-prompt-origin"].firstMatch.exists)
        let editor = app.textViews["system-prompt-editor"].firstMatch
        XCTAssertTrue((editor.value as? String ?? "").contains("Always answer in Turkish"), "the editor shows the agent's text")
        revert.tap()
        XCTAssertFalse(app.descendants(matching: .any)["system-prompt-origin"].firstMatch.waitForExistence(timeout: 2), "the caption is gone after Revert")
        XCTAssertFalse(revert.exists, "history is empty → no second Revert")
        XCTAssertFalse((editor.value as? String ?? "").contains("Always answer in Turkish"), "the previous prompt is back")
    }

    func testToolIsListedInSettingsAsOnByDefaultAndAsksFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        app.launch()
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), "Settings › Tools disclosure")
        if !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        let toggle = app.switches["tool.system_prompt"].firstMatch
        for _ in 0..<6 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "system_prompt has a row")
        XCTAssertEqual(app.staticTexts["tool.system_prompt.default"].firstMatch.label, "on by default")
        XCTAssertTrue(app.staticTexts["tool.system_prompt.asksFirst"].firstMatch.exists, "every write stops at a card")
    }
}
