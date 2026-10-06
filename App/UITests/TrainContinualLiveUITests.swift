import XCTest

/// The round-2 proof (owner pays, ≈ $0.2–0.3): only when `LOOPL_HF_TOKEN` is set (`TEST_RUNNER_LOOPL_HF_TOKEN`, or simctl
/// launchctl setenv on the sim). Dataset = a real app share (`LOOPL_TRAIN_DATASET`, default loopl-e2e-vision-20261006: 112 rows with
/// gen.ts), Continue a model = `LOOPL_CONTINUE` (default loopl-app-sim-4bit → the script trains from its bf16 twin), epochs Auto,
/// Stitch = By day, cheapest cap, output `LOOPL_TRAIN_NAME` (default loopl-app-sim-r2). Confirms on the ApprovalCard — whose body must
/// show `--base cagataydev/loopl-app-sim`, `--epochs auto`, `--stitch day` — and waits for the first `[loopl]` stage.
final class TrainContinualLiveUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func find(_ app: XCUIApplication, _ id: String, scroll: Int = 2, timeout: TimeInterval = 5) -> XCUIElement {
        let q = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if q.waitForExistence(timeout: timeout) { return q }
        for _ in 0..<scroll { app.swipeUp(); if q.waitForExistence(timeout: 2) { return q } }
        return q
    }

    func testLaunchRoundTwoFromTheApp() throws {
        let env = ProcessInfo.processInfo.environment
        let token = env["LOOPL_HF_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "set TEST_RUNNER_LOOPL_HF_TOKEN to launch a real (billed) round-2 job")
        let dataset = env["LOOPL_TRAIN_DATASET"] ?? "loopl-e2e-vision-20261006"
        let continueModel = env["LOOPL_CONTINUE"] ?? "loopl-app-sim-4bit"
        let outName = env["LOOPL_TRAIN_NAME"] ?? "loopl-app-sim-r2"
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "models-train").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        XCTAssertTrue(app.staticTexts["Train your own"].waitForExistence(timeout: 10))

        let picker = app.descendants(matching: .any).matching(identifier: "train-dataset").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "dataset picker never appeared — signed in?")
        picker.tap()
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", dataset)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "dataset \(dataset) not listed"); choice.tap()
        if app.navigationBars.buttons.firstMatch.exists, !app.staticTexts["Train your own"].exists { app.navigationBars.buttons.firstMatch.tap() }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rows, ≈'")).firstMatch
        XCTAssertTrue(rows.waitForExistence(timeout: 60), "row count never read")

        // Continue a model → the tuned base (listed once Mine + owned repos are read)
        let cont = find(app, "train-continue", scroll: 2, timeout: 30)
        XCTAssertTrue(cont.exists, "'Continue a model' never appeared — no Mine models with a bf16 twin?")
        cont.tap()
        let tuned = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", continueModel + " · round")).firstMatch
        XCTAssertTrue(tuned.waitForExistence(timeout: 10), "\(continueModel) not offered as a base: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("round") })")
        let roundLabel = tuned.label
        tuned.tap()
        if app.navigationBars.buttons.firstMatch.exists, !app.staticTexts["Train your own"].exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(find(app, "train-continue-note", scroll: 1).waitForExistence(timeout: 5))
        XCTAssertTrue(find(app, "train-replay", scroll: 1).exists, "Include all previous shards toggle")

        // Stitch by day; epochs stay Auto (recommended)
        let stitch = find(app, "train-stitch", scroll: 1)
        XCTAssertTrue(stitch.exists)
        stitch.buttons["By day"].tap()
        let note = find(app, "train-stitch-note", scroll: 1)
        XCTAssertTrue(note.waitForExistence(timeout: 10) && note.label.contains("stitched"), "day preview: \(note.label)")
        let a1 = XCTAttachment(screenshot: app.screenshot()); a1.name = "r2-form"; a1.lifetime = .keepAlways; add(a1)

        let cap = app.sliders.matching(identifier: "train-cap").firstMatch
        if find(app, "train-cap", scroll: 1).exists { cap.adjust(toNormalizedSliderPosition: 0) }
        let name = find(app, "train-name", scroll: 1)
        if name.exists { name.tap(); name.typeText(outName + "\n") }

        let start = find(app, "train-start", scroll: 2, timeout: 10)
        XCTAssertTrue(start.exists); start.tap()
        let approve = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'approve'")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "ApprovalCard missing")
        let body = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '--base'")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5), "approval shows the script arguments")
        XCTAssertTrue(body.label.contains("--base cagataydev/") && !body.label.contains("-4bit"), "trains from the bf16 twin: \(body.label)")
        XCTAssertTrue(body.label.contains("--epochs auto") && body.label.contains("--stitch day"), body.label)
        let a2 = XCTAttachment(screenshot: app.screenshot()); a2.name = "r2-approval"; a2.lifetime = .keepAlways; add(a2)
        let args = XCTAttachment(string: "ARGS \(roundLabel) :: \(body.label)"); args.name = "args"; args.lifetime = .keepAlways; add(args)
        approve.tap()

        let link = app.staticTexts["Open on Hugging Face"]
        XCTAssertTrue(link.waitForExistence(timeout: 60), "run view never appeared (job not created?)")
        let failed = app.staticTexts["Training failed"]
        let reading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reading' OR label BEGINSWITH 'Rendering' OR label BEGINSWITH 'Training'")).firstMatch
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !reading.exists, !failed.exists { sleep(5) }
        let jobLink = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'huggingface.co/jobs' OR value CONTAINS 'huggingface.co/jobs'")).firstMatch
        if jobLink.exists { let j = XCTAttachment(string: "JOB \(jobLink.label) \(jobLink.value ?? "")"); j.name = "job"; j.lifetime = .keepAlways; add(j) }
        let a3 = XCTAttachment(screenshot: app.screenshot()); a3.name = "r2-running"; a3.lifetime = .keepAlways; add(a3)
        XCTAssertFalse(failed.exists, "job failed: \(app.descendants(matching: .any).matching(identifier: "train-error").firstMatch.label)")
        XCTAssertTrue(reading.exists, "no [loopl] stage within 4 min")
    }
}
