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

        // ONE scroll strategy for the whole list, instead of a `swipeUp` loop per tool name.
        //
        // This test used to hunt named rows one after another — current_time, http, clipboard_write, music, then
        // `location`, then `reminders_create` — with a small swipe loop each. That walks the list MONOTONICALLY
        // DOWN while asking for names in a different order than the list draws them: `music` is under **Off** on
        // the Simulator, `location` is under **On** above it, so by the time `location` was wanted the viewport
        // had passed it — and a row scrolled away is gone from a lazy List's tree, so `exists` was false for a
        // row that was never missing. Measured before this change: fails on an iPhone SE, fails on the CI
        // runner's tallest iPhone 72 s in, and passes on a 16 Pro locally in 96.8 s — marginal on screen height
        // AND machine speed at once, which is why no device matrix could rescue it (improve-7/AUDIT.md #8).
        //
        // So: scroll down exactly once, COLLECTING every tool row as it goes, then assert on what was collected.
        // No ordering assumption, no backtracking, no per-tool budget, and a failure can say what it did see.
        var defaults: [String: String] = [:]
        var asksFirst: Set<String> = []
        var lastSeen = ""
        for _ in 0..<30 {
            for el in app.staticTexts.allElementsBoundByIndex {
                let id = el.identifier
                guard id.hasPrefix("tool.") else { continue }
                if id.hasSuffix(".default") {
                    defaults[String(id.dropFirst(5).dropLast(8))] = el.label
                } else if id.hasSuffix(".asksFirst") {
                    asksFirst.insert(String(id.dropFirst(5).dropLast(10)))
                }
            }
            // "Has the list moved?" measured as a fingerprint of the WHOLE visible set, not the last element:
            // the last static text in the AX tree is often a section footer that stays realised, so comparing it
            // declared the end of the list after the 8 core tools and the Apple ones were never collected
            // (measured: "saw: calculator, current_time, device_info, http, manage_messages, recall, remember,
            // use_agent" — a wrong answer that looked like a missing feature).
            let fingerprint = app.staticTexts.allElementsBoundByIndex
                .map { $0.identifier + "/" + $0.label }.joined(separator: "|")
            if fingerprint == lastSeen { break }    // nothing changed after a swipe: every row has been seen
            lastSeen = fingerprint
            app.swipeUp()
        }
        let seen = defaults.keys.sorted().joined(separator: ", ")

        // Portable and on-device tools in the same list, with their default tags.
        for name in ["current_time", "http", "clipboard_write", "music"] {
            XCTAssertEqual(defaults[name], "on by default", "\(name) — saw: \(seen)")
        }
        // `location` moved to ON by default in #138 — the owner's report was that the location tool did not work,
        // and a tool nobody switches on cannot. The off group is proven by `reminders_create`, still off.
        XCTAssertEqual(defaults["location"], "on by default", "location is listed with its default — saw: \(seen)")
        XCTAssertEqual(defaults["reminders_create"], "off by default", "an off-by-default tool is listed too — saw: \(seen)")
        XCTAssertTrue(asksFirst.contains("http"), "http carries its approval note — asks: \(asksFirst.sorted())")
        XCTAssertTrue(asksFirst.contains("clipboard_write"), "clipboard_write carries its approval note")
        XCTAssertFalse(asksFirst.contains("music"), "music never stops at a card")
        shot(app, "settings-tools-off")

        // Switching a tool off moves it to the Off group and the summary follows (read the summary with the row on screen —
        // the List is lazy; on the Simulator `music` is unavailable, so the switch that is both on and hittable is http).
        for _ in 0..<8 where !summary.exists { app.swipeDown() }
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let before = summary.label
        let http = app.switches["tool.http"].firstMatch
        for _ in 0..<6 where !http.isHittable { app.swipeUp() }
        XCTAssertTrue(http.isHittable)
        // `isHittable` is not "safe to tap". MEASURED on an iPhone SE: the http row is **126.5 pt tall** (name,
        // description and the "asks first" note all wrap) and sat at `{{16, -0.5}, {343, 126.5}}` — hittable,
        // because part of it showed, while the point this knob coordinate is measured from (dy 0.5 → y ≈ 63) sat
        // UNDER the navigation bar. The tap landed on the bar, the switch never moved (value 1 → 1), and the test
        // reported it as "summary counts what the model gets" failing — a tap that missed, dressed up as a
        // product bug. Nudge the row clear of the bar first, in quarter-screen drags rather than full swipes so
        // it cannot be flung off the bottom instead.
        func nudgeDown() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        for _ in 0..<6 where http.frame.minY < 100 { nudgeDown() }
        XCTAssertGreaterThan(http.frame.minY, 44,
                             "the row must be clear of the navigation bar before its knob is tapped: \(http.frame)")
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
