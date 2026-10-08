import XCTest

/// Nothing may be drawn outside the screen. One screen per test, every one of them under **Accessibility XL**, because
/// that is where a layout that merely bends at 17 pt breaks: an audit found the whole chat 502 pt wide on a 402 pt
/// screen (a `fixedSize` pill in the approval card) with content clipped at BOTH edges — "elper" for *Helper*.
/// The failure message carries the element and its coordinates, so a run answers the question instead of posing it.
final class OverflowAuditUITests: XCTestCase {
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        return app
    }

    /// Every realised text, button and container measured against the window.
    /// Skipped on purpose, each measured rather than assumed:
    /// · an unrealised row in a lazy list reports an empty frame;
    /// · the scroll canvas is legitimately wider/taller than its viewport;
    /// · a decoration under 4 pt tall is not layout — `IndeterminateBar`'s accent segment sweeps by `.offset(x: w)`
    ///   inside a `clipShape`, so its frame leaves the screen ([63…451] against a track at [63…362]) while nothing of
    ///   it is ever drawn out there.
    private func assertNothingOutside(_ app: XCUIApplication, _ screenName: String, settle: XCUIElement? = nil) {
        if let settle { XCTAssertTrue(settle.waitForExistence(timeout: 20), "\(screenName) drew") }
        let screen = app.windows.firstMatch.frame
        var over: [(String, CGRect, CGFloat)] = []
        // Only what a PERSON can perceive: every element with a non-empty accessibility label. Unnamed container
        // frames are deliberately out of scope — a `List` reports its cell background at the section insets, i.e.
        // 16 pt outside the window on EVERY screen at EVERY text size (measured on Models, Settings and Train, all
        // three of which are visually perfect at Accessibility XL). Including them means five failures and no bugs;
        // excluding them still catches the real thing, because when a card demands too much width the labels inside
        // it are the ones that land off the glass.
        for el in app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
                + app.switches.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex
                + app.otherElements.allElementsBoundByIndex {
            // The system's own scroll indicator sits in the edge inset by design ("Vertical scroll bar, 2 pages",
            // measured [378…408] on a 402 pt screen) — it is chrome, not content.
            guard !el.label.isEmpty, !el.label.hasSuffix("pages"), !el.label.contains("scroll bar") else { continue }
            let f = el.frame
            guard f.width > 1, f.height > 4, f.width < screen.width * 3 else { continue }
            let out = max(screen.minX - f.minX, f.maxX - screen.maxX)
            guard out > 1 else { continue }
            over.append((el.label, f, out))
        }
        let worst = over.sorted { $0.2 > $1.2 }.prefix(6)
            .map { "\($0.0.prefix(38)) [x \(Int($0.1.minX))…\(Int($0.1.maxX))] over by \(Int($0.2))" }
        XCTAssertTrue(over.isEmpty, "\(screenName): outside the screen (0…\(Int(screen.maxX))): " + worst.joined(separator: " · "))
    }

    func testChatWithToolRowsFits() {
        let app = launch(["--design-fixture", "tool", "--design-reasoning"])
        assertNothingOutside(app, "chat/tool", settle: app.descendants(matching: .any)["tool-row-calculator"].firstMatch)
    }

    func testApprovalCardFits() {
        let app = launch(["--design-fixture", "approval"])
        assertNothingOutside(app, "chat/approval", settle: app.buttons["Approve"].firstMatch)
    }

    func testAskUserFormFits() {
        let app = launch(["--design-fixture", "ask", "--design-ask", "form"])
        assertNothingOutside(app, "chat/ask-form", settle: app.descendants(matching: .any)["ask-card-form"].firstMatch)
    }

    func testRenderCardsFit() {
        let app = launch(["--design-fixture", "render"])
        assertNothingOutside(app, "chat/render", settle: app.staticTexts.firstMatch)
    }

    func testModelsFits() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-models", "shelf"])
        assertNothingOutside(app, "models", settle: app.collectionViews["pane-models"].firstMatch)
    }

    func testSettingsWithToolsOpenFits() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "settings"])
        let list = app.collectionViews["pane-settings"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "settings drew")
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        if tools.exists, !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        assertNothingOutside(app, "settings/tools")
    }

    func testTrainFormFits() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-train", "form"])
        assertNothingOutside(app, "train/form", settle: app.staticTexts.firstMatch)
    }

    func testHistoryFits() {
        let app = launch(["--skip-onboarding", "--design-fixture", "history"])
        assertNothingOutside(app, "history", settle: app.staticTexts.firstMatch)
    }

    func testOnboardingPickFits() {
        let app = launch(["--design-fixture", "onboarding", "--design-onboarding-step", "pick", "--design-apple-fm"])
        assertNothingOutside(app, "onboarding/pick", settle: app.staticTexts.firstMatch)
    }
}
