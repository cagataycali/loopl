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
        let facts = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'thinks before answering'")).firstMatch
        if !facts.waitForExistence(timeout: 3) {
            let near = app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { $0.contains("Qwen3-VL") || $0.contains("GB") }
            XCTFail("no row facts say 'thinks before answering' — labels near: \(near)")
        }
        XCTAssertTrue(facts.label.contains("sees pictures"), facts.label)
        XCTAssertTrue(facts.label.contains("GB"), facts.label)
        shoot(app, "vl-thinking-rows")
        let fourB = row("Qwen3-VL 4B Thinking")
        XCTAssertTrue(fourB.waitForExistence(timeout: 5), "Qwen3-VL 4B Thinking row")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'thinks before answering'")).count, 2, "both Thinking rows carry the fact")

        guard ProcessInfo.processInfo.environment["LOOPL_VL_DOWNLOAD"] == "1" else { note("rows verified; LOOPL_VL_DOWNLOAD unset"); return }
        // Tap → engine.select → HFDownloader on the real repo. We only need to see bytes arrive.
        for _ in 0..<6 where !twoB.isHittable { app.swipeDown() }
        twoB.tap()
        // A downloading row LEAVES More models and joins "On this iPhone" at the top (Models order #112) — the List is lazy,
        // so scroll back up before looking for it.
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'downloading'")).firstMatch
        for _ in 0..<8 where !progress.exists { app.swipeDown(); _ = progress.waitForExistence(timeout: 2) }
        XCTAssertTrue(progress.waitForExistence(timeout: 60), "download did not start for mlx-community/Qwen3-VL-2B-Thinking-4bit")
        XCTAssertTrue(app.staticTexts["Qwen3-VL 2B Thinking"].firstMatch.exists, "the row now sits under On this iPhone")
        // The progress row is ONE a11y element ("downloading, N percent") — the bytes text is folded into it.
        shoot(app, "vl-thinking-downloading")
        note("VL-SIM download started for Qwen3-VL-2B-Thinking-4bit · progress: \(progress.label)")
        XCTAssertTrue(progress.label.hasPrefix("downloading"), progress.label)
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        XCTContext.runActivity(named: name) { a in
            let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; att.name = name; a.add(att)
        }
    }
    private func note(_ text: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] else { return }
        try? (text + "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("vl-sim-notes.txt"), atomically: true, encoding: .utf8)
    }
}
