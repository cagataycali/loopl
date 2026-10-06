import XCTest

/// Geometry guard for the bug the owner hit on iOS 27.0.1: the bottom tab bar
/// covered the last row of the scrollable panes — Settings' destructive
/// "Delete conversation history" and the Models list's last model.
///
/// Each test scrolls a pane to its end and asserts, in points, that the last row
/// clears the tab bar: `tabBar.minY - lastRow.maxY >= 0`, with the measured gap
/// attached to the result bundle next to a screenshot.
///
/// Own scheme (`looplUITests`) so the other lanes' unit-test gate stays untouched.
/// `TEST_RUNNER_INSETS_BEFORE=1` launches the app with `--design-no-clearance`,
/// which reproduces the pre-fix geometry — that is how the before/after pairs in
/// the lane's shots/ were captured from one build.
final class InsetsUITests: XCTestCase {
    /// Pre-fix capture mode: measure and screenshot, never fail. Set by the two
    /// `*WithoutClearance` capture tests (not by an environment variable, so a
    /// plain `-only-testing:` run is enough to reproduce either geometry).
    private var before = false
    private var tag: String { before ? "before" : "after" }

    /// Which simulator this run is on — the same suite runs on SE / 16 Pro /
    /// 16 Pro Max / iPad Pro, and the gap is only meaningful next to the device.
    private var deviceTag: String {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "unknown"
    }

    override func setUp() { continueAfterFailure = false }

    private func launch(tab: String, dynamicTypeXL: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", tab]
        if before { app.launchArguments.append("--design-no-clearance") }
        if dynamicTypeXL {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launch()
        return app
    }

    /// The floating tab bar, or nil on iPad (NavigationSplitView — no tab bar).
    private func tabBar(_ app: XCUIApplication) -> XCUIElement? {
        let bar = app.tabBars.firstMatch
        return bar.waitForExistence(timeout: 10) ? bar : nil
    }

    /// The pane's own list. On iPad the app is a NavigationSplitView, so the
    /// pane has to be picked from the sidebar first — and `collectionViews.firstMatch`
    /// would otherwise be the sidebar, not the pane.
    private func pane(_ app: XCUIApplication, _ identifier: String, sidebar: String) -> XCUIElement {
        let list = app.collectionViews[identifier]
        if list.waitForExistence(timeout: 8) { return list }
        let item = app.buttons[sidebar].firstMatch
        if item.waitForExistence(timeout: 5) { item.tap() }
        XCTAssertTrue(list.waitForExistence(timeout: 10), "pane \(identifier) never appeared")
        return list
    }

    private func scrollToEnd(_ scroll: XCUIElement, times: Int = 16) {
        XCTAssertTrue(scroll.waitForExistence(timeout: 15), "no list in this pane")
        for _ in 0..<times { scroll.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.0)   // let the scroll settle so frames are final
    }

    /// A `List` only instantiates the rows near the viewport, so a row in the
    /// middle of a long pane has to be scrolled INTO existence before it can be
    /// measured (on an iPhone SE the Storage section is off the a11y tree once the
    /// list is scrolled to its end).
    private func scrollUntilVisible(_ scroll: XCUIElement, _ element: XCUIElement, times: Int = 14) {
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        for _ in 0..<times {
            if element.exists && element.isHittable { break }
            scroll.swipeUp(velocity: .fast)
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func lastRow(_ scroll: XCUIElement) -> XCUIElement {
        let cells = scroll.cells
        XCTAssertGreaterThan(cells.count, 0, "empty list")
        return cells.element(boundBy: cells.count - 1)
    }

    @discardableResult
    private func check(_ element: XCUIElement, _ app: XCUIApplication, _ label: String,
                       file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(label) not found", file: file, line: line)
        let bar = tabBar(app)
        let limit = bar?.frame.minY ?? app.windows.firstMatch.frame.maxY
        let gap = limit - element.frame.maxY
        let name = "\(label)-\(tag)"
        // One grep-able line per measurement: the gates read the geometry out of the
        // xcodebuild log (`grep INSETS-GAP`), so a run is checkable without opening
        // the .xcresult. Device name included because the same test runs on 4 sims.
        print("INSETS-GAP device=\(deviceTag) case=\(name) maxY=\(element.frame.maxY) limit=\(limit) gap=\(gap)")
        XCTContext.runActivity(named: "\(name): maxY \(element.frame.maxY) · limit \(limit) · gap \(gap)") { a in
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.lifetime = .keepAlways
            shot.name = name
            a.add(shot)
            let text = XCTAttachment(string: "\(name) maxY=\(element.frame.maxY) limit=\(limit) gap=\(gap)\n")
            text.lifetime = .keepAlways
            text.name = "\(name).txt"
            a.add(text)
        }
        if !before {
            XCTAssertGreaterThanOrEqual(gap, 0, "\(label) is UNDER the bar by \(-gap) pt", file: file, line: line)
        }
        return gap
    }

    // MARK: - Settings

    func testSettingsBottomClearsTabBar() {
        let app = launch(tab: "settings")
        let list = pane(app, "pane-settings", sidebar: "Settings")
        scrollToEnd(list)
        check(lastRow(list), app, "settings-last-row")
    }

    func testSettingsDeleteHistoryButtonIsHittable() {
        let app = launch(tab: "settings")
        let list = pane(app, "pane-settings", sidebar: "Settings")
        let btn = app.buttons["Delete conversation history"]
        scrollUntilVisible(list, btn)
        check(btn, app, "settings-delete-history")
    }

    func testSettingsBottomClearsTabBarAtAccessibilityXL() {
        let app = launch(tab: "settings", dynamicTypeXL: true)
        let list = pane(app, "pane-settings", sidebar: "Settings")
        scrollToEnd(list, times: 30)
        check(lastRow(list), app, "settings-last-row-axXL")
    }

    // MARK: - Models

    func testModelsBottomClearsTabBar() {
        let app = launch(tab: "models")
        let list = pane(app, "pane-models", sidebar: "Models")
        scrollToEnd(list, times: 22)
        check(lastRow(list), app, "models-last-row")
    }

    func testModelsBottomClearsTabBarAtAccessibilityXL() {
        let app = launch(tab: "models", dynamicTypeXL: true)
        let list = pane(app, "pane-models", sidebar: "Models")
        scrollToEnd(list, times: 40)
        check(lastRow(list), app, "models-last-row-axXL")
    }

    // MARK: - Before/after captures (same build, `--design-no-clearance` = the old geometry)

    /// Documents the bug: with the clearance suppressed the last row ends flush
    /// against the tab bar (gap 0) — or under it, on a system that floats the bar.
    func testSettingsBottomWithoutClearance() {
        before = true
        let app = launch(tab: "settings")
        let list = pane(app, "pane-settings", sidebar: "Settings")
        scrollToEnd(list)
        check(lastRow(list), app, "settings-last-row")
    }

    func testModelsBottomWithoutClearance() {
        before = true
        let app = launch(tab: "models")
        let list = pane(app, "pane-models", sidebar: "Models")
        scrollToEnd(list, times: 22)
        check(lastRow(list), app, "models-last-row")
    }

    // MARK: - Pushed panes inside a tab (same bar behind them)

    func testToolsEditorBottomClearsTabBar() {
        let app = launch(tab: "settings")
        _ = pane(app, "pane-settings", sidebar: "Settings")   // iPad: pick the pane from the sidebar first
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.tap()
        let list = app.collectionViews.firstMatch
        scrollToEnd(list, times: 20)
        check(lastRow(list), app, "tools-last-row")
    }

    func testHubBrowseBottomClearsTabBar() {
        let app = launch(tab: "models")
        _ = pane(app, "pane-models", sidebar: "Models")
        let browse = app.descendants(matching: .any)["models-browse-hub"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        let list = app.collectionViews.firstMatch
        scrollToEnd(list, times: 10)
        check(lastRow(list), app, "hub-browse-last-row")
    }
}
