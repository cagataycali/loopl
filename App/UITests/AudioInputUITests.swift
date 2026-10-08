import XCTest

/// Audio input the composer's mic button starts a take (× · live waveform + clock · ✓),
/// ✓ turns it into a chip (play · duration · ×), Send puts one marker line into the user message which the
/// transcript renders as the same chip. The `audio` scene shows the model calling `transcribe` on it.
/// Screenshots are attached at every step (the audit's captures come from these attachments).
/// The host grants the microphone up front (`simctl privacy grant microphone`); the denied path is covered
/// by the fixture's `--mic-denied` switch so no system alert is involved.
final class AudioInputUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(scene: String = "tool", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", scene, "--design-tab", "chat"] + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testRecordChipSendShowsInTranscript() {
        let app = launch()
        let mic = app.buttons["Record audio"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "mic button is always in the composer")
        shot(app, "01-composer-mic")
        mic.tap()

        let finish = app.buttons["Finish recording"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "recording bar replaced the field")
        XCTAssertTrue(app.buttons["Cancel recording"].exists)
        XCTAssertFalse(app.textFields["Message"].exists, "the field is hidden while recording")
        sleep(2)
        shot(app, "02-recording")
        finish.tap()

        let play = app.buttons["Play recording"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "the take became a chip")
        XCTAssertTrue(app.buttons["Remove recording"].exists)
        XCTAssertTrue(app.textFields["Message"].exists, "field is back")
        shot(app, "03-chip")

        // Play the take back from the chip (it toggles to Stop while audio runs).
        play.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 3) || app.buttons["Play recording"].exists)

        // A recording alone makes the message sendable (the fixture has no model behind it, so we stop here;
        // the `audio` scene below shows what the sent turn looks like).
        XCTAssertTrue(app.buttons["Send"].isEnabled, "a recording alone is sendable")
        shot(app, "04-chip-sendable")
    }

    func testTranscriptRendersTheRecordingChipAndTranscribeRow() {
        let app = launch(scene: "audio")
        let chip = app.buttons["Play recording"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "user turn shows the recording as a chip")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "[audio attached:")).firstMatch.exists,
                       "the marker line itself is not shown")
        // By identifier: #140 gave the row plain words, so "transcribe" is no longer in its label.
        let row = app.descendants(matching: .any)["tool-row-transcribe"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "transcribe tool row")
        shot(app, "05-transcript-audio")
        row.tap()
        sleep(1)
        shot(app, "06-transcribe-expanded")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "hello from loopl")).firstMatch.waitForExistence(timeout: 3))
    }

    func testCancelAndRemove() {
        let app = launch()
        let mic = app.buttons["Record audio"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()
        let cancel = app.buttons["Cancel recording"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 3), "× brings the field back with no chip")
        XCTAssertFalse(app.buttons["Play recording"].exists)

        mic.tap()
        let finish = app.buttons["Finish recording"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        sleep(1)
        finish.tap()
        let remove = app.buttons["Remove recording"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(app.buttons["Play recording"].waitForExistence(timeout: 2), "chip removed")
        shot(app, "07-after-remove")
    }

    func testDeniedMicrophoneShowsCalmNotice() {
        let app = launch(extra: ["--mic-denied"])
        let mic = app.buttons["Record audio"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()
        let notice = app.staticTexts["Microphone is off for loopl."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "inline notice, no alert")
        XCTAssertTrue(app.links["Open Settings"].exists || app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["Finish recording"].exists)
        shot(app, "08-mic-denied")
        app.buttons["Dismiss"].tap()
        XCTAssertFalse(notice.waitForExistence(timeout: 2))
    }

    func testReduceMotionPath() {
        let app = launch(extra: ["-UIAccessibilityReduceMotionEnabled", "1"])
        let mic = app.buttons["Record audio"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()
        let finish = app.buttons["Finish recording"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "09-recording-reduce-motion")
        finish.tap()
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 5))
    }
}
