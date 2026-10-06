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
    /// A finger-speed drag across the headline band (XCUI's `swipeLeft` from the centre lands on the live scene's
    /// buttons and reads as a tap there).
    private func swipePage(_ app: XCUIApplication) {
        let pager = el(app, "onboarding-pager")
        let from = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.12))
        let to = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.12))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.0)
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
        swipePage(app)
        XCTAssertTrue(el(app, "onboarding-page-2").waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Pick a model")
        next.tap()

        let cont = el(app, "onboarding-continue")
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        // OUR models, smallest first, 2B preselected — never the Qwen picks.
        for id in ["loopl-0.8b-4bit", "loopl-2b-4bit", "loopl-4b-4bit"] {
            XCTAssertTrue(el(app, "onboarding-card-\(id)").exists, "card \(id)")
        }
        XCTAssertFalse(el(app, "onboarding-card-qwen3-0.6b-4bit").exists, "the Qwen picks are gone")
        XCTAssertTrue(cont.label.contains("loopl 2B"), "2B is the preselected pick: \(cont.label)")
        XCTAssertTrue(el(app, "onboarding-card-loopl-2b-4bit").label.contains("Recommended · fast + smart"), "2B carries the badge")
        XCTAssertTrue(el(app, "onboarding-network").exists)
        XCTAssertTrue(el(app, "onboarding-apple-fm").exists, "Apple Intelligence is a card under the picks (here: the not-available line)")
        el(app, "onboarding-card-loopl-0.8b-4bit").tap()
        XCTAssertTrue(cont.label.contains("loopl 0.8B"), "Continue follows the pick: \(cont.label)")
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

    /// A private pick with nobody signed in never dead-ends: Download → the sign-in step (Hugging Face / Apple
    /// Intelligence / pick another), Back returns to the cards. `--design-gated` forces the step whatever models.json says.
    func testGatedPickAsksForSignIn() {
        let app = launch(["--design-onboarding-step", "pick", "--design-gated", "--design-apple-fm"])
        let cont = el(app, "onboarding-continue")
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        cont.tap()
        XCTAssertTrue(el(app, "onboarding-signin").waitForExistence(timeout: 5), "the sign-in step replaces the cards")
        XCTAssertTrue(el(app, "onboarding-signin-go").exists)
        XCTAssertTrue(el(app, "onboarding-signin-apple").exists, "Apple Intelligence is the no-account way out")
        XCTAssertFalse(cont.exists, "no Download button under the sign-in step")
        el(app, "onboarding-signin-go").tap()
        XCTAssertTrue(el(app, "onboarding-hf-token").waitForExistence(timeout: 5), "the token sheet opens")
        app.buttons["Later"].firstMatch.tap()
        XCTAssertTrue(el(app, "onboarding-signin").waitForExistence(timeout: 5))
        el(app, "onboarding-signin-back").tap()
        XCTAssertTrue(cont.waitForExistence(timeout: 5), "Pick another model returns to the cards")
        XCTAssertTrue(el(app, "onboarding-card-loopl-2b-4bit").exists)
    }

    /// Signed in (`--design-mine`), the same gated pick downloads straight away — the step never shows.
    func testGatedPickDownloadsWhenSignedIn() {
        let app = launch(["--design-onboarding-step", "pick", "--design-gated", "--design-mine"])
        let cont = el(app, "onboarding-continue")
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        cont.tap()
        XCTAssertTrue(el(app, "onboarding-progress").waitForExistence(timeout: 5), "download starts")
        XCTAssertFalse(el(app, "onboarding-signin").exists)
        XCTAssertFalse(el(app, "onboarding-hf").exists, "no account question — already signed in")
    }

    /// Apple Intelligence is a full-width card: available → tapping it finishes with no download.
    func testAppleIntelligenceCardStarts() {
        let app = launch(["--design-onboarding-step", "pick", "--design-apple-fm"])
        let card = el(app, "onboarding-apple-fm")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("no download"), card.label)
        app.swipeUp()
        card.tap()
        XCTAssertTrue(el(app, "onboarding-progress").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "onboarding-progress").waitForNonExistence(timeout: 15), "Apple Intelligence is ready at once; the flow closes")
    }

    /// On a 6 GB phone the 4B card says so (fit badge + one line) and 2B stays the pick.
    func testFitBadgeOnSmallPhone() {
        let app = launch(["--design-onboarding-step", "pick", "--design-ram-gb", "6"])
        XCTAssertTrue(el(app, "onboarding-continue").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "onboarding-fit-loopl-4b-4bit").exists, "4B explains why it is tight/too big")
        XCTAssertFalse(el(app, "onboarding-fit-loopl-2b-4bit").exists, "2B fits")
        XCTAssertTrue(el(app, "onboarding-continue").label.contains("loopl 2B"))
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

    /// Not a check — a performance. `LOOPL_ONBOARDING_DEMO=1` walks the flow at human pace (each scene plays out,
    /// one page is swiped, the ring fills) so `simctl io recordVideo` running alongside captures the real motion.
    func testDemoWalkthrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPL_ONBOARDING_DEMO"] == "1", "demo recording only")
        let app = launch()
        XCTAssertTrue(el(app, "onboarding-page-0").waitForExistence(timeout: 12))   // the intro plays out by itself
        Thread.sleep(forTimeInterval: 6.5)
        el(app, "onboarding-next").tap()
        Thread.sleep(forTimeInterval: 2.0)
        el(app, "onboarding-approval").buttons["Approve"].firstMatch.tap()           // the human approves
        Thread.sleep(forTimeInterval: 3.5)
        swipePage(app)                                                                   // turn the page by hand
        Thread.sleep(forTimeInterval: 6.5)
        el(app, "onboarding-next").tap()
        Thread.sleep(forTimeInterval: 1.4)
        el(app, "onboarding-card-loopl-0.8b-4bit").tap()
        Thread.sleep(forTimeInterval: 1.0)
        el(app, "onboarding-continue").tap()
        Thread.sleep(forTimeInterval: 2.2)
        el(app, "onboarding-hf-later").tap()
        XCTAssertTrue(el(app, "onboarding-progress").waitForNonExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Not a check — captures. `LOOPL_ONBOARDING_SHOTS=<dir>` writes the pick stage scrolled to the Apple Intelligence
    /// card and the sign-in step as PNGs (lane evidence; the ASC set comes from scripts/appstore-screenshots.sh).
    func testShootPickStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_ONBOARDING_SHOTS"], !dir.isEmpty else { throw XCTSkip("captures only") }
        func shoot(_ app: XCUIApplication, _ name: String) {
            let png = app.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let app = launch(["--design-onboarding-step", "pick", "--design-apple-fm", "--design-ram-gb", "6"])
        XCTAssertTrue(el(app, "onboarding-continue").waitForExistence(timeout: 10))
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.0)
        shoot(app, "pick-apple-card")
        app.terminate()
        let gated = launch(["--design-onboarding-step", "pick", "--design-gated", "--design-apple-fm"])
        XCTAssertTrue(el(gated, "onboarding-continue").waitForExistence(timeout: 10))
        el(gated, "onboarding-continue").tap()
        XCTAssertTrue(el(gated, "onboarding-signin").waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        shoot(gated, "pick-signin-step")
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
