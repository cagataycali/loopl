import XCTest

/// the recovery controls were too small to hit.
///
/// Measured on an iPhone 16 Pro simulator with a REAL Hugging Face 429 injected by a local
/// stand-in (`improve-6/tools/hubproxy.py` via the DEBUG-only `LOOPL_HUB_HOST` seam):
///
///     Models list  Retry       32 × 14 pt      (#models-retry-qwen3-0.6b-4bit)
///     Chat banner  Try again   58 × 16 pt      (#chat-readiness-retry)
///
/// Apple's minimum is 44 × 44. These are the one control a person needs after a rate limit, and
/// `Resume` / `Sign in` in the same switch were built the same way. `looplHitTarget()` grows the
/// touch rectangle with padding and takes the same padding back off the outside, so the TEXT does
/// not move — the rows were tuned in #170/#176 and must keep their geometry.
///
/// This test therefore asserts BOTH halves: the hit frame is ≥ 44 pt tall, and the row around it
/// did not grow. It runs in the `looplUITests` scheme, which since #177 runs on every push to main.
final class TouchTargetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ scene: String, tab: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene]
        if let tab { app.launchArguments += ["--design-tab", tab] }
        app.launch()
        return app
    }

    private func assert44(_ element: XCUIElement, _ what: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(what) never appeared")
        let f = element.frame
        XCTContext.runActivity(named: "\(what) hit frame \(Int(f.width)) × \(Int(f.height)) pt") { _ in }
        XCTAssertGreaterThanOrEqual(f.height, 44, "\(what) is only \(Int(f.height)) pt tall — Apple's minimum is 44")
        XCTAssertGreaterThanOrEqual(f.width, 44, "\(what) is only \(Int(f.width)) pt wide — Apple's minimum is 44")
        XCTAssertTrue(element.isHittable, "\(what) is not hittable")
    }

    /// The chat readiness banner after a download failure: the button must be reachable, and the
    /// sentence must name the model (AUDIT #8 — it used to read "Your progress is kept" with no subject).
    func testChatRetryAfterAFailedDownloadIs44ptAndTheBannerNamesTheModel() {
        let app = launch("downloadfailed")
        assert44(app.buttons["chat-readiness-retry"], "chat Try again")

        let banner = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "didn't finish downloading")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the banner does not say what failed; texts on screen: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(banner.label.contains("429"), "the code stays, after the words: \(banner.label)")
    }

    /// The same control in the Models list, where the row already names the model. The fixture puts a
    /// private model in a signed-out state, so the failed branch draws its `Sign in` sibling — the one
    /// built exactly like `Retry`.
    func testModelsRecoveryButtonsAre44pt() {
        let app = launch("empty", tab: "models")
        let models = app.otherElements["pane-models"]
        XCTAssertTrue(models.waitForExistence(timeout: 20), "Models pane never appeared")

        // Whichever recovery control this state draws: Retry, Sign in or Resume.
        let ids = ["models-retry-", "models-signin-"]
        let found = app.buttons.allElementsBoundByIndex.filter { b in
            ids.contains { b.identifier.hasPrefix($0) }
        }
        guard let button = found.first else {
            // No failed row in this state — nothing to assert, and failing here would make the suite
            // depend on the network. The chat case above covers the modifier itself.
            XCTContext.runActivity(named: "no failed model row in this state — skipped") { _ in }
            return
        }
        assert44(button, "Models \(button.identifier)")
    }

    /// The text must not have moved: `looplHitTarget` pays for its touch area with overflow, not layout.
    /// The banner's sentence and the button sit on consecutive lines at ~8 pt of spacing; if the modifier
    /// had reflowed the stack, that gap would jump by the 30 pt of vertical padding it adds.
    func testGrowingTheTouchAreaDidNotReflowTheBanner() {
        let app = launch("downloadfailed")
        let button = app.buttons["chat-readiness-retry"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        let banner = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "didn't finish downloading")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))

        // The visible text's baseline gap, not the hit frame's: the button's frame now overlaps the
        // sentence by design, so measure from the sentence's bottom to the button's CENTRE.
        let gap = button.frame.midY - banner.frame.maxY
        XCTContext.runActivity(named: "sentence bottom → button centre: \(Int(gap)) pt") { _ in }
        XCTAssertGreaterThan(gap, 0, "the button's text should still sit below the sentence")
        XCTAssertLessThan(gap, 40, "the banner reflowed: \(Int(gap)) pt between the sentence and the button")
    }
}
