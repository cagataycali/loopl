import XCTest

/// IMPROVE-7 AUDIT #3 — deleting the model that is ANSWERING.
///
/// `ModelsView.delete` called `engine.didDelete(spec)` and went straight on to `FileManager.removeItem`, while
/// `didDelete` only fired `Task { await unload() }` and returned. Nothing in that path looked at `isGenerating`,
/// and the swipe/context-menu Delete is offered on a row whose model is mid-answer (the row's *select* button does
/// check). So: the weights were unlinked while the model still held them, `unload()` set `readiness = .idle` and
/// `agent = nil` while the agent kept streaming from its own reference — the screen said *no model is running*
/// with a model visibly still talking, and `stop()` (which reads `agent`) could no longer cancel the run.
///
/// Reaching that state needs "a model is loaded AND the turn is in flight", which no fixture could produce — a
/// scene either scripts a finished conversation or replays a live one. `--design-answering` is the one-line seam
/// for it, the same shape as `designVision` in #184.
final class ModelDeleteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A loaded, downloaded `loopl-2b-4bit` with the turn still running, opened on Models.
    private func launchAnswering(tab: String = "models") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "streaming", "--design-models", "shelf",
                               "--design-answering", "--design-tab", tab]
        app.launch()
        return app
    }

    private func loadedRow(_ app: XCUIApplication) -> XCUIElement {
        // By identifier, never by the words on it (IMPROVE-6's rule — the words keep improving).
        app.cells.containing(.any, identifier: "models-row-loopl-2b-4bit").firstMatch
    }

    func testTheDeleteDialogSaysItWillStopTheAnswer() {
        let app = launchAnswering()
        XCTAssertTrue(app.collectionViews["pane-models"].waitForExistence(timeout: 20))
        let row = loadedRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the loaded model's row")
        XCTAssertTrue(row.isHittable, "a row off screen would be tapped at its centre and hit something else")
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "a downloaded model offers Delete")
        delete.tap()

        // The dialog must say what Delete is about to do, because this model is the one talking. Read as a WHOLE
        // (title + message) rather than by identifier: a `confirmationDialog` message becomes a UIAlertController
        // message and does not carry an `accessibilityIdentifier` — measured, the identifier never appears.
        let words = Self.dialogText(app)
        XCTAssertTrue(words.contains("answering"), "it must name the state, not just warn: \(words)")
        XCTAssertTrue(words.contains("stops that answer"), "and say what happens to the answer: \(words)")
        // No jargon in the one sentence standing between a tap and a lost answer.
        for word in ["unload", "weights", "readiness", "isgenerating", "idle"] {
            XCTAssertFalse(words.contains(word), "\(word) in: \(words)")
        }
    }

    /// The behaviour itself: confirm the delete and the answer must be OVER. Before the fix the turn kept running
    /// with no model behind it — the composer still showed Stop, forever, and the next turn had nothing to answer
    /// with. This is the assertion that fails on the old `Engine.didDelete`.
    func testDeletingTheAnsweringModelStopsTheAnswerFirst() {
        let app = launchAnswering(tab: "chat")
        let stop = app.buttons["Stop generating"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the fixture turn is in flight: the composer shows Stop")

        app.buttons["Models"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["pane-models"].waitForExistence(timeout: 20))
        let row = loadedRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        app.buttons["Delete"].firstMatch.tap()        // confirm

        app.buttons["Chat"].firstMatch.tap()
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 15),
                      "the answer was stopped before the files went, so the composer is back to Send")
        XCTAssertFalse(app.buttons["Stop generating"].firstMatch.exists,
                       "a turn cannot still be 'running' when the model behind it has been deleted")
    }

    /// Deleting a model that is NOT loaded must stay the quiet, ordinary case — no scary sentence, nothing stopped.
    func testDeletingAnIdleModelSaysNothingExtra() {
        let app = launchAnswering()
        XCTAssertTrue(app.collectionViews["pane-models"].waitForExistence(timeout: 20))
        let other = app.cells.containing(.any, identifier: "models-row-qwen3-0.6b-4bit").firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 15), "the shelf's other downloaded model")
        guard other.isHittable else { return }        // below the fold on a small screen: nothing to prove here
        other.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let words = Self.dialogText(app)
        XCTAssertFalse(words.isEmpty, "the confirmation dialog is up")
        for phrase in ["answering", "model in use", "stops that answer", "no model running"] {
            XCTAssertFalse(words.contains(phrase),
                           "a dialog that explains the ordinary case teaches the reader to skip it: \(words)")
        }
    }

    /// Everything the confirmation dialog shows, lowercased — title and message together.
    private static func dialogText(_ app: XCUIApplication) -> String {
        let sheet = app.sheets.firstMatch.waitForExistence(timeout: 5) ? app.sheets.firstMatch : app.alerts.firstMatch
        guard sheet.waitForExistence(timeout: 5) else { return "" }
        return sheet.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " · ").lowercased()
    }
}
