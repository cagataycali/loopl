import XCTest

/// LIVE proof for Models › loopl models: with the owner's token (LOOPL_HF_TOKEN) the collection comes from the Hub (private
/// today), a row opens the repo sheet and the download completes on the simulator. MLX is compiled out on the simulator, so
/// "chat" is proven on macOS by MLXModel tests against the same repo; here the proof is "listed → downloaded → on this device".
/// LOOPL_COLLECTION_REPO picks the row (default cagataydev/loopl-0.8b-v1.1-4bit, 625 MB). Skips without the token.
final class CollectionLiveUITests: XCTestCase {
    func testCollectionRowDownloadsWithTheOwnersToken() throws {
        let env = ProcessInfo.processInfo.environment
        let token = env["LOOPL_HF_TOKEN"] ?? ""
        let repo = env["LOOPL_COLLECTION_REPO"] ?? "cagataydev/loopl-0.8b-v1.1-4bit"
        try XCTSkipIf(token.isEmpty, "needs LOOPL_HF_TOKEN (owner's Hugging Face token) in the runner env")
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "collection-row-\(repo)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(repo) not in Models › loopl models")
        // Signed in: no sign-in hint; the footer no longer says "bundled list" once the Hub answered.
        let footer = app.descendants(matching: .any).matching(identifier: "collection-footer").firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, footer.exists, footer.label.contains("bundled list") { sleep(2) }
        note("FOOTER \(footer.label)")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-signed-out").firstMatch.exists, "signed in → no hint")
        shot(app, "live-row")
        row.tap()

        let download = app.buttons["hub-download"]
        XCTAssertTrue(download.waitForExistence(timeout: 30), "repo sheet did not load")
        note("SHEET-DOWNLOAD \(download.label)")
        shot(app, "live-sheet")
        download.tap()
        XCTAssertFalse(app.staticTexts["hub-download-refused"].waitForExistence(timeout: 3), "download refused: \(app.staticTexts["hub-download-refused"].label)")

        let downloading = app.descendants(matching: .any).matching(identifier: "collection-downloading-\(repo)").firstMatch
        let failed = app.descendants(matching: .any).matching(identifier: "collection-failed-\(repo)").firstMatch
        _ = downloading.waitForExistence(timeout: 20)
        shot(app, "live-downloading")
        let end = Date().addingTimeInterval(15 * 60)
        while Date() < end, downloading.exists, !failed.exists { sleep(5) }
        XCTAssertFalse(failed.exists, "download failed: \(failed.label)")
        XCTAssertFalse(downloading.exists, "download did not finish within 15 min")
        Thread.sleep(forTimeInterval: 2)
        note("ROW-AFTER \(row.label)")
        XCTAssertTrue(row.label.contains("on this device") || row.label.contains("in use"), "row shows the checkmark / in use: \(row.label)")
        shot(app, "live-downloaded")
    }

    private func note(_ s: String) { let a = XCTAttachment(string: s); a.name = "note"; a.lifetime = .keepAlways; add(a); print(s) }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("collection-\(name).png"))
        }
        let a = XCTAttachment(screenshot: shot); a.name = "SHOT \(name)"; a.lifetime = .keepAlways; add(a)
    }
}
