import XCTest

/// **One walk of a screen, two questions.** Both are geometry questions asked at **Accessibility XL**, where a
/// layout that merely bends at 17 pt breaks:
///
/// 1. *Is anything drawn outside the screen?* IMPROVE-8 found the whole chat 502 pt wide on a 402 pt screen (a
///    `fixedSize` pill in the approval card) with content clipped at BOTH edges — "elper" for *Helper*.
/// 2. *Is a sentence squeezed into a column by a control sharing its row?* THE most repeated layout bug in this
///    app: #194 ("Asks before POST, PUT, PATCH or DELETE" in ~139 pt), #195 (the approval card's header), #198
///    ("Hug-ging Face has a…" in ~90 pt beside **Get it**) and the collection row's curator note (150 pt) were
///    all one shape — a long `Text` and a short control in one `HStack`.
///
/// This file merges `OverflowAuditUITests` and `TypeSqueezeUITests`, which asked those two questions with the
/// **same launch recipe on the same screens** and were kept apart only because their pull requests could not be
/// stacked. Merging them is not tidiness:
///
/// - **It launches the app 9 times instead of 15.** Six of the nine screens were in both suites, and a launch at
///   Accessibility XL is the expensive part of each test.
/// - **It gives the overflow question the walk it never had.** `OverflowAuditUITests` measured ONE viewport, so
///   on a long screen it only ever audited the top of it, while the squeeze suite already knew the bug lives
///   below the fold (at Accessibility XL a Settings row is ~190 pt, so the first "Asks before …" note is the
///   sixth row). Both questions are now asked of everything the walk realises.
/// - **The walk goes back up.** A one-directional scroll leaves the screen somewhere it did not start, and only
///   measures layouts in the order they were first realised.
///
/// The failure message of each half names the element and its numbers, so a red run answers the question
/// instead of posing it.
final class ScreenAuditUITests: XCTestCase {
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Pin the text size IN THE TEST. `simctl ui <udid> content_size` persists on the simulator and leaks into
        // every test that does not pin its own — IMPROVE-8 left a device that way and OnboardingUITests failed
        // with a 1090 pt card.
        app.launchArguments = args + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        return app
    }

    // MARK: - the two questions

    /// Nothing may be drawn outside the screen.
    ///
    /// Only what a PERSON can perceive: elements with a non-empty accessibility label. Unnamed container frames
    /// are deliberately out of scope — a `List` reports its cell background at the section insets, i.e. 16 pt
    /// outside the window on EVERY screen at EVERY text size (measured on Models, Settings and Train, all three
    /// visually perfect at Accessibility XL). Including them means five failures and no bugs.
    ///
    /// Also skipped, each measured rather than assumed: the system's own scroll indicator, which sits in the edge
    /// inset by design; the scroll canvas, legitimately wider than its viewport; and a decoration under 4 pt tall,
    /// because `IndeterminateBar`'s accent segment sweeps by `.offset(x: w)` inside a `clipShape`, so its frame
    /// leaves the screen ([63…451] against a track at [63…362]) while nothing of it is ever drawn out there.
    private func collectOutside(_ app: XCUIApplication, into found: inout [String: String]) {
        let screen = app.windows.firstMatch.frame
        for el in app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
                + app.switches.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex
                + app.otherElements.allElementsBoundByIndex {
            let label = el.label
            guard !label.isEmpty, !label.hasSuffix("pages"), !label.contains("scroll bar") else { continue }
            let f = el.frame
            guard f.width > 1, f.height > 4, f.width < screen.width * 3 else { continue }
            let out = max(screen.minX - f.minX, f.maxX - screen.maxX)
            guard out > 1 else { continue }
            found[label] = "\(label.prefix(38)) [x \(Int(f.minX))…\(Int(f.maxX))] over by \(Int(out))"
        }
    }

    /// At Accessibility XL, a label of 25 characters or more given less than `min(45 % of the screen, 220 pt)`.
    ///
    /// The absolute term is the lesson of running this on an **iPad**, which `ui.yml` does not cover: a
    /// proportional rule alone is wrong on a wide screen, because text has a maximum readable measure. On an
    /// 834 pt iPad a perfectly formatted chat bubble is 324 pt (39 %), a History subtitle 263 pt and a tool row's
    /// note 357 pt — all flagged, none a bug. The real squeezes sit far lower in ABSOLUTE terms: 90, 132, 139,
    /// 150, 163, 175 pt. 220 pt separates the two sets, and on a small screen 45 % of 375 pt (169 pt) still binds.
    private func collectSqueezed(_ app: XCUIApplication, into found: inout [String: String]) {
        let w = app.windows.firstMatch.frame.width
        for el in app.staticTexts.allElementsBoundByIndex {
            let f = el.frame, label = el.label
            guard label.count >= 25, f.width > 1, f.height > 4 else { continue }
            // A monospaced value (a header value, a path, a sha) is not prose and may sit in a column, and an
            // availability CHIP's accessibility label is long by design while its capsule is deliberately small
            // ("unavailable: Not on Simulator — runs on a real iPhone", measured at 135 pt on an iPad).
            guard !label.contains("application/"), !label.hasPrefix("/"), !label.hasPrefix("unavailable:") else { continue }
            guard f.width < min(w * 0.45, 220) else { continue }
            found[label] = "“\(label.prefix(44))” in \(Int(f.width)) pt of \(Int(w))"
        }
    }

    // MARK: - the walk

    /// Walks the screen, asking both questions of every state the walk realises, down and then back up.
    ///
    /// Collect WHILE walking, never at the end: a guard that measures one viewport measures nothing on a long
    /// screen. Stops when a swipe produces no new text — fingerprinting the WHOLE visible set, not its last
    /// element, because a section footer stays realised and lies about the end of the list.
    private func audit(_ app: XCUIApplication, _ screen: String, settle: XCUIElement? = nil, scrolls: Int = 12) {
        if let settle { XCTAssertTrue(settle.waitForExistence(timeout: 20), "\(screen) drew") }
        var outside: [String: String] = [:], squeezed: [String: String] = [:]
        var lastSeen = ""
        for _ in 0..<scrolls {
            collectOutside(app, into: &outside)
            collectSqueezed(app, into: &squeezed)
            let fingerprint = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: "|")
            if fingerprint == lastSeen { break }
            lastSeen = fingerprint
            app.swipeUp()
        }
        // Back up, measuring on the way: a test that only ever scrolls one way leaves the screen somewhere it did
        // not start, and never sees a layout in the order a person scrolling back sees it.
        lastSeen = ""
        for _ in 0..<scrolls {
            collectOutside(app, into: &outside)
            collectSqueezed(app, into: &squeezed)
            let fingerprint = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: "|")
            if fingerprint == lastSeen { break }
            lastSeen = fingerprint
            app.swipeDown()
        }
        let worstOutside = outside.values.sorted().prefix(6).joined(separator: " · ")
        XCTAssertTrue(outside.isEmpty, "\(screen): outside the screen — \(worstOutside)")
        XCTAssertTrue(squeezed.isEmpty, "\(screen): a sentence squeezed into a column — "
                      + squeezed.values.sorted().joined(separator: " · "))
    }

    /// Settings with the Tools group expanded — the screen both original suites had to prepare by hand.
    private func settingsWithToolsOpen() -> XCUIApplication {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "settings"])
        let list = app.collectionViews["pane-settings"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "settings drew")
        let tools = app.descendants(matching: .any)["settings-tools"].firstMatch
        if tools.exists, !app.descendants(matching: .any)["settings-tools-group-on"].firstMatch.exists { tools.tap() }
        return app
    }

    // MARK: - the nine screens

    func testChatWithToolRows() {
        let app = launch(["--design-fixture", "tool", "--design-reasoning"])
        audit(app, "chat/tool", settle: app.descendants(matching: .any)["tool-row-calculator"].firstMatch)
    }

    func testApprovalCard() {
        let app = launch(["--design-fixture", "approval"])
        audit(app, "chat/approval", settle: app.buttons["Approve"].firstMatch)
    }

    func testAskUserForm() {
        let app = launch(["--design-fixture", "ask", "--design-ask", "form"])
        audit(app, "chat/ask-form", settle: app.descendants(matching: .any)["ask-card-form"].firstMatch)
    }

    func testRenderCards() {
        let app = launch(["--design-fixture", "render"])
        audit(app, "chat/render", settle: app.staticTexts.firstMatch)
    }

    func testModels() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-models", "shelf"])
        audit(app, "models", settle: app.collectionViews["pane-models"].firstMatch)
    }

    func testSettingsWithToolsOpen() {
        audit(settingsWithToolsOpen(), "settings/tools")
    }

    func testTrainForm() {
        let app = launch(["--skip-onboarding", "--design-fixture", "empty", "--design-tab", "models", "--design-train", "form"])
        audit(app, "train/form", settle: app.staticTexts.firstMatch)
    }

    func testHistory() {
        let app = launch(["--skip-onboarding", "--design-fixture", "history"])
        audit(app, "history", settle: app.staticTexts.firstMatch)
    }

    func testOnboardingPick() {
        let app = launch(["--design-fixture", "onboarding", "--design-onboarding-step", "pick", "--design-apple-fm"])
        audit(app, "onboarding/pick", settle: app.staticTexts.firstMatch)
    }
}
