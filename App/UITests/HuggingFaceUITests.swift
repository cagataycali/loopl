import XCTest

/// Settings › Hugging Face renders in both states and the row is reachable above the tab bar.
/// Signed-in state needs a token in this simulator's Keychain (the self-test harness
/// `--selftest-hf-token` puts it there); otherwise the signed-out form is captured instead.
/// Screenshots go to $LOOPL_SHOT_DIR when set (lane evidence), always to the result bundle.
final class HuggingFaceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHuggingFaceSectionIsVisibleAndReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        if let token = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"], !token.isEmpty { app.launchEnvironment["LOOPL_HF_TOKEN"] = token }
        app.launch()
        let list = app.collectionViews["pane-settings"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Settings"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        // Identifiers set on List rows do not always survive into the a11y tree; the labels do.
        let identity = app.buttons["Remove token"].firstMatch
        let field = app.buttons["Verify"].firstMatch
        // Scroll DOWN in screen-sized steps, not flings. `swipeUp(velocity: .fast)` is a momentum scroll, and the
        // shorter the screen the further it travels relative to the content: on an iPhone SE the twelve fast swipes
        // flew past Hugging Face to the bottom of Settings and then did nothing at all, twelve times — the section
        // was never missing, it was behind the test's own momentum. (Measured: fails on an SE, passes on a 16 Pro;
        // the CI runner picked the tallest iPhone, so nobody could see it.) A plain `swipeUp()` moves about one
        // screen, and the loop gives up when the list stops producing anything new rather than swiping into the void.
        // Scroll DOWN until the section EXISTS, in screen-sized steps rather than flings, giving up when the list
        // stops producing anything new instead of swiping into the void.
        let present = { identity.exists || field.exists }
        var lastSeen = ""
        for _ in 0..<20 {
            if present() { break }
            list.swipeUp()
            let bottom = list.staticTexts.allElementsBoundByIndex.last?.label ?? ""
            if bottom == lastSeen { break }     // the list did not move: we are at the end
            lastSeen = bottom
        }
        XCTAssertTrue(present(), "Hugging Face is somewhere in Settings; the last row seen was \(lastSeen)")

        // Existing is not reachable. MEASURED on an iPhone SE (375 × 667): one screen-sized swipe lands the
        // signed-out form with **Verify at y = 3** — under the navigation bar — and it stays unhittable through a
        // full second of settling, so this is geometry, not a race. On a 16 Pro the same swipe leaves it in the
        // middle of the screen, which is why this test passed everywhere anyone looked: the CI runner picks the
        // tallest iPhone it has. The signed-in identity row already had this remedy (nudge the list back ~150 pt);
        // the signed-out form never did. Nudge down until it is genuinely tappable, which is what a thumb would do.
        let row = identity.exists ? identity : field
        for _ in 0..<4 where !row.isHittable {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05,
                       thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(row.isHittable, "the Hugging Face row must be reachable, not parked under a bar: \(row.frame)")
        Thread.sleep(forTimeInterval: 1.5)   // avatar + any whoami refresh
        let signedIn = identity.exists
        // Fast swipes overshoot and park the identity row (avatar + name) under the nav bar — isHittable still says yes
        // through the blur, so always nudge the list back by ~150 pt once the Remove row is on screen.
        // (The old signed-in-only nudge lived here; `nudge into reach` above now covers both states.)
        let name = signedIn ? "settings-hf-signed-in" : "settings-hf-signed-out"
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        XCTAssertTrue(signedIn || field.exists, "neither the identity row nor the token field is on screen")
        if signedIn {
            XCTAssertTrue(app.staticTexts["read granted"].exists || app.staticTexts["read not granted"].exists || app.staticTexts["read"].exists, "scope badges missing")
        } else {
            XCTAssertTrue(app.secureTextFields.firstMatch.exists, "token field missing")
        }
        XCTContext.runActivity(named: name) { a in
            let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; att.name = name; a.add(att)
        }
        print("HF-UI state=\(signedIn ? "signed-in" : "signed-out")")
    }

    /// Models › Mine: signed in (token via LOOPL_HF_TOKEN → the app's HFAccount env override; pass it as
    /// TEST_RUNNER_LOOPL_HF_TOKEN) the section lists the account's repos with the private badge; signed out
    /// it is one row pointing at Settings. Captures models-mine-signed-in.png / models-mine-signed-out.png.
    func testModelsMineSection() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        let token = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"] ?? ""
        if !token.isEmpty { app.launchEnvironment["LOOPL_HF_TOKEN"] = token }
        app.launch()
        let list = app.collectionViews["pane-models"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Models"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        let signedOutRow = app.staticTexts["Your Hugging Face models"].firstMatch
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Mine · @'")).firstMatch
        // Mine is the LAST section (owner's order: On this iPhone → Browse → Train → loopl models → Mine): scroll down to it.
        for _ in 0..<6 where !(header.exists || signedOutRow.exists) { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 20) || signedOutRow.waitForExistence(timeout: 5), "Mine section missing")
        let signedIn = header.exists
        if signedIn {
            // whoami + /api/models?author= on the network: give the rows time, then expect at least one repo or the empty row.
            let anyHit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mine-hit-'")).firstMatch
            // IMPROVE-9: this matched the empty state BY LABEL ("No MLX or GGUF repos…"), which #207 rewords.
            // Precisely what that would have cost, because overclaiming it is easy: this suite is NOT skipped
            // in ui.yml, but the assertion sits inside `if signedIn`, so with no Hugging Face token in CI it is
            // never evaluated. It would have become a LATENT failure — invisible until the first signed-in run,
            // which is the same shape as the ⌘Y probe #204 found. The view has carried
            // `.accessibilityIdentifier("mine-empty")` all along.
            // FIND A ROW BY IDENTIFIER, NEVER BY LABEL (IMPROVE-6 #180/#183).
            let empty = app.descendants(matching: .any)["mine-empty"].firstMatch
            XCTAssertTrue(anyHit.waitForExistence(timeout: 30) || empty.exists, "neither a repo row nor the empty state")
            if anyHit.exists { XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private")).firstMatch.exists, "the owner's account has private repos — badge missing") }
        }
        Thread.sleep(forTimeInterval: 1.0)
        let name = signedIn ? "models-mine-signed-in" : "models-mine-signed-out"
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        XCTContext.runActivity(named: name) { a in
            let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; att.name = name; a.add(att)
        }
        print("HF-UI mine state=\(signedIn ? "signed-in" : "signed-out")")
    }
}
