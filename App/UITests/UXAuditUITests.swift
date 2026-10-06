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

    /// Regression (not a capture — runs in CI): a five-line draft, keyboard dismissed by dragging the transcript.
    /// With a LazyVStack transcript this froze the app in a layout loop (100 % main thread, every XCUI query timed out).
    func testKeyboardDismissWithTallDraftDoesNotHangLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "vision", "--design-local-vision"]
        app.launch()
        let field = app.textViews["Message"].firstMatch.exists ? app.textViews["Message"].firstMatch : app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        field.typeText("Hello there — can you look at the picture I attached and tell me what the sign says, then convert the price to euros? Also remember that I prefer short answers. One more paragraph so the field reaches its maximum height and starts scrolling inside.")
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        // The app must answer queries within seconds afterwards (the hang made this take 30 s and fail).
        let t0 = Date()
        XCTAssertTrue(app.buttons["Send"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "tab bar back after the keyboard")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15, "layout loop: queries stalled")
    }

    /// VoiceOver audit (lane evidence, skipped without LOOPL_UX_SHOTS): every button / text field / toggle on the Chat,
    /// Models and Settings panes with its label, identifier and hint, as `UX-A11Y` lines. Empty labels and duplicates
    /// are what the reviewer looks for.
    func testDumpAccessibility() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_UX_SHOTS"], !dir.isEmpty else { throw XCTSkip("captures only") }
        var out: [String] = []
        for (pane, args) in [("chat", ["--design-fixture", "vision", "--design-local-vision"]),
                             ("models", ["--design-fixture", "persona", "--design-tab", "models", "--design-models", "shelf", "--design-collection", "bundled", "--design-mine"]),
                             ("settings", ["--design-fixture", "empty", "--design-tab", "settings"])] {
            let app = XCUIApplication()
            app.launchArguments = ["--skip-onboarding"] + args
            app.launch()
            Thread.sleep(forTimeInterval: 3)
            for type in [XCUIElement.ElementType.button, .textField, .textView, .switch, .segmentedControl, .image] {
                for e in app.descendants(matching: type).allElementsBoundByIndex where e.isHittable || type == .image {
                    let hint = e.value(forKey: "accessibilityHint") as? String ?? ""
                    out.append("UX-A11Y pane=\(pane) type=\(type.rawValue) label=\"\(e.label)\" id=\"\(e.identifier)\" hint=\"\(hint)\" frame=\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width))x\(Int(e.frame.height))")
                }
            }
            app.terminate()
        }
        try? out.joined(separator: "\n").write(toFile: dir + "/a11y.txt", atomically: true, encoding: .utf8)
        out.forEach { print($0) }
    }

    func testShootComposerMatrix() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_UX_SHOTS"], !dir.isEmpty else { throw XCTSkip("captures only") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let extra = (ProcessInfo.processInfo.environment["LOOPL_UX_ARGS"] ?? "").split(separator: " ").map(String.init)
        let scene = ProcessInfo.processInfo.environment["LOOPL_UX_SCENE"] ?? "vision"

        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene, "--design-local-vision"] + extra
        // LOOPL_UX_ORIENT=landscape rotates the device before launch (the whole matrix repeats sideways).
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["LOOPL_UX_ORIENT"] == "landscape" ? .landscapeLeft : .portrait
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
