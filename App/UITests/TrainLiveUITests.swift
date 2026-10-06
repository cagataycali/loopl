import XCTest

/// The ONE real job launched from the app (owner pays): only when `LOOPL_HF_TOKEN` is set (pass it as
/// `TEST_RUNNER_LOOPL_HF_TOKEN`); otherwise the test is skipped. Picks the proven smoke dataset, the cheapest cap
/// (15 min), names the output `loopl-app-sim`, confirms on the ApprovalCard and waits until the job reports its
/// first stage. The job keeps running on Hugging Face after the app is killed; the lane logs id + $ in jobs.log.
final class TrainLiveUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLaunchOneRealJobFromTheApp() throws {
        let token = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "set TEST_RUNNER_LOOPL_HF_TOKEN to launch a real (billed) job")
        let dataset = ProcessInfo.processInfo.environment["LOOPL_TRAIN_DATASET"] ?? "loopl-app-smoke-data"
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "models-train").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        XCTAssertTrue(app.staticTexts["Train your own"].waitForExistence(timeout: 10))

        // dataset picker (real list from /api/datasets?author=me)
        let picker = app.descendants(matching: .any).matching(identifier: "train-dataset").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "dataset picker never appeared — signed in?")
        picker.tap()
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", dataset)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "dataset \(dataset) not listed"); choice.tap()
        if app.navigationBars.buttons.firstMatch.exists, !app.staticTexts["Train your own"].exists { app.navigationBars.buttons.firstMatch.tap() }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rows, ≈'")).firstMatch
        XCTAssertTrue(rows.waitForExistence(timeout: 60), "row count never read: \(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rows'")).firstMatch.label)")
        let a1 = XCTAttachment(screenshot: app.screenshot()); a1.name = "live-form"; a1.lifetime = .keepAlways; add(a1)

        // a distinct output name (the cost cap is automatic since TRAIN-SIMPLIFY)
        app.swipeUp()
        let name = app.descendants(matching: .any).matching(identifier: "train-name").firstMatch
        if name.waitForExistence(timeout: 5) { name.tap(); name.typeText((ProcessInfo.processInfo.environment["LOOPL_TRAIN_NAME"] ?? "loopl-app-sim") + "\n") }

        let start = app.descendants(matching: .any).matching(identifier: "train-start").firstMatch
        if !start.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let approve = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'approve'")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "ApprovalCard missing")
        let a2 = XCTAttachment(screenshot: app.screenshot()); a2.name = "live-confirm"; a2.lifetime = .keepAlways; add(a2)
        approve.tap()

        // the session uploads the script, creates the job, and the first [loopl] stage arrives once the container runs (~1–3 min)
        let link = app.staticTexts["Open on Hugging Face"]
        XCTAssertTrue(link.waitForExistence(timeout: 60), "run view never appeared (job not created?) — \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Could not' OR label CONTAINS 'missing'")).firstMatch.label)")
        let failed = app.staticTexts["Training failed"]
        let reading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading' OR label BEGINSWITH 'Rendering' OR label BEGINSWITH 'Training'")).firstMatch
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !reading.exists, !failed.exists { sleep(5) }
        let jobLink = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'huggingface.co/jobs' OR value CONTAINS 'huggingface.co/jobs'")).firstMatch
        if jobLink.exists { let j = XCTAttachment(string: "JOB \(jobLink.label) \(jobLink.value ?? "")"); j.name = "job"; j.lifetime = .keepAlways; add(j) }
        let a3 = XCTAttachment(screenshot: app.screenshot()); a3.name = "live-running"; a3.lifetime = .keepAlways; add(a3)
        XCTAssertFalse(failed.exists, "job failed: \(app.descendants(matching: .any).matching(identifier: "train-error").firstMatch.label)")
        XCTAssertTrue(reading.exists, "no [loopl] stage within 4 min")
    }
}
