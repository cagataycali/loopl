import XCTest

/// UX-POLISH audit captures (lane evidence, not a gate): the composer with the keyboard UP at 1 / 3 / 5 lines,
/// with attachments, and the geometry of every control printed as one grep-able `UX-GEOM` line per element so a
/// 4-pt-grid / baseline check can be done on numbers rather than by eye.
/// `LOOPL_UX_SHOTS=<dir>` writes PNGs; without it the test is skipped. Variants come from the usual launch
/// arguments (`-UIPreferredContentSizeCategoryName`, `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`)
/// passed through `LOOPL_UX_ARGS` (space separated).
final class UXAuditUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var device: String { ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "unknown" }

    private func geom(_ app: XCUIApplication, _ scene: String) {
        func line(_ name: String, _ e: XCUIElement) {
            guard e.exists else { print("UX-GEOM device=\(device) scene=\(scene) el=\(name) MISSING"); return }
            let f = e.frame
            print("UX-GEOM device=\(device) scene=\(scene) el=\(name) x=\(f.minX) y=\(f.minY) w=\(f.width) h=\(f.height) maxX=\(f.maxX) maxY=\(f.maxY)")
        }
        line("window", app.windows.firstMatch)
        line("field", app.textViews["Message"].firstMatch.exists ? app.textViews["Message"].firstMatch : app.textFields["Message"].firstMatch)
        line("send", app.buttons["Send"].firstMatch)
        line("mic", app.buttons["Record audio"].firstMatch)
        line("attach", app.buttons["Attach an image"].firstMatch)
        line("keyboard", app.keyboards.firstMatch)
        line("tabbar", app.tabBars.firstMatch)
    }

    private func shoot(_ app: XCUIApplication, _ dir: String, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        geom(app, name)
    }

    func testShootComposerMatrix() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_UX_SHOTS"], !dir.isEmpty else { throw XCTSkip("captures only") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let extra = (ProcessInfo.processInfo.environment["LOOPL_UX_ARGS"] ?? "").split(separator: " ").map(String.init)
        let scene = ProcessInfo.processInfo.environment["LOOPL_UX_SCENE"] ?? "vision"

        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene, "--design-local-vision"] + extra
        app.launch()
        let field = app.textViews["Message"].firstMatch.exists ? app.textViews["Message"].firstMatch : app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no composer")
        shoot(app, dir, "c0-idle")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "keyboard never came up")
        shoot(app, dir, "c1-empty-kb")
        field.typeText("Hello")
        shoot(app, dir, "c2-one-line")
        field.typeText(" there — can you look at the picture I attached and tell me what the sign says, then convert the price to euros?")
        shoot(app, dir, "c3-three-lines")
        field.typeText(" Also remember that I prefer short answers, and open the flashlight if it is dark in here, please.")
        field.typeText(" One more paragraph so the field reaches its maximum height and starts scrolling inside.")
        shoot(app, dir, "c4-max-lines")
        // Dismiss by dragging the transcript (opt-in: LOOPL_UX_C5=1): the bar must land exactly where it was (no jump, no gap).
        if ProcessInfo.processInfo.environment["LOOPL_UX_C5"] == "1" {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            Thread.sleep(forTimeInterval: 1.0)
            shoot(app, dir, "c5-dismissed-with-text")
        }
        app.terminate()
    }
}
