import XCTest

/// Models tab in the order a first-time user needs it (owner, 2026-10-06): 1 On this iPhone · 2 Browse Hugging Face · 3 Train your own ·
/// 4 loopl models · 5 Mine — read top to bottom; the rest of the catalog folds under the loopl models. LAST comes the Storage
/// block (used · free on this iPhone and each drive, memory for a model, Settings › Storage) — readable rows, not a caption.
/// Deterministic: `--design-collection bundled` (snapshot, no network) + `--design-models shelf|empty` (ModelStore.overrideState) +
/// `--storage-fixture none` (no drives left over from StorageUITests on the same simulator).
/// Screenshots → LOOPL_SHOT_DIR: models-order-shelf.png models-order-empty.png.
final class ModelsOrderUITests: XCTestCase {
    private let headers = ["models-header-device", "models-header-browse", "models-header-train"]

    func testSectionsReadTopToBottomInTheOwnersOrder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-models", "shelf", "--storage-fixture", "none"]
        app.launch()
        let device = app.staticTexts["models-header-device"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 10), "section 1 header")
        XCTAssertEqual(device.label, "On this iPhone")
        // 1 — the shelf: the model in use first, then the downloaded ones, then the download in flight. Nothing folded.
        let inUse = app.staticTexts["loopl 2B"].firstMatch
        XCTAssertTrue(inUse.exists, "the model in use is on the shelf")
        let downloading = app.staticTexts["loopl 0.8B"].firstMatch
        XCTAssertTrue(downloading.exists, "a download in flight stays on the shelf")
        XCTAssertLessThan(inUse.frame.minY, downloading.frame.minY, "in use sorts first")
        let browse = app.descendants(matching: .any).matching(identifier: "models-browse-hub").firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertLessThan(downloading.frame.minY, browse.frame.minY, "On this iPhone above Browse")
        shoot(app, "models-order-shelf")
        // 2 → 3 → 4 → 5, by scrolling down the list and recording where each header first appears.
        var order: [String] = []
        let wanted = headers + ["loopl models", "Mine", "models-header-storage"]
        for _ in 0..<14 {
            // A lazy List realises a header shortly before it scrolls in, so "first seen" is the order on screen.
            // (`isHittable` is not asked: the last header can sit under the floating tab bar and still be in order.)
            // Mine's header reads "Mine · @author" once a token is in the runner env.
            for id in wanted where !order.contains(id) && app.staticTexts.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", id, id)).firstMatch.exists { order.append(id) }
            if order.count == wanted.count { break }
            app.swipeUp()
        }
        XCTAssertEqual(order, wanted, "headers top to bottom")
        // Storage is the last block and says how much space there IS, not only what loopl uses.
        let storage = app.descendants(matching: .any).matching(identifier: "models-storage").firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 5), "this iPhone's storage row")
        XCTAssertTrue(storage.label.contains("free"), storage.label)
        // The rows below it realise as they scroll in (lazy List; the last one can sit under the floating tab bar).
        let toSettings = app.descendants(matching: .any).matching(identifier: "models-storage-settings").firstMatch
        for _ in 0..<4 where !toSettings.exists { app.swipeUp() }
        XCTAssertTrue(toSettings.waitForExistence(timeout: 5), "the way to Settings › Storage")
        XCTAssertFalse(app.staticTexts["From Hugging Face"].exists)
        shoot(app, "models-order-storage")
    }

    func testEmptyShelfSaysWhereModelsComeFrom() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-models", "empty", "--storage-fixture", "none"]
        app.launch()
        let empty = app.descendants(matching: .any).matching(identifier: "models-empty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "the calm empty line")
        XCTAssertTrue(empty.label.contains("Get a model"), empty.label)
        // The loopl models are still one swipe away, after Browse and Train.
        let four = app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-4bit").firstMatch
        if !four.exists { app.swipeUp() }
        XCTAssertTrue(four.waitForExistence(timeout: 5))
        shoot(app, "models-order-empty")
        // Storage, last: nothing downloaded, but the free space is still there to read.
        let storage = app.descendants(matching: .any).matching(identifier: "models-storage").firstMatch
        for _ in 0..<8 where !storage.exists { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        XCTAssertTrue(storage.label.contains("Nothing downloaded") && storage.label.contains("free"), storage.label)
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
