import XCTest

/// P8-A: the Qwen3-VL Thinking rows on the iOS simulator (MLX is compiled out here, so this proves the CATALOG + DOWNLOAD
/// path, not inference — inference is proven on macOS by MLXVisionTests). Models › More models lists both Thinking rows
/// with the *thinks* badge; tapping one starts the real Hub download (bytes arrive, the progress row appears), then we stop.
/// Set LOOPL_VL_DOWNLOAD=1 to let the download run (network); without it the test stops after the rows are verified.
final class VLModelsUITests: XCTestCase {
    func testThinkingRowsListedAndDownloadStartsOnTheSimulator() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-models", "empty", "--storage-fixture", "none"]
        app.launch()
        let list = app.collectionViews["pane-models"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Models"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        let more = app.descendants(matching: .any).matching(identifier: "models-more").firstMatch
        for _ in 0..<6 where !more.exists { app.swipeUp(); _ = more.waitForExistence(timeout: 2) }
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More models row")
        more.tap()

        func row(_ name: String) -> XCUIElement {
            let el = app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
            for _ in 0..<8 where !(el.exists && el.isHittable) { app.swipeUp(); _ = el.waitForExistence(timeout: 1) }
            return el
        }
        let twoB = row("Qwen3-VL 2B Thinking")
        XCTAssertTrue(twoB.waitForExistence(timeout: 5), "Qwen3-VL 2B Thinking row under More models")
        // The row's facts (one a11y element): size · params · ctx · runtime · sees pictures · thinks before answering.
        let facts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'thinks before answering' AND label CONTAINS '1.8 GB'")).firstMatch
        XCTAssertTrue(facts.waitForExistence(timeout: 3), "the 2B Thinking row says it sees pictures and thinks")
        XCTAssertTrue(facts.label.contains("sees pictures"), facts.label)
        shoot(app, "vl-thinking-rows")
        let fourB = row("Qwen3-VL 4B Thinking")
        XCTAssertTrue(fourB.waitForExistence(timeout: 5), "Qwen3-VL 4B Thinking row")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'thinks before answering' AND label CONTAINS '3.1 GB'")).firstMatch.exists)

        guard ProcessInfo.processInfo.environment["LOOPL_VL_DOWNLOAD"] == "1" else { return }
        // Tap → engine.select → HFDownloader on the real repo. We only need to see bytes arrive.
        for _ in 0..<6 where !twoB.isHittable { app.swipeDown() }
        twoB.tap()
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'downloading'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 60), "download did not start for mlx-community/Qwen3-VL-2B-Thinking-4bit")
        let bytes = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' of 1.8 GB' OR label CONTAINS ' of 1,8 GB'")).firstMatch
        XCTAssertTrue(bytes.waitForExistence(timeout: 60), "progress row with bytes of 1.8 GB")
        shoot(app, "vl-thinking-downloading")
        print("VL-SIM download started: \(bytes.label)")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] else { return }
        let png = app.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
