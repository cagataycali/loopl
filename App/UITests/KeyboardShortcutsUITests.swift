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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
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
        app.typeKey(.return, modifierFlags: .command)
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
            // iPad: History is the sidebar — the chord hides it and brings it back.
            let row = app.buttons["New conversation"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let sidebarRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'New conversation' AND elementType == %d", XCUIElement.ElementType.cell.rawValue)).firstMatch
            let visibleBefore = sidebarRow.exists && sidebarRow.isHittable
            app.typeKey("y", modifierFlags: .command)
            sleep(1)
            XCTAssertNotEqual(visibleBefore, sidebarRow.exists && sidebarRow.isHittable, "⌘Y toggled the sidebar")
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
