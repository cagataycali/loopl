import XCTest

/// #19 first-run onboarding: the sheet offers three model cards, Continue shows the mark as a progress ring and
/// closes itself when the model is ready; Skip closes it straight away. `--design-fixture onboarding` scripts the
/// download (no network, no weights).
final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "onboarding"]
        app.launch()
        return app
    }
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testPickDownloadAndReady() {
        let app = launch()
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
        // Scripted ~4 s download + load → "Ready" → the sheet closes on its own.
        XCTAssertTrue(progress.waitForNonExistence(timeout: 15), "sheet closes itself once the model is ready")
        XCTAssertFalse(cont.exists)
    }

    func testSkipCloses() {
        let app = launch()
        let skip = el(app, "onboarding-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(el(app, "onboarding-continue").waitForNonExistence(timeout: 5))
    }
}
