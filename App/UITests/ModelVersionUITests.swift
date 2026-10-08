import XCTest

/// "Is the model on my iPhone still the one Hugging Face serves?" — a question the app could not answer until now:
/// every catalog row pins no revision, so a download takes whatever `main` points at that day, and on 2026-10-07 all
/// three loopl sizes were replaced in place by v1.2. A new install got v1.2, an existing one kept v1.1, and nothing
/// said so. `--design-update <id>` stages the answer with no network: a copy from nine days ago, a repo that moved on.
final class ModelVersionUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models",
                               "--design-models", "shelf"] + extra
        app.launch()
        return app
    }

    func testTheRowSaysANewerVersionExistsAndOffersIt() {
        let app = launch(["--design-update", "loopl-2b-4bit"])
        let line = app.descendants(matching: .any)["models-update-loopl-2b-4bit"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the row says a newer version is on the Hub")
        XCTAssertTrue(line.label.contains("newer version"), line.label)
        XCTAssertTrue(line.label.contains("arrived"), "it says when this copy arrived: \(line.label)")
        // No Hub vocabulary in a sentence a person reads.
        for word in ["sha", "commit", "revision", "main"] {
            XCTAssertFalse(line.label.lowercased().contains(word), "\(word) in “\(line.label)”")
        }
        let get = app.buttons["models-update-get-loopl-2b-4bit"].firstMatch
        XCTAssertTrue(get.exists, "and offers the download")
        XCTAssertTrue(get.isHittable, "the button is reachable without scrolling the row away")
    }

    /// The other three cases are silence: a copy that matches, a copy loopl has no record of, and every row that was
    /// never asked about. Nothing on this shelf has a recorded version unless the fixture gives it one.
    func testEveryOtherRowSaysNothing() {
        let app = launch(["--design-update", "loopl-2b-4bit"])
        XCTAssertTrue(app.descendants(matching: .any)["models-update-loopl-2b-4bit"].firstMatch.waitForExistence(timeout: 20))
        for id in ["qwen3-0.6b-4bit", "loopl-0.8b-4bit", "apple-fm"] {
            XCTAssertFalse(app.descendants(matching: .any)["models-update-\(id)"].firstMatch.exists,
                           "\(id) has no recorded version, so it must not be nagged about")
        }
    }
}
