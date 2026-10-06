import XCTest

/// #21 "answered by X": reopening a thread starts a FRESH context under the model that is loaded now, so the
/// old answers on screen were written by someone else. The chat title says so, and stops claiming it once this
/// session adds a turn ("Earlier answers by X"). The line sits at the top of the transcript, not in the title bar —
/// the inline title is squeezed between two button groups and truncated it on an SE.
final class AnsweredByUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    /// The `answeredby` fixture saves a thread under another model, re-reads it through the archive's decoder and
    /// opens it — so the subtitle is driven by the real `SavedConversation.modelName`, not by test-only state.
    func testReopenedThreadNamesTheModelThatAnsweredIt() {
        let app = launch(["--design-fixture", "answeredby"])
        let provenance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'answered by '")).firstMatch
        XCTAssertTrue(provenance.waitForExistence(timeout: 15), "the transcript says 'Answered by <other model>'")
        let other = (provenance.label as String).replacingOccurrences(of: "Answered by ", with: "")
        XCTAssertFalse(other.isEmpty)
        // It names a DIFFERENT model than the loaded one (whose name is the title itself).
        XCTAssertFalse(app.staticTexts[other].firstMatch.exists && app.navigationBars.staticTexts[other].exists,
                       "the line names the other model, not the loaded one")
    }

    /// A thread started here has nothing to disclaim.
    func testAFreshThreadHasNoProvenanceLine() {
        let app = launch(["--design-fixture", "tool"])
        XCTAssertTrue(app.buttons["New conversation"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'answered by '")).firstMatch.exists,
                       "no model-provenance line on a thread this session wrote")
    }

    /// Sending into the reopened thread makes the claim narrower instead of dropping it.
    func testSendingNarrowsItToEarlierAnswers() {
        let app = launch(["--design-fixture", "answeredby"])
        let provenance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'answered by '")).firstMatch
        XCTAssertTrue(provenance.waitForExistence(timeout: 15))
        let field = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the composer took focus")
        // The message field is multi-line (a UITextView), so Return makes a newline — this is exactly why ⌘↩ exists.
        // Send with the button, which is enabled the moment the draft is non-empty.
        field.typeText("and now?")
        XCTAssertTrue(((field.value as? String) ?? "").contains("and now?"), "the draft is in the field")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled, "Send is enabled with a draft")
        // Put the keyboard away first (a tap on the transcript blurs the composer, keeping the draft): with it up,
        // the Send button's reported frame is the one UNDER the keyboard and the tap lands on a key instead.
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Explain what an agent loop'")).firstMatch.tap()
        usleep(600_000)
        let send2 = app.buttons["Send"].firstMatch
        XCTAssertTrue(send2.waitForExistence(timeout: 5) && send2.isEnabled, "Send still enabled with the keyboard down")
        send2.tap()
        var left = false
        for _ in 0..<20 where !left { left = !(((field.value as? String) ?? "").contains("and now?")); if !left { usleep(200_000) } }
        XCTAssertTrue(left, "the draft left the field — value: \(field.value ?? "nil")")
        let narrowed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'earlier answers by '")).firstMatch
        let ok = narrowed.waitForExistence(timeout: 10)
        if !ok {
            let labels = app.staticTexts.allElementsBoundByIndex.prefix(12).map { "\($0.label)" }.joined(separator: " | ")
            XCTFail("the subtitle becomes 'earlier answers by X' — saw: \(labels)")
        }
    }
}
