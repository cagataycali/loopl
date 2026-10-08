import XCTest

/// #20: the chat toolbar's Share menu offers Markdown and image, and each opens the system share sheet.
final class ConversationShareUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openShareSheet(_ entry: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "tool"]
        app.launch()
        let share = app.descendants(matching: .any).matching(identifier: "chat-share").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        // Menu rows surface by label, not by accessibilityIdentifier.
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", entry)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), entry)
        item.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10), "share sheet for \(entry)")
        // The chat is untouched behind the sheet (the menu must not hit the neighbouring New-conversation button).
        XCTAssertTrue(app.buttons["New conversation"].isEnabled)
    }

    func testShareAsMarkdown() { openShareSheet("Share as Markdown") }
    func testShareAsImage() { openShareSheet("Share as image") }
}
