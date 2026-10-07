import XCTest

/// Share to Hugging Face (Phase 5): History › Select → pick conversations → sheet (review, redaction,
/// preview) → token → dataset → push → link. Screenshots of every stage are attached to the result bundle
/// (`SHOT <name>`), which is how the lane's captures are produced.
///
/// `testSharePushesForReal` pushes to a PRIVATE test dataset when the runner passes a Hugging Face write
/// token (`TEST_RUNNER_LOOPL_HF_TOKEN`, which xcodebuild forwards to the app as `LOOPL_HF_TOKEN`); it is
/// skipped otherwise, so CI stays offline. (A UI-test runner does not receive `TEST_RUNNER_*` variables — on a
/// simulator set it with `xcrun simctl spawn <udid> launchctl setenv LOOPL_HF_TOKEN hf_…` before the run.) Target dataset: `TEST_RUNNER_LOOPL_HF_SHARE_REPO`
/// (bare name, default `loopl-app-conversations-test`) — creating it a second time is a 409 the app treats
/// as "append", exactly the second-share path.
final class HubShareUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var token: String? {
        let t = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"] ?? ""
        return t.isEmpty ? nil : t
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "history"]
        // LOOPL_HF_SHARE_CORPUS=N adds N deterministic threads (every 8th with a picture) — the TRAIN-E2E-VISION share.
        if let n = ProcessInfo.processInfo.environment["LOOPL_HF_SHARE_CORPUS"], Int(n) != nil { app.launchArguments += ["--design-history-corpus", n] }
        if signedIn, let token { app.launchEnvironment["LOOPL_HF_TOKEN"] = token }
        else { app.launchEnvironment["LOOPL_HF_TOKEN"] = ""; app.launchArguments.append("--design-signed-out") }
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "SHOT \(name)"; a.lifetime = .keepAlways
        add(a)
    }

    /// Open History, enter selection mode, select everything, tap Share — returns once the sheet's review step is up.
    private func openShareSheet(_ app: XCUIApplication) {
        let select = app.reachHistory()
        shot("01-history")
        select.tap()
        let all = app.buttons["history.selectAll"]
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        let share = app.buttons["history.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled, "Share enabled once something is selected")
        shot("02-history-selected")
        share.tap()
        XCTAssertTrue(app.buttons["hubshare.continue"].waitForExistence(timeout: 10), "review step")
    }

    /// Review + redaction + preview + the signed-out token step — no network.
    func testReviewAndSignedOutState() {
        let app = launch(signedIn: false)
        openShareSheet(app)
        // 2 of 3 are shareable: the third thread's only tool row never finished.
        XCTAssertTrue(app.staticTexts["2 of 3 conversations will be shared"].waitForExistence(timeout: 5))
        shot("03-review")
        app.switches["Remove tool results"].firstMatch.tap()
        let preview = app.staticTexts["Preview"].firstMatch
        if preview.waitForExistence(timeout: 3) { preview.tap() }
        shot("04-review-redacted-preview")
        app.buttons["hubshare.continue"].tap()
        let tokenField = app.secureTextFields["hubshare.token"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 8), "signed-out → token step")
        XCTAssertFalse(app.buttons["hubshare.verify"].isEnabled, "Verify disabled until a plausible token")
        shot("05-token")
        tokenField.tap(); tokenField.typeText("not-a-token")
        XCTAssertFalse(app.buttons["hubshare.verify"].isEnabled, "junk is refused before any network")
        app.buttons["hubshare.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["history.select"].waitForExistence(timeout: 5), "back in History, selection cleared")
    }

    /// The whole thing, for real: verify → dataset step → push → success link.
    func testSharePushesForReal() throws {
        guard let token, token.hasPrefix("hf_") else { throw XCTSkip("no TEST_RUNNER_LOOPL_HF_TOKEN — live push skipped") }
        let repoName = ProcessInfo.processInfo.environment["LOOPL_HF_SHARE_REPO"] ?? "loopl-app-conversations-test"
        let app = launch(signedIn: true)
        openShareSheet(app)
        app.buttons["hubshare.continue"].tap()
        // Token comes from the environment → the sheet verifies it and lands on the dataset step.
        let push = app.buttons["hubshare.push"]
        XCTAssertTrue(push.waitForExistence(timeout: 30), "dataset step after whoami")
        // Always target the TEST dataset by name — never whatever the picker defaulted to.
        let picker = app.buttons["hubshare.repoPicker"].firstMatch
        if picker.waitForExistence(timeout: 3) {
            picker.tap()
            let new = app.buttons["New private dataset"].firstMatch
            if new.waitForExistence(timeout: 3) { new.tap() } else { app.tap() }
        }
        let name = app.textFields["hubshare.repoName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // The default name is real text (not just a placeholder) — clear it; extra deletes on an empty field are no-ops.
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 48))
        name.typeText(repoName)
        app.keyboards.buttons["Return"].firstMatch.exists ? app.keyboards.buttons["Return"].firstMatch.tap() : ()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "/\(repoName)")).firstMatch.waitForExistence(timeout: 5), "repository line shows owner/\(repoName)")
        shot("06-dataset")
        push.tap()
        let shared = app.staticTexts["hubshare.shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 240), "push finished")
        let url = app.staticTexts["hubshare.doneURL"].firstMatch
        XCTAssertTrue(url.exists)
        let link = url.label.isEmpty ? ((url.value as? String) ?? "") : url.label
        let a = XCTAttachment(string: "DONE_URL \(link)\n"); a.name = "done-url"; a.lifetime = .keepAlways; add(a)
        shot("07-shared")
        app.buttons["hubshare.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["history.select"].waitForExistence(timeout: 5))
    }
}
