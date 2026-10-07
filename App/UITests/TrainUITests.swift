import XCTest

/// Models › Train your own, on the `--design-train` fixtures (no network, no token, no money):
/// form → tap Train → ApprovalCard appears (nothing launches without it); running ladder shows the live step;
/// done shows the result; failed marks the broken stage. One screenshot per scene lands in the result bundle.
final class TrainUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-train", scene]
        app.launch()
        return app
    }

    /// SwiftUI puts a row's identifier on the cell, the button or a static text depending on the container — search everything, scrolling as needed.
    /// Find by identifier, scrolling if needed. `scroll:` used to be a literal number of swipes chosen per call
    /// site (1 almost everywhere), which is a screen-height assumption in disguise: on an iPhone SE `train-manual`
    /// is more than one swipe down the form, so `find` returned a query matching nothing and the next `.tap()`
    /// failed with *"Failed to tap train-manual: No matches found"* — a missing element, not a missing feature.
    /// The number is a CEILING now, and the loop stops early when the screen stops producing anything new, so it
    /// costs nothing on a tall phone. `scroll: 0` keeps its exact meaning: must be there without scrolling.
    private func find(_ app: XCUIApplication, _ id: String, scroll: Int = 4, timeout: TimeInterval = 10) -> XCUIElement {
        let q = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if q.waitForExistence(timeout: timeout) { return q }
        let limit = scroll == 0 ? 0 : max(scroll, 8)
        var lastSeen = ""
        for _ in 0..<limit {
            app.swipeUp()
            if q.waitForExistence(timeout: 2) { return q }
            let bottom = app.staticTexts.allElementsBoundByIndex.last?.label ?? ""
            if bottom == lastSeen { break }
            lastSeen = bottom
        }
        // Then UPWARD, because scrolling one way only made some elements unreachable by construction. Measured on
        // an iPhone SE: expanding the "More options" DisclosureGroup pushes its own label off the TOP of a short
        // screen, so the second tap on `train-manual` could never find it — at the failure `train-epochs-note`,
        // `train-flavor` and `train-method` were all present while `train-base` and `train-name`, which sit ABOVE
        // the label, were not. The viewport had moved below the thing we were looking for, and `find` only ever
        // swiped further down. On a 16 Pro the label stays on screen, which is why this passed everywhere anyone
        // looked.
        for _ in 0..<limit {
            app.swipeDown()
            if q.waitForExistence(timeout: 2) { return q }
            let top = app.staticTexts.allElementsBoundByIndex.first?.label ?? ""
            if top == lastSeen { break }
            lastSeen = top
        }
        return q
    }

    /// Tap something found by identifier, after proving it is really on screen. XCUITest taps a button's CENTRE
    /// whether or not it is visible, so tapping an off-screen element hits whatever happens to be at those
    /// coordinates and the failure surfaces somewhere else entirely.
    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let el = find(app, id)
        XCTAssertTrue(el.exists, "\(id) is not on this screen at all", file: file, line: line)
        XCTAssertTrue(el.isHittable, "\(id) exists but cannot be tapped: \(el.frame)", file: file, line: line)
        el.tap()
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testFormConfirmsThroughApprovalCardAndEstimateIsVisible() {
        let app = launch("form")
        XCTAssertTrue(app.staticTexts["Train your own"].waitForExistence(timeout: 15))
        XCTAssertTrue(find(app, "train-base", scroll: 0).exists, "base picker missing")
        // one-glance form (TRAIN-SIMPLIFY): Base model · Continue a model · Epochs: Auto (recommended) · name; everything else under "Fine-tune manually"
        XCTAssertTrue(find(app, "train-continue", scroll: 1).exists, "'Continue a model' picker missing (Mine bases)")
        let epochs = find(app, "train-epochs", scroll: 1)
        XCTAssertTrue(epochs.exists && epochs.label.contains("Auto (recommended)"), "Passes row: \(epochs.label)")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "train-stitch").firstMatch.exists, "the Stitch picker is gone — the script decides")
        XCTAssertFalse(app.sliders.firstMatch.exists, "no 'Stop after' slider — the cost guard is automatic")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "train-epochs-picker").firstMatch.exists, "the 1–4 picker is folded until 'Fine-tune manually' opens")
        let summary = find(app, "train-summary", scroll: 1)
        XCTAssertTrue(summary.exists && summary.label.hasPrefix("Starts from loopl 0.8B and learns from your 191 conversations in up to 3 passes, keeping the one that scores best"), "plain-words plan: \(summary.label)")
        let blocked = find(app, "train-continue-blocked", scroll: 1)
        XCTAssertTrue(blocked.exists && blocked.label.contains("loopl-old"), "a Mine model without a bf16 twin is named as not continuable")
        shoot(app, "train-form")
        // the disclosure opens the manual knobs: epochs 1–4 with the heuristic, GPU Auto · <flavor>, Method
        tap(app, "train-manual")
        XCTAssertTrue(find(app, "train-epochs-picker", scroll: 1, timeout: 5).exists, "epochs picker missing under Fine-tune manually")
        let epochsNote = find(app, "train-epochs-note", scroll: 1)
        XCTAssertTrue(epochsNote.exists && epochsNote.label.contains("3–4"), "heuristic footnote: \(epochsNote.label)")
        let gpu = find(app, "train-flavor", scroll: 1)
        XCTAssertTrue(gpu.exists && gpu.label.contains("Auto"), "GPU defaults to Auto and names the pick: \(gpu.label)")
        shoot(app, "train-form-manual")
        tap(app, "train-manual")
        let start = find(app, "train-start")
        XCTAssertTrue(start.exists, "Train button missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '≈ $'")).firstMatch.waitForExistence(timeout: 5), "estimate not shown")
        let cap = find(app, "train-cap", scroll: 1)
        XCTAssertTrue(cap.exists && cap.label.hasPrefix("Stops by itself if it runs past ") && cap.label.contains(" minutes"), "automatic cap sentence: \(cap.label)")
        shoot(app, "train-form-estimate")
        start.tap()
        let approval = find(app, "train-approval", scroll: 1, timeout: 5)
        XCTAssertTrue(approval.exists, "ApprovalCard did not appear — the job must never start without it")
        XCTAssertTrue(app.staticTexts["huggingface.co"].exists, "the card names the host the job goes to")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/api/jobs/'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stops by itself if it runs past'")).firstMatch.exists, "the ApprovalCard carries the same estimate sentence")
        shoot(app, "train-form-approval")
        // deny → back to the button, still on the form (no session started)
        let deny = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'deny' OR label CONTAINS[c] 'don'")).firstMatch
        if deny.exists { deny.tap(); XCTAssertTrue(find(app, "train-start", scroll: 1, timeout: 5).exists) }
    }

    func testRunningShowsStepAndStageLadder() {
        let app = launch("running")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Training · step 14/24'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["loss 2.21"].exists)
        shoot(app, "train-running")
        XCTAssertTrue(find(app, "train-cancel").exists, "a running job can be cancelled")
    }

    func testDoneShowsResultAndAddToModels() {
        let app = launch("done")
        XCTAssertTrue(app.staticTexts["Your model is ready"].waitForExistence(timeout: 15))
        shoot(app, "train-done")
        XCTAssertTrue(find(app, "train-loss").exists, "held-out loss before → after")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2.38'")).firstMatch.exists)
        XCTAssertTrue(find(app, "train-add-model", scroll: 1).exists)
        // 1.2.0 result: per-epoch held-out loss + lineage of a round-2 model
        let chart = find(app, "train-epochs-chart", scroll: 1)
        XCTAssertTrue(chart.exists, "per-epoch eval-loss chart missing")
        XCTAssertTrue(chart.label.contains("pass 2 2.15"), "chart reads the pass lines: \(chart.label)")
        let lineage = find(app, "train-lineage", scroll: 1)
        XCTAssertTrue(lineage.exists, "lineage missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Qwen3.5-0.8B → loopl-app-sim'")).firstMatch.exists, "lineage chain text")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'round 2'")).firstMatch.exists)
        shoot(app, "train-done-result")
    }

    func testFailedNamesTheCause() {
        let app = launch("failed")
        XCTAssertTrue(app.staticTexts["Training failed"].waitForExistence(timeout: 15))
        // IMPROVE-4 #28: the plain sentence leads, the raw line follows (one combined element).
        let err = app.descendants(matching: .any).matching(identifier: "train-error").firstMatch
        for _ in 0..<4 where !err.exists { app.swipeUp() }   // below the eight stage rows on an SE
        XCTAssertTrue(err.waitForExistence(timeout: 5))
        XCTAssertTrue(err.label.contains("ran out of memory"), err.label)
        XCTAssertTrue(err.label.contains("CUDA out of memory"), err.label)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "train-cancel").firstMatch.exists)
        shoot(app, "train-failed")
    }
}
