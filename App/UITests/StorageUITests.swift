import XCTest

/// Settings › Storage with a simulated USB-C drive (`--storage-fixture <folder>`:
/// a folder outside the sandbox stands in for the SanDisk; a second, vanished
/// folder stands in for a drive that is not plugged in).
///
/// Proves, with screenshots attached: both volumes listed with free space, the
/// connected/not-connected states, the model on the missing drive dimmed and
/// not deletable, and a real "Move to this iPhone" that copies, verifies and
/// relabels the row. Screenshots are also written to `TEST_RUNNER_SHOTS_DIR`
/// when set (how the audit's hosted shots were produced).
final class StorageUITests: XCTestCase {
    private let drive = "/tmp/loopl-sim-drive"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.removeItem(atPath: drive)
    }

    private func launch(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", tab, "--storage-fixture", drive]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func openStorage(_ app: XCUIApplication) {
        let list = app.collectionViews["pane-settings"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let row = app.buttons["settings-storage"].firstMatch
        for _ in 0..<8 where !row.isHittable { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings has a Storage row")
        row.tap()
        XCTAssertTrue(app.collectionViews["pane-storage"].waitForExistence(timeout: 10))
    }

    func testStorageScreenListsBothVolumesAndMovesAModelToThePhone() throws {
        let app = launch(tab: "settings")
        openStorage(app)
        shot("storage-01-overview")

        let internalRow = app.otherElements["storage-internal"].firstMatch
        let sandisk = app.otherElements["storage-volume-SanDisk"].firstMatch
        let old = app.otherElements["storage-volume-Old stick"].firstMatch
        XCTAssertTrue(internalRow.exists || app.staticTexts["This iPhone"].exists, "iPhone row")
        XCTAssertTrue(sandisk.exists || app.staticTexts["SanDisk"].exists, "connected drive row")
        XCTAssertTrue(old.exists || app.staticTexts["Old stick"].exists, "disconnected drive row")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'free'")).firstMatch.exists, "free space shown")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not connected'")).firstMatch.exists, "unplugged copy")

        // The model on the connected drive: "… on SanDisk"; the one on the missing drive: "not connected".
        let list = app.collectionViews["pane-storage"]
        // SwiftUI exposes a Menu in a Form as a button labelled with its title; the identifier is not always carried.
        let byId = app.descendants(matching: .any)["storage-move-qwen3.5-0.8b-4bit"].firstMatch
        let move = byId.exists ? byId : app.buttons["Move"].firstMatch
        for _ in 0..<6 where !move.isHittable { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(move.waitForExistence(timeout: 5), "fixture model listed with a Move menu")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'on SanDisk'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'On Old stick'")).firstMatch.exists)
        shot("storage-02-models")

        // Move to this iPhone — copy + verify + delete source, then the row relabels.
        move.tap()
        let toPhone = app.buttons["Move to this iPhone"].firstMatch
        XCTAssertTrue(toPhone.waitForExistence(timeout: 5)); toPhone.tap()
        let moved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'on This iPhone'")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 20), "row says the model is on the iPhone after the move")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive + "/loopl/mlx-community--Qwen3.5-0.8B-4bit/model.safetensors"), "source removed after verification")
        shot("storage-03-moved")

        // And back to the drive via the same menu.
        move.tap()
        let toDrive = app.buttons["Move to SanDisk"].firstMatch
        XCTAssertTrue(toDrive.waitForExistence(timeout: 5)); toDrive.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'on SanDisk'")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive + "/loopl/mlx-community--Qwen3.5-0.8B-4bit/model.safetensors"))
        shot("storage-04-moved-back")
    }

    func testModelsListDimsTheModelOnTheMissingDriveAndHidesDelete() throws {
        let app = launch(tab: "models")
        let list = app.collectionViews["pane-models"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let needs = app.staticTexts["models-needs-drive-qwen3-1.7b-4bit"].firstMatch
        XCTAssertTrue(needs.waitForExistence(timeout: 10), "Qwen3-1.7B says it needs Old stick")
        XCTAssertTrue(needs.label.contains("Old stick"), needs.label)
        XCTAssertTrue(app.staticTexts["models-location-qwen3.5-0.8b-4bit"].firstMatch.exists, "Qwen3.5 shows 'On SanDisk'")
        shot("models-01-drive-badges")

        // Swipe the missing-drive row: no Delete action may appear.
        let row = app.cells.containing(.staticText, identifier: "models-needs-drive-qwen3-1.7b-4bit").firstMatch
        XCTAssertTrue(row.exists)
        row.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].waitForExistence(timeout: 1.5), "a model that is not on the phone cannot be deleted from the phone")
        shot("models-02-no-delete-when-away")
    }

    func testSelectingAModelOnTheMissingDriveFailsClearlyWithoutCrashing() throws {
        let app = launch(tab: "models")
        XCTAssertTrue(app.collectionViews["pane-models"].waitForExistence(timeout: 15))
        let needs = app.staticTexts["models-needs-drive-qwen3-1.7b-4bit"].firstMatch
        XCTAssertTrue(needs.waitForExistence(timeout: 10))
        needs.tap()   // the row is inert; the app must still be here
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(needs.exists)
    }
}
