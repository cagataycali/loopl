import XCTest

/// Settings › Tools is ONE collapsible row (owner, 2026-10-06): every tool under it, grouped On / Off, each with its
/// toggle, default tag and — where a card applies — the "Asks before …" note. Nothing tool-related elsewhere.
final class SettingsToolsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"] + extra
        app.launch()
        if !app.collectionViews["pane-settings"].waitForExistence(timeout: 8) {   // iPad: pick the pane from the sidebar
            let item = app.buttons["Settings"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
        }
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_TOOLS_SHOTS"] else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testOneCollapsibleToolsRowWithGroupsTagsAndNotes() {
        let app = launch()
        let row = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Tools row lives in Settings › Agent")
        // iOS 26 sim: the row's `settings-tools` id is inherited by the summary Text (its own id is dropped) — match it by label.
        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "(identifier == 'settings-tools-summary' OR identifier == 'settings-tools') AND (label CONTAINS ' of ' OR label == 'off')")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the summary label")
        XCTAssertTrue(summary.label.contains(" of ") || summary.label == "off", summary.label)
        XCTAssertFalse(app.staticTexts["On-device Apple tools"].exists, "the old section is gone")
        shot(app, "settings-collapsed")

        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap() }
        XCTAssertTrue(onHeader.waitForExistence(timeout: 5), "tapping the row expands the groups")
        shot(app, "settings-tools-open")
        let offHeader = app.descendants(matching: .any)["settings-tools-group-off"].firstMatch
        for _ in 0..<8 where !offHeader.exists { app.swipeUp() }       // the List is lazy: the Off group sits below the On rows
        XCTAssertTrue(offHeader.waitForExistence(timeout: 3), "an Off group follows the On group")
        for _ in 0..<8 where !onHeader.isHittable { app.swipeDown() }

        // Portable and on-device tools in the same list, with their default tags.
        // Asserted while each row is on screen — the List is lazy, a row scrolled away is gone from the tree.
        for name in ["current_time", "http", "clipboard_write", "music"] {        // list order; music is under Off on the Simulator
            let t = app.switches["tool.\(name)"].firstMatch
            for _ in 0..<6 where !t.exists { app.swipeUp() }
            XCTAssertTrue(t.waitForExistence(timeout: 5), name)
            XCTAssertEqual(app.staticTexts["tool.\(name).default"].firstMatch.label, "on by default", name)
            let asks = app.staticTexts["tool.\(name).asksFirst"].firstMatch.exists
            switch name {
            case "http", "clipboard_write": XCTAssertTrue(asks, "\(name) carries its approval note")
            case "music": XCTAssertFalse(asks, "music never stops at a card")
            default: break
            }
        }

        // Off group: the off-by-default ones (and whatever the Simulator cannot run).
        var found = false
        for _ in 0..<6 {
            if app.staticTexts["tool.location.default"].firstMatch.exists { found = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(found, "location is listed under Off")
        XCTAssertEqual(app.staticTexts["tool.location.default"].firstMatch.label, "off by default")
        shot(app, "settings-tools-off")

        // Switching a tool off moves it to the Off group and the summary follows (read the summary with the row on screen —
        // the List is lazy; on the Simulator `music` is unavailable, so the switch that is both on and hittable is http).
        for _ in 0..<8 where !summary.exists { app.swipeDown() }
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let before = summary.label
        let http = app.switches["tool.http"].firstMatch
        for _ in 0..<6 where !http.isHittable { app.swipeUp() }
        XCTAssertTrue(http.isHittable)
        let knob = { http.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }   // the row IS the Toggle; its centre is the label text
        knob()                                   // the row moves to the Off group (off screen); the summary says so
        for _ in 0..<8 where !summary.exists { app.swipeDown() }
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertNotEqual(summary.label, before, "summary counts what the model gets")
        for _ in 0..<10 where !http.isHittable { app.swipeUp() }
        if http.isHittable { knob() }   // leave the install as it was (now under Off)
    }

    /// Phase 6: the agent mounted `http` (switch off → "mounted for this conversation") and unmounted `calculator` (switch on →
    /// "unmounted for this conversation"); `manage_tools` is pinned ("always on", no toggle); one line says what the agent changed.
    func testMountedForThisConversationTagsAndNote() {
        let app = launch(extra: ["--design-mounted", "http,-calculator"])
        let row = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap() }
        XCTAssertTrue(onHeader.waitForExistence(timeout: 5))
        // `http` is switched on by default in a fresh install; make the fixture meaningful: the test switches it OFF first
        // would also unmount it (a user's switch wins) — so instead the fixture mounts http while it is on (no tag) and
        // unmounts calculator while it is on (tag). Assert the calculator tag, the pinned row and the note.
        let calcTag = app.staticTexts["tool.calculator.conversation"].firstMatch
        for _ in 0..<6 where !calcTag.exists { app.swipeUp() }
        XCTAssertTrue(calcTag.waitForExistence(timeout: 8), "calculator is tagged for this conversation")
        XCTAssertEqual(calcTag.label, "unmounted for this conversation")
        XCTAssertFalse(app.staticTexts["tool.http.conversation"].exists, "http: switch and conversation agree → no tag")
        let note = app.descendants(matching: .any)["settings-tools-conversation-note"].firstMatch
        for _ in 0..<6 where !note.exists { app.swipeDown() }
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("unmounted calculator"), note.label)
        shot(app, "settings-tools-conversation")
        let manage = app.staticTexts["tool.manage_tools.default"].firstMatch
        for _ in 0..<6 where !manage.exists { app.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        XCTAssertEqual(manage.label, "always on")
        XCTAssertFalse(app.switches["tool.manage_tools"].firstMatch.isEnabled, "pinned: no toggle")
    }

    func testCollapsedStateIsRemembered() {
        var app = launch()
        let row = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let onHeader = app.descendants(matching: .any)["settings-tools-group-on"].firstMatch
        if !onHeader.exists { row.tap(); XCTAssertTrue(onHeader.waitForExistence(timeout: 5)) }
        app.terminate()
        app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.waitForExistence(timeout: 10), "@AppStorage keeps it open")
        app.descendants(matching: .any)["settings-tools"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.waitForExistence(timeout: 2))
    }
}
