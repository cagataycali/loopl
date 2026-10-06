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
}
