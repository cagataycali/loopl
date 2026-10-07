import XCTest

/// Reaching History is device-shaped, and getting it wrong is silent.
///
/// On iPhone, History is a sheet opened from a toolbar button. On iPad the app is a `NavigationSplitView` and
/// History is the sidebar — **hidden by default in portrait** (`NavigationSplitViewVisibility.automatic`), opened
/// by the split view's own toggle.
///
/// The trap this helper exists to close: `RootView` publishes the ⌘Y chord from a 0x0 proxy `Button("History")`
/// inside its `.background`, and `keyboardShortcut` keeps that proxy in the query tree even through
/// `.accessibilityHidden(true)`. So `app.buttons["History"].firstMatch` can resolve to an element of size
/// {0, 0} at the centre of the screen. Tapping it fails with
/// `kAXErrorCannotComplete performing AXAction kAXScrollToVisibleAction` — a failure that names a scroll, not a
/// missing screen, and so reads like a flake. It is why all four `HistoryUITests` failed the first time the suite
/// was run on an iPad, every one of them before reaching the screen under test.
///
/// Match identifiers, never the word a person reads (the lane's standing rule).
extension XCUIApplication {
    /// Opens History and returns its **Select** button, already existing. Fails with a readable reason otherwise.
    ///
    /// `expectSelect: false` for an EMPTY archive: History correctly offers nothing to select when there are no
    /// conversations (`Select` is hidden on `conversations.isEmpty`), so demanding it there asserts the opposite
    /// of the behaviour under test.
    @discardableResult
    func reachHistory(timeout: TimeInterval = 10, expectSelect: Bool = true) -> XCUIElement {
        let select = buttons["history.select"]
        if select.waitForExistence(timeout: 3) { return select }     // iPad landscape: the sidebar is already up

        let button = buttons["chat.history"]                          // iPhone: the real toolbar control
        // iPad: the split view's toggle is Apple's, and it ships with NO accessibility identifier — the measured
        // tree is `—|Show Sidebar|(36.0, 36.0)` next to the phantom `—|History|(0.0, 0.0)`. A label match is the
        // only handle that exists, so match on Apple's word ("Show Sidebar" / "Hide Sidebar"), never on ours, and
        // require a real size so the phantom can never satisfy it again.
        let sidebar = buttons.matching(NSPredicate(format: "label CONTAINS 'Sidebar'")).firstMatch
        // Poll for EITHER shape rather than waiting out the iPhone timeout first: a `waitForExistence(timeout:)`
        // on the control this device does not have is pure dead time (it cost 10 s of every iPad run).
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !button.exists, !sidebar.exists { usleep(200_000) }
        if button.exists {
            XCTAssertTrue(button.isHittable, "the History button must be on screen, not merely present: \(button.frame)")
            button.tap()
        } else if sidebar.exists {
            XCTAssertTrue(sidebar.isHittable, "the sidebar toggle must be on screen: \(sidebar.frame)")
            XCTAssertGreaterThan(sidebar.frame.height, 4, "a 0-size element is a shortcut proxy, not a control")
            sidebar.tap()
        } else {
            // A failure that names what WAS on screen. The original iPad failure said only
            // "failed to scroll to visible", which reads like a flake and cost a lane's worth of guessing.
            let seen = buttons.allElementsBoundByIndex.prefix(40)
                .map { "\($0.identifier.isEmpty ? "—" : $0.identifier)|\($0.label)|\($0.frame.size)" }
                .joined(separator: "\n  ")
            XCTFail("no way to open History on this device: neither chat.history (iPhone) nor the iPad sidebar toggle exists.\nbuttons on screen:\n  \(seen)")
        }
        if expectSelect { XCTAssertTrue(select.waitForExistence(timeout: timeout), "Select button in History") }
        return select
    }

    /// True when History is the iPad sidebar rather than the iPhone sheet — decided by the split view's own
    /// toggle being on screen, not by a screen width this app does not get to choose.
    var historyIsSidebar: Bool {
        buttons.matching(NSPredicate(format: "label CONTAINS 'Sidebar'")).count > 0
    }

    /// Assert that the app states HOW MANY conversations are about to be deleted, where a person can see it.
    ///
    /// On iPhone that is the navigation bar title ("3 selected"). In the iPad sidebar the bar carries Cancel and
    /// Select all leading and the split view's toggle trailing, and UIKit drops the inline title for want of room —
    /// measured, with a screenshot: the sidebar's bar shows no title at all in selection mode. The count is still
    /// stated on the destructive button itself ("Delete 3"), so require THAT on every device and the title only
    /// where it is actually rendered. This is why four of these tests were phone-shaped.
    func assertSelectionCount(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counted = n == 1 ? "Delete 1" : "Delete \(n)"
        XCTAssertTrue(buttons[counted].waitForExistence(timeout: 3),
                      "the destructive button must state the count", file: file, line: line)
        if !historyIsSidebar {
            XCTAssertTrue(navigationBars.staticTexts["\(n) selected"].exists,
                          "on a phone the navigation bar states the count", file: file, line: line)
        }
    }
}
