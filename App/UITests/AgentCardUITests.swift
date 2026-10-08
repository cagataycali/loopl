import XCTest

/// Sub-agent cards on the `agents` fixture — no model, no network. Mid-flight: `weather` done (folded to
/// its result line), `notes` waiting for the human (its POST approval card INSIDE the child card), `issues` in the background
/// (its use_agent row returned at once, the child keeps running — folded chip line). Answering the child's card routes to the
/// child: Deny → notes fails, the parent answers. `--design-agents finished`: the wake line + the parent's follow-up.
/// Screenshots → LOOPL_SHOT_DIR: agents-midflight.png agents-denied.png agents-finished.png.
final class AgentCardUITests: XCTestCase {
    private func launch(_ extra: [String] = [], axXL: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "agents"] + extra
        if axXL { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
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

    /// The chat must never be WIDER than the screen. At an accessibility text size the agent fixture's content ran off
    /// BOTH edges — "Helper" read "elper", "issues" read "ssues", the tool name `http` read `ttp` — because one
    /// over-wide child in a vertical stack widens every sibling and the viewport then centres the lot. Photographed on
    /// an iPhone 16 Pro and an iPhone SE before this test existed; the assertion message names what stuck out.
    func testNothingRunsOffTheEdgeAtAccessibilitySize() throws {
        let app = launch(axXL: true)
        XCTAssertTrue(card(app, "agent_n").waitForExistence(timeout: 15), "the fixture drew")
        let screen = app.windows.firstMatch.frame
        var over: [(String, CGRect, CGFloat)] = []
        for el in app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex + app.otherElements.allElementsBoundByIndex {
            let f = el.frame
            // Skipped on purpose, both measured: an unrealised row reports an empty frame, the scroll canvas is far
            // wider than the viewport by design, and a 2 pt decoration is not layout — `IndeterminateBar`'s accent
            // segment SWEEPS by `.offset(x: w)` inside a `clipShape`, so its frame legitimately leaves the screen
            // (measured [63…451] against a track at [63…362]) while nothing of it is ever drawn out there.
            guard f.width > 1, f.height > 4, f.width < screen.width * 3 else { continue }
            let out = max(screen.minX - f.minX, f.maxX - screen.maxX)
            guard out > 1 else { continue }
            over.append((el.label.isEmpty ? el.identifier : el.label, f, out))
        }
        let worst = over.sorted { $0.2 > $1.2 }.prefix(6)
            .map { "\($0.0.prefix(38)) [x \(Int($0.1.minX))…\(Int($0.1.maxX))] over by \(Int($0.2))" }
        XCTAssertTrue(over.isEmpty, "outside the screen (0…\(Int(screen.maxX))): " + worst.joined(separator: " · "))
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
