import XCTest

/// #22 hardware-keyboard shortcuts (iPad / Mac / iPhone with a keyboard): ⌘N new conversation, ⌘Y History (⌘Y is the system Home chord on iPad),
/// ⌘. stop, ⌘↩ send. Driven with XCUIElement.typeKey on the simulator's hardware keyboard.
final class KeyboardShortcutsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene]
        app.launch()
        // A freshly launched sim window is not key for hardware-keyboard commands until it is touched once
        // (measured: ⌘N before any tap is dropped, after one tap it lands). A real user has always touched the app.
        _ = app.buttons.firstMatch.waitForExistence(timeout: 10)
        // Touch the navigation title — inert, so the tap itself changes nothing.
        let title = app.navigationBars.staticTexts.firstMatch
        if title.exists { title.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap() }
        usleep(400_000)
        // …and the FIRST hardware-key event after launch only attaches the simulated keyboard (it is dropped) —
        // measured with screenshots: chord #1 no-op, chord #2 lands. So spend the first one on a key with no binding.
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        usleep(400_000)
        return app
    }

    func testCommandNStartsANewConversation() {
        let app = launch("tool")
        let new = app.buttons["New conversation"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        XCTAssertTrue(new.isEnabled, "the tool fixture has a conversation")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitDisabled(new), "⌘N cleared the chat")
    }

    func testCommandReturnSends() {
        let app = launch("empty")
        let field = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("hello from the keyboard")
        // typeText goes through the software keyboard; switching back to the hardware keyboard drops its first
        // event again (same as after launch) — so the chord is pressed twice. The second press is a no-op if the
        // first landed (the field is empty → Send disabled), so this cannot double-send.
        // XCUIKeyboardKey.return + ⌘ never reaches the app (measured: not even a plain ⌘↩-bound button fires);
        // the literal "\n" does. The field stays focused — this is the in-composer path (LooplAppDelegate).
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey("\n", modifierFlags: .command)
        // send() empties the field the moment it fires (the fixture has no model, so nothing streams back).
        var cleared = false
        for _ in 0..<20 where !cleared { cleared = !((field.value as? String) ?? "").contains("hello from the keyboard"); if !cleared { usleep(150_000) } }
        XCTAssertTrue(cleared, "⌘↩ sent the draft: \(field.value ?? "nil")")
    }

    func testCommandPeriodStops() {
        let app = launch("live")
        let stop = app.buttons["Stop generating"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "the live replay is generating")
        app.typeKey(".", modifierFlags: .command)
        // Uninterrupted the replay runs ~8 s more; stopped, it ends at once.
        XCTAssertTrue(stop.waitForNonExistence(timeout: 2), "⌘. stopped the answer")
    }

    func testCommandYHistory() {
        let app = launch("history")
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: History is the NavigationSplitView sidebar. Portrait starts with it hidden, so ⌘Y shows it and
            // ⌘Y again hides it. The probe is the sidebar's own "History" section header — the chat detail has no
            // History control in split layout (`if !inSplit` in ChatView), so this text means "the sidebar is on screen".
            XCTAssertTrue(app.buttons["New conversation"].firstMatch.waitForExistence(timeout: 10))
            let header = app.staticTexts["History"]
            let visibleBefore = header.exists
            app.typeKey("y", modifierFlags: .command)
            if visibleBefore {
                XCTAssertTrue(header.waitForNonExistence(timeout: 3), "⌘Y hid the sidebar")
            } else {
                XCTAssertTrue(header.waitForExistence(timeout: 3), "⌘Y showed the sidebar")
            }
            app.typeKey("y", modifierFlags: .command)
            sleep(1)
            XCTAssertEqual(visibleBefore, header.exists, "⌘Y toggled it back")
        } else {
            XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
            app.typeKey("y", modifierFlags: .command)
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "⌘Y opened the History sheet")
        }
    }

    private func waitDisabled(_ e: XCUIElement) -> Bool {
        for _ in 0..<20 { if !e.isEnabled { return true }; usleep(150_000) }
        return false
    }
}
