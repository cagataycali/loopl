import XCTest

/// Models › Mine → repo sheet → Download on a FULL iPhone (`--free-space 50000000`), signed in with the
/// owner's token (LOOPL_HF_TOKEN via `simctl spawn launchctl setenv`, see hf-account GOTCHAS).
/// Before: the sheet dismissed and nothing visible happened in Mine — the reason sat as a footnote in the
/// "From Hugging Face" section below the fold ("the download is not starting"). After: the sheet stays,
/// says why (need vs free + the drive hint) and offers Settings › Storage; closing it, the Mine row carries
/// the same reason plus Retry. Captures mine-download-refused-sheet.png / mine-download-refused-row.png.
final class MineDownloadUITests: XCTestCase {
    func testFullPhoneRefusalIsVisibleInSheetAndMineRow() throws {
        let token = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "needs LOOPL_HF_TOKEN (owner's Hugging Face token) in the runner env")
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--free-space", "50000000"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()

        let list = app.collectionViews["pane-models"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Models"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mine-hit-'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 40), "no Mine row — whoami/listing failed or the token is not seen")
        let repo = hit.identifier.replacingOccurrences(of: "mine-hit-", with: "")
        Thread.sleep(forTimeInterval: 2.0)   // let the list's insert animation settle before presenting the zoom sheet
        hit.tap()

        let download = app.buttons["hub-download"]
        if !download.waitForExistence(timeout: 30) { shoot(app, "mine-download-DEBUG-no-sheet") }
        XCTAssertTrue(download.exists, "repo sheet did not load")
        download.tap()

        // The sheet must NOT dismiss; the reason appears right above the button.
        let refused = app.staticTexts["hub-download-refused"].firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "no inline refusal after Download on a full phone")
        XCTAssertTrue(download.exists, "sheet dismissed although the download could not start")
        XCTAssertTrue(refused.label.contains("Not enough space"), refused.label)
        XCTAssertTrue(refused.label.contains("free"), "need vs free missing: \(refused.label)")
        XCTAssertTrue(app.buttons["hub-download-storage"].exists, "Settings › Storage shortcut missing")
        let reason = refused.label
        shoot(app, "mine-download-refused-sheet")

        app.buttons["Close"].firstMatch.tap()
        // Back in Models: the Mine row shows the same reason + Retry (no scrolling to a section below).
        let rowFail = app.staticTexts["mine-failed-\(repo)"].firstMatch
        XCTAssertTrue(rowFail.waitForExistence(timeout: 5), "Mine row carries no failure reason")
        XCTAssertTrue(rowFail.label.contains("Not enough space"), rowFail.label)
        XCTAssertTrue(app.buttons["mine-retry-\(repo)"].exists, "Retry missing on the Mine row")
        shoot(app, "mine-download-refused-row")
        print("MINE-DL refusal sheet=\(reason)")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        XCTContext.runActivity(named: name) { a in
            let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; att.name = name; a.add(att)
        }
    }
}
