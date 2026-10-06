import XCTest

/// First-run onboarding v2: mark intro → three live story pages (paged, swipeable, each skippable) → pick the first
/// model → the ring until it is ready → the flow closes itself. `--design-fixture onboarding` scripts the download
/// (no network, no weights); `--design-onboarding-step story|pick --design-onboarding-page N` lands on one stage.
final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "onboarding"] + extra
        app.launch()
        return app
    }
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The whole thing, the way a new user meets it: intro → tap → Continue ×2 → swipe → Pick a model → pick → ring → chat.
    func testFullFlowToReady() {
        let app = launch()
        let intro = el(app, "onboarding-intro")
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        intro.tap()                                                      // skip the rest of the intro
        let page0 = el(app, "onboarding-page-0")
        XCTAssertTrue(page0.waitForExistence(timeout: 5))
        let next = el(app, "onboarding-next")
        XCTAssertEqual(next.label, "Continue")
        next.tap()
        XCTAssertTrue(el(app, "onboarding-page-1").waitForExistence(timeout: 5))
        // The pages follow the finger: a swipe is the other way to turn one.
        el(app, "onboarding-pager").swipeLeft()
        XCTAssertTrue(el(app, "onboarding-page-2").waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Pick a model")
        next.tap()

        let cont = el(app, "onboarding-continue")
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        for id in ["qwen3-0.6b-4bit", "qwen3.5-0.8b-4bit", "qwen3.5-2b-4bit"] {
            XCTAssertTrue(el(app, "onboarding-card-\(id)").exists, "card \(id)")
        }
        XCTAssertTrue(cont.label.contains("335"), "default pick is the 335 MB model: \(cont.label)")
        XCTAssertTrue(el(app, "onboarding-network").exists)
        el(app, "onboarding-card-qwen3.5-0.8b-4bit").tap()
        XCTAssertTrue(cont.label.contains("Qwen3.5 0.8B"), "Continue follows the pick: \(cont.label)")
        cont.tap()
        let progress = el(app, "onboarding-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "onboarding-mark").exists)
        XCTAssertTrue(el(app, "onboarding-hf").exists, "the download's dead time offers the optional Hugging Face sign-in")
        el(app, "onboarding-hf-later").tap()
        XCTAssertTrue(el(app, "onboarding-hf").waitForNonExistence(timeout: 3))
        // Scripted ~4 s download + load → "Ready" → the flow closes on its own.
        XCTAssertTrue(progress.waitForNonExistence(timeout: 15), "closes itself once the model is ready")
        XCTAssertFalse(cont.exists)
    }

    /// The intro advances by itself (≤ 2.5 s) when nobody taps.
    func testIntroAutoAdvances() {
        let app = launch()
        XCTAssertTrue(el(app, "onboarding-intro").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "onboarding-page-0").waitForExistence(timeout: 6), "story starts without a tap")
    }

    /// Skip is on every stage and goes straight to the chat.
    func testSkipFromStoryCloses() {
        let app = launch(["--design-onboarding-step", "story"])
        let skip = el(app, "onboarding-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(el(app, "onboarding-next").waitForNonExistence(timeout: 5))
    }

    func testSkipFromPickCloses() {
        let app = launch(["--design-onboarding-step", "pick"])
        let skip = el(app, "onboarding-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "onboarding-continue").exists)
        skip.tap()
        XCTAssertTrue(el(app, "onboarding-continue").waitForNonExistence(timeout: 5))
    }

    /// Page 2 is the REAL approval card: tapping Approve in the preview runs the scripted tool row.
    func testApprovalPageIsLive() {
        let app = launch(["--design-onboarding-step", "story", "--design-onboarding-page", "1"])
        let card = el(app, "onboarding-approval")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let approve = card.buttons["Approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 3))
        approve.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'tool http'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the http tool row follows the approval")
    }

    /// Back from the model pick returns to the story.
    func testBackToStory() {
        let app = launch(["--design-onboarding-step", "pick"])
        let back = el(app, "onboarding-back")
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(el(app, "onboarding-page-0").waitForExistence(timeout: 5))
    }

    /// Settings › About › "Show intro again" replays the flow on an installed app.
    func testReplayFromSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        app.launch()
        let list = app.collectionViews["pane-settings"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Settings"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        let row = app.buttons["Show intro again"].firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(el(app, "onboarding-intro").waitForExistence(timeout: 5), "the intro plays again")
        el(app, "onboarding-intro").tap()
        XCTAssertTrue(el(app, "onboarding-skip").waitForExistence(timeout: 5))
        el(app, "onboarding-skip").tap()
        XCTAssertTrue(el(app, "onboarding-next").waitForNonExistence(timeout: 5))
    }
}
