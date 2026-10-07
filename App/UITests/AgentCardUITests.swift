import XCTest

/// Sub-agent cards (Phase 6 lane E) on the `agents` fixture — no model, no network. Mid-flight: `weather` done (folded to
/// its result line), `notes` waiting for the human (its POST approval card INSIDE the child card), `issues` in the background
/// (its use_agent row returned at once, the child keeps running — folded chip line). Answering the child's card routes to the
/// child: Deny → notes fails, the parent answers. `--design-agents finished`: the wake line + the parent's follow-up.
/// Screenshots → LOOPL_SHOT_DIR: agents-midflight.png agents-denied.png agents-finished.png.
final class AgentCardUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "agents"] + extra
        app.launch()
        return app
    }
    private func card(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-card-\(id)").firstMatch
    }

    func testMidflightCardsShowStatusAndNestedApproval() throws {
        let app = launch()
        let notes = card(app, "agent_n")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "notes child card")
        XCTAssertTrue(notes.label.contains("agent notes"), notes.label)
        XCTAssertEqual(notes.value as? String, "needs your answer", "status chip is spoken as the card's value (P7-B wording)")
        // The child's approval card is rendered with the parent's component — the same Approve / Deny buttons.
        let approve = app.buttons["Approve"].firstMatch, deny = app.buttons["Deny"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 5) && deny.exists, "nested ApprovalCard inside the child card")
        // Background child: folded to its chip line, value says so.
        let issues = card(app, "agent_i")
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        XCTAssertEqual(issues.value as? String, "background")
        // Done child above the fold: scroll up to find it (folded to its result line).
        app.swipeDown()
        let weather = card(app, "agent_w")
        XCTAssertTrue(weather.waitForExistence(timeout: 5), "weather child card")
        XCTAssertEqual(weather.value as? String, "done")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'result: Hoboken'")).firstMatch.exists, "folded done card keeps its one-line result")
        shoot(app, "agents-midflight")

        // Tap the background chip line → it opens (the child's task + running tool row become visible).
        app.swipeUp()
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        issues.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'task: Summarise'")).firstMatch.waitForExistence(timeout: 5), "tap expands a background card")
        issues.tap()

        // Deny the child's POST → the decision goes to the CHILD: notes fails, its row errors, the parent answers.
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()
        let failed = NSPredicate(format: "value == 'failed'")
        expectation(for: failed, evaluatedWith: notes).fulfillmentWithTimeout(10)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'you declined it'")).firstMatch.waitForExistence(timeout: 10), "parent answers after the child settled")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'result: Not posted'")).firstMatch.exists, "failed card folds to its last line")
        shoot(app, "agents-denied")
    }

    func testFinishedStoryShowsWakeLine() throws {
        let app = launch(["--design-agents", "finished"])
        let issues = card(app, "agent_i")
        XCTAssertTrue(issues.waitForExistence(timeout: 10))
        XCTAssertEqual(issues.value as? String, "done")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Helper issues finished'")).firstMatch.exists, "the parent's wake turn is a quiet line, not a user bubble")
        XCTAssertEqual(card(app, "agent_n").value as? String, "failed")
        // No background strip once everything settled.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "agent-strip-agent_i").firstMatch.exists)
        shoot(app, "agents-finished")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] else { return }
        Thread.sleep(forTimeInterval: 0.6)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

private extension XCTestExpectation {
    func fulfillmentWithTimeout(_ t: TimeInterval) { _ = XCTWaiter.wait(for: [self], timeout: t) }
}
