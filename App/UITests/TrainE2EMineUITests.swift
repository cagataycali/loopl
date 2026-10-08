import XCTest

/// TRAIN-E2E-VISION step 4: the model trained from the app shows up in Models › Mine (with its vision badge) and
/// downloads in the simulator. Needs LOOPL_HF_TOKEN + LOOPL_MINE_REPO (e.g. cagataydev/loopl-app-e2e-vision-4bit) in the
/// runner env (`xcrun simctl spawn <udid> launchctl setenv …`); skipped otherwise. MLX is compiled out on the simulator,
/// so the proof is "download completes"; the audit checks the files on disk and runs the image chat on macOS.
final class TrainE2EMineUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTrainedModelIsInMineAndDownloads() throws {
        let env = ProcessInfo.processInfo.environment
        let token = env["LOOPL_HF_TOKEN"] ?? "", repo = env["LOOPL_MINE_REPO"] ?? ""
        try XCTSkipIf(token.isEmpty || repo.isEmpty, "needs LOOPL_HF_TOKEN + LOOPL_MINE_REPO")
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()

        let hit = app.buttons["mine-hit-\(repo)"].firstMatch
        var tries = 0
        while !hit.waitForExistence(timeout: 10), tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(hit.exists, "\(repo) not in Models › Mine")
        Thread.sleep(forTimeInterval: 2)
        note("MINE-ROW \(hit.label)")
        shot(app, "mine-row")
        hit.tap()

        let download = app.buttons["hub-download"]
        XCTAssertTrue(download.waitForExistence(timeout: 30), "repo sheet did not load")
        shot(app, "mine-sheet")
        download.tap()
        XCTAssertFalse(app.staticTexts["hub-download-refused"].waitForExistence(timeout: 3), "download refused")
        if app.buttons["Close"].firstMatch.exists { app.buttons["Close"].firstMatch.tap() }

        let downloading = app.descendants(matching: .any)["mine-downloading-\(repo)"].firstMatch
        let failed = app.staticTexts["mine-failed-\(repo)"].firstMatch
        _ = downloading.waitForExistence(timeout: 20)
        shot(app, "mine-downloading")
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline, downloading.exists, !failed.exists { sleep(5) }
        XCTAssertFalse(failed.exists, "download failed: \(failed.label)")
        XCTAssertFalse(downloading.exists, "download did not finish within 15 min")
        Thread.sleep(forTimeInterval: 2)
        note("MINE-ROW-AFTER \(app.buttons["mine-hit-\(repo)"].firstMatch.label)")
        shot(app, "mine-downloaded")
    }

    private func note(_ s: String) { let a = XCTAttachment(string: s); a.name = "note"; a.lifetime = .keepAlways; add(a); print(s) }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "SHOT \(name)"; a.lifetime = .keepAlways; add(a)
    }
}
