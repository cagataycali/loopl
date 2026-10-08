import XCTest

/// Video input: the `video` scene renders the user's clip as a chip (poster · m:ss · N frames)
/// above the question, and the composer's attach menu offers a video when the model can see. Screenshots attached.
final class VideoInputUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene, "--design-tab", "chat"]
        app.launch()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testVideoSceneShowsClipChipAndAnswer() {
        let app = launch(scene: "video")
        let chip = app.descendants(matching: .any).matching(identifier: "video-chip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the user turn shows the clip as a chip")
        XCTAssertTrue(chip.label.contains("0:10"), chip.label)
        XCTAssertTrue(chip.label.contains("10 frames"), "16-frame plan at 1 fps on a 10 s clip = 10 frames: \(chip.label)")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "[video attached:")).firstMatch.exists,
                       "no raw stand-in line in the bubble — that text is for text-only models")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "blue square")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "01-video-turn")
    }

    func testAttachMenuOffersVideoForAVisionModel() {
        let app = launch(scene: "vision")
        // `descendants(matching: .any)`, not `.buttons`: the attach control is a SwiftUI `Menu`, which XCUITest
        // exposes as a pop-up/other element, so `app.buttons[…]` never matched it. LooplModelsUITests already
        // reaches it this way.
        let attach = app.descendants(matching: .any).matching(identifier: "composer-attach").firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "vision fixture shows the attach button")
        attach.tap()
        XCTAssertTrue(app.buttons["Photo or Video"].waitForExistence(timeout: 5), "the picker takes photos and videos")
        XCTAssertTrue(app.buttons["Video from Files"].exists)
        shot(app, "02-attach-menu")
    }
}
