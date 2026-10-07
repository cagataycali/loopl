import XCTest

/// A sentence squeezed into a narrow column by a control sharing its row. THE most repeated layout bug in this app:
/// `SettingsToolsUITests`-era #194 ("Asks before POST, PUT, PATCH or DELETE" in a ~150 pt column beside "on by
/// default"), #195 (the approval card's header) and #198 ("Hug-ging Face has a…" in ~90 pt beside **Get it**) were all
/// the same shape — a long `Text` and a short control in one `HStack`. It is invisible at the text size a developer
/// works at and obvious at Accessibility XL, so it needs a machine, not a reviewer.
///
/// The measurement: at Accessibility XL, a label of 25 characters or more that has been given less than 45 % of the
/// screen's width is squeezed. Nothing in the app legitimately reads that way — a genuinely narrow column holds short
/// words (a chip, a number, a tag), and a long sentence that wraps gets the full content width.
final class TypeSqueezeUITests: XCTestCase {
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        return app
    }

    /// Walks the screen collecting as it goes, because the squeeze lives BELOW THE FOLD: at Accessibility XL a
    /// Settings row is ~190 pt tall, so the first tool with an "Asks before …" note is the sixth row and a test that
    /// measures one viewport measures nothing. Stops when a swipe produces no new text (fingerprint of the WHOLE
    /// visible set, not its last element — a section footer stays realised and lies about the end of the list).
    private func assertNoSqueeze(_ app: XCUIApplication, _ screen: String, settle: XCUIElement? = nil, scrolls: Int = 12) {
        if let settle { XCTAssertTrue(settle.waitForExistence(timeout: 20), "\(screen) drew") }
        let w = app.windows.firstMatch.frame.width
        var squeezed: [String: String] = [:]
        var lastSeen = ""
        for _ in 0..<scrolls {
            for el in app.staticTexts.allElementsBoundByIndex {
                let f = el.frame, label = el.label
                guard label.count >= 25, f.width > 1, f.height > 4 else { continue }
                // A monospaced value (a header value, a path, a sha) is not prose and may sit in a column.
                guard !label.contains("application/"), !label.hasPrefix("/") else { continue }
                guard f.width < w * 0.45 else { continue }
                squeezed[label] = "“\(label.prefix(44))” in \(Int(f.width)) pt of \(Int(w))"
            }
            let fingerprint = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: "|")
            if fingerprint == lastSeen { break }
            lastSeen = fingerprint
            app.swipeUp()
        }
        XCTAssertTrue(squeezed.isEmpty, "\(screen): a sentence squeezed into a column — " + squeezed.values.sorted().joined(separator: " · "))
    }

    func testSettingsToolRowsAreNotSqueezed() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "settings"])
        let list = app.collectionViews["pane-settings"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "settings drew")
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        if tools.exists, !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        assertNoSqueeze(app, "settings/tools")
    }

    func testApprovalCardIsNotSqueezed() {
        let app = launch(["--design-fixture", "approval"])
        assertNoSqueeze(app, "chat/approval", settle: app.buttons["Approve"].firstMatch)
    }

    func testModelRowsAreNotSqueezed() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-models", "shelf"])
        assertNoSqueeze(app, "models", settle: app.collectionViews["pane-models"].firstMatch)
    }

    func testChatToolRowsAreNotSqueezed() {
        let app = launch(["--design-fixture", "tool", "--design-reasoning"])
        assertNoSqueeze(app, "chat/tool", settle: app.descendants(matching: .any)["tool-row-calculator"].firstMatch)
    }

    func testHistoryRowsAreNotSqueezed() {
        let app = launch(["--skip-onboarding", "--design-fixture", "history"])
        assertNoSqueeze(app, "history", settle: app.staticTexts.firstMatch)
    }

    func testTrainFormIsNotSqueezed() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-train", "form"])
        assertNoSqueeze(app, "train/form", settle: app.staticTexts.firstMatch)
    }
}
