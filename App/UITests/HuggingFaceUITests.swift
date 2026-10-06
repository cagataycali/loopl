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
        for _ in 0..<12 {
            if (identity.exists && identity.isHittable) || (field.exists && field.isHittable) { break }
            list.swipeUp(velocity: .fast)
        }
        Thread.sleep(forTimeInterval: 1.5)   // avatar + any whoami refresh
        let signedIn = identity.exists
        // Fast swipes overshoot and park the identity row (avatar + name) under the nav bar — isHittable still says yes
        // through the blur, so always nudge the list back by ~150 pt once the Remove row is on screen.
        if signedIn {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            Thread.sleep(forTimeInterval: 1.0)
        }
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
        XCTAssertTrue(header.waitForExistence(timeout: 20) || signedOutRow.waitForExistence(timeout: 5), "Mine section missing")
        let signedIn = header.exists
        if signedIn {
            // whoami + /api/models?author= on the network: give the rows time, then expect at least one repo or the empty row.
            let anyHit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mine-hit-'")).firstMatch
            let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No MLX or GGUF repos'")).firstMatch
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
