import XCTest

/// Models › "loopl models" (the Hugging Face collection, APP-COLLECTION lane). Deterministic on the simulator with
/// `--design-collection bundled` (the snapshot App/Resources/collection.json, no network): the section follows On this iPhone →
/// Browse → Train (owner's order), MLX rows carry the curator's note + vision badge, GGUF builds sit under a disclosure, the curated models.json
/// twins are deduped out of "Recommended", anonymous → the sign-in hint, tapping a row opens the repo sheet.
/// Screenshots → LOOPL_SHOT_DIR: collection-top.png collection-gguf.png collection-sheet.png.
final class CollectionUITests: XCTestCase {
    func testCollectionSectionListsTheLooplModels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-gguf"]
        app.launch()
        let four = app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-4bit").firstMatch
        if !four.waitForExistence(timeout: 10) { app.swipeUp() }   // below Browse + Train on a small screen
        XCTAssertTrue(four.waitForExistence(timeout: 5), "loopl 4B row from the bundled collection snapshot")
        XCTAssertTrue(four.label.contains("vision"), "vision badge from the files: \(four.label)")
        XCTAssertTrue(four.label.contains("quiz 111"), "the curator's note is the subtitle: \(four.label)")
        // Owner's order (MODELS-ORDER): On this iPhone → Browse → Train → loopl models → Mine — the section sits BELOW Browse now.
        let browse = app.descendants(matching: .any).matching(identifier: "models-browse-hub").firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(four.frame.minY, browse.frame.minY, "loopl models below Browse Hugging Face")
        shoot(app, "collection-top")
        // The section sits below Browse + Train, so its tail is under the fold of the lazy List: scroll until each row is realised.
        func reach(_ id: String) -> XCUIElement {
            let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
            for _ in 0..<3 where !el.exists { app.swipeUp() }
            return el
        }
        for id in ["cagataydev/loopl-2b-4bit", "cagataydev/loopl-0.8b-v1.1-4bit", "cagataydev/loopl-0.8b-4bit"] {
            XCTAssertTrue(reach("collection-row-\(id)").exists, id)
        }
        // Hidden: bf16 merges, the LoRA adapter, the app-trained examples, datasets.
        for id in ["cagataydev/loopl-4b", "cagataydev/loopl-4b-lora", "cagataydev/loopl-app-sim-4bit", "cagataydev/loopl-train"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-row-\(id)").firstMatch.exists, "\(id) must not be listed")
        }
        XCTAssertTrue(reach("collection-signed-out").exists, "anonymous → sign-in hint")
        let footer = reach("collection-footer")
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(footer.label.contains("bundled list"), footer.label)

        // GGUF under the disclosure.
        let gguf = reach("collection-gguf")
        XCTAssertTrue(gguf.exists)
        let ggufRow = app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-GGUF").firstMatch
        XCTAssertFalse(ggufRow.exists, "GGUF rows start collapsed")
        gguf.tap()
        // The expanded rows land below the fold of a lazy List: bring them on screen before asking for them.
        if !ggufRow.waitForExistence(timeout: 2) { app.swipeUp(); _ = ggufRow.waitForExistence(timeout: 3) }
        if !ggufRow.exists { gguf.tap(); app.swipeUp() }   // the first tap may have scrolled instead of toggling
        XCTAssertTrue(ggufRow.waitForExistence(timeout: 5), "GGUF rows after opening the disclosure — \(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'collection-'")).allElementsBoundByIndex.map { $0.identifier })")
        XCTAssertFalse(ggufRow.label.contains("vision"), "GGUF is text only")
        shoot(app, "collection-gguf")

        // Dedupe: the curated models.json loopl rows are not repeated under More models.
        app.swipeUp(); app.swipeUp()
        let more = app.descendants(matching: .any).matching(identifier: "models-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More models row")
        more.tap()
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Qwen3-1.7B'")).firstMatch.waitForExistence(timeout: 5)
        let curatedTwin = app.staticTexts.matching(NSPredicate(format: "label == 'loopl 0.8B'")).count
        XCTAssertLessThanOrEqual(curatedTwin, 1, "the models.json twin must not appear a second time under More models")

        // Row → the same repo sheet Browse uses (private + anonymous: the sheet says so, nothing crashes).
        for _ in 0..<6 where !(four.exists && four.isHittable) { app.swipeDown() }
        XCTAssertTrue(four.waitForExistence(timeout: 5))
        four.tap()
        let sheetTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'loopl-4b-4bit'")).firstMatch
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "repo sheet for the tapped collection row")
        shoot(app, "collection-sheet")
    }

    /// Owner 15:5xZ: fewer, quality models — GGUF builds out of the main list (Settings › Show GGUF builds), the curated catalog folded
    /// behind one "More models" row, Apple Intelligence + the loopl models as the featured set (`featured` in models.json).
    func testShortlistFoldsTheCatalogAndHidesGGUFByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled"]
        app.launch()
        let four = app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-4bit").firstMatch
        if !four.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(four.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-gguf").firstMatch.exists, "GGUF disclosure hidden until Settings › Show GGUF builds")
        app.swipeUp()
        let more = app.descendants(matching: .any).matching(identifier: "models-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More models row")
        let q17 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Qwen3-1.7B'")).firstMatch
        XCTAssertFalse(q17.exists, "catalog depth folded by default")
        shoot(app, "shortlist-folded")
        more.tap()
        XCTAssertTrue(q17.waitForExistence(timeout: 5) || { app.swipeUp(); return q17.waitForExistence(timeout: 3) }(), "More models opens the curated catalog")
        app.swipeUp(); app.swipeUp(); app.swipeUp()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'llama.cpp'")).firstMatch.exists, "no GGUF rows without the switch")
        shoot(app, "shortlist-open")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["LOOPL_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        XCTContext.runActivity(named: name) { a in
            let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; att.name = name; a.add(att)
        }
    }
}
