import XCTest

/// Phase 7 `render_ui`: the model's typed spec is drawn as a native card under the tool row — every kind from the
/// `render` fixture is on screen, an unknown type is NAMED, the issues line is present when the parser repaired
/// something, and the tool is on by default in Settings › Tools.
final class RenderUIUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ kind: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "render", "--design-render", kind, "--design-tab", "chat"] + extra
        app.launch()
        return app
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func testMixedCardShowsTitleChartKeyValueAndList() {
        let app = launch("mixed")
        XCTAssertTrue(any(app, "render-card-tooluse_r_mixed").waitForExistence(timeout: 15), "the card is under the render_ui row")
        XCTAssertTrue(app.staticTexts["Your week"].firstMatch.exists, "card title")
        let chart = any(app, "render-chart-1")
        XCTAssertTrue(chart.exists, "the chart component")
        XCTAssertTrue(chart.label.hasPrefix("bar chart Steps this week; steps: Mon 4000, Tue 6200"), "VoiceOver reads the data, not 'image': \(chart.label)")
        XCTAssertTrue(app.staticTexts["Resting HR: 58 bpm"].firstMatch.exists || app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Resting HR: 58 bpm'")).firstMatch.exists, "key/value row is one spoken element")
        // By identifier: the row reads "Card" since #140 (ToolLabel.table), not "render_ui".
        XCTAssertTrue(app.descendants(matching: .any)["tool-row-render_ui"].exists, "the tool row is visible — the call is not hidden")
        XCTAssertFalse(any(app, "render-issues").exists, "a clean spec has no issues line")
        // The answer after the card is one sentence that does not repeat the numbers.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Saturday carried it'")).firstMatch.exists)
    }

    func testMapIsAButtonThatNamesItsPins() {
        let app = launch("map")
        let map = app.buttons["render-map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15), "the map is a button")
        XCTAssertEqual(map.label, "map with 3 pins: bwè kafe, Black Rail Coffee, Hidden Grounds")
        XCTAssertTrue(app.staticTexts["bwè kafe · Black Rail Coffee · Hidden Grounds"].firstMatch.exists, "pins listed as text under the map")
    }

    func testDiagramSpeaksItsSteps() {
        let app = launch("diagram")
        let d = any(app, "render-diagram-0")
        XCTAssertTrue(d.waitForExistence(timeout: 15), "diagram component")
        XCTAssertTrue(d.label.hasPrefix("diagram Login flow with 6 steps: Open app to Enter email + password; Enter email + password to Verify"), d.label)
    }

    func testUnknownTypeIsNamedAndIssuesAreShown() {
        let app = launch("unknown")
        XCTAssertTrue(any(app, "render-unknown-0").waitForExistence(timeout: 15), "the unknown component card")
        XCTAssertTrue(app.staticTexts["unknown component type “gauge”"].firstMatch.exists, "the type the model invented is on the card")
        let issues = any(app, "render-issues")
        XCTAssertTrue(issues.exists, "issues line")
        XCTAssertTrue(issues.label.contains("unknown type \"gauge\"") && issues.label.contains("1 point had no numeric"), issues.label)
        XCTAssertTrue(any(app, "render-chart-1").exists, "the valid chart next to it still draws")
    }

    func testEveryKindHasACard() {
        for kind in ["chart", "line", "pie", "table", "keyvalue", "list", "progress", "misc"] {
            let app = launch(kind)
            XCTAssertTrue(any(app, "render-card-tooluse_r_\(kind)").waitForExistence(timeout: 15), "\(kind) card")
            app.terminate()
        }
    }

    func testToolIsListedInSettingsAsOnByDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "settings"]
        app.launch()
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), "Settings › Tools disclosure")
        if !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        let toggle = app.switches["tool.render_ui"].firstMatch
        for _ in 0..<6 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "render_ui has a row")
        XCTAssertEqual(app.staticTexts["tool.render_ui.default"].firstMatch.label, "on by default")
    }
}
