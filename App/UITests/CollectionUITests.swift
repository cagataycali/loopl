import XCTest

/// Models › "loopl models" (the Hugging Face collection, APP-COLLECTION lane). Deterministic on the simulator with
/// `--design-collection bundled` (the snapshot App/Resources/collection.json, no network): the section follows On this iPhone →
/// Browse → Train (owner's order), MLX rows carry the curator's note + vision badge, GGUF builds sit under a disclosure, the curated models.json
/// twins are deduped out of "Recommended", tapping a row opens the repo sheet. Since PUBLISH-V11 (#104) the snapshot is the six PUBLIC
/// v1.1 repos (3 MLX 4-bit + 3 bf16 post-tuning bases): no sign-in hint, no GGUF disclosure (no GGUF item in the collection).
/// Screenshots → LOOPL_SHOT_DIR: collection-top.png collection-sheet.png.
final class CollectionUITests: XCTestCase {
    func testCollectionSectionListsTheLooplModels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-gguf"]
        app.launch()
        // Owner's order (MODELS-ORDER) is On this iPhone → Browse → Train → loopl models → Mine, so Browse is on
        // screen BEFORE any scrolling and the collection is reached by scrolling down. Proving the order that way
        // instead of comparing two frames is what makes this work on a short screen: on an iPhone SE the swipe that
        // reaches the loopl row scrolls Browse out of the lazy List entirely, and the old frame comparison then
        // failed on a row that was never missing. (Found by running this suite on an SE — the CI runner picks the
        // tallest iPhone it has, so a test may quietly require a tall phone and nobody finds out.)
        let browse = app.descendants(matching: .any).matching(identifier: "models-browse-hub").firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "Browse Hugging Face is on screen at the top of Models")
        let four = app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-4bit").firstMatch
        if four.exists {
            // Tall screen: both fit, so the stronger claim is still available.
            XCTAssertGreaterThan(four.frame.minY, browse.frame.minY, "loopl models below Browse Hugging Face")
        }
        for _ in 0..<4 where !four.exists { app.swipeUp() }        // below Browse + Train on a small screen
        XCTAssertTrue(four.waitForExistence(timeout: 5), "loopl 4B row from the bundled collection snapshot")
        // The badge reads "sees pictures" and the subtitle is the plain blurb since IMPROVE-4 #142/#152 —
        // the owner's standing order is plainer words, so the test follows the words, not the old ones
        // ("vision" / the curator's "quiz 158" note).
        XCTAssertTrue(four.label.contains("sees pictures"), "vision badge from the files: \(four.label)")
        XCTAssertTrue(four.label.contains("Most capable"), "the plain blurb is the subtitle: \(four.label)")
        XCTAssertTrue(four.label.contains("GB"), "the size is on the row: \(four.label)")
        shoot(app, "collection-top")
        // The section sits below Browse + Train, so its tail is under the fold of the lazy List: scroll until each row is realised.
        func reach(_ id: String) -> XCUIElement {
            let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
            for _ in 0..<3 where !el.exists { app.swipeUp() }
            return el
        }
        for id in ["cagataydev/loopl-2b-4bit", "cagataydev/loopl-0.8b-4bit"] {
            XCTAssertTrue(reach("collection-row-\(id)").exists, id)
        }
        // Hidden: the bf16 post-tuning bases (and, in a wider snapshot, LoRA adapters, app-trained examples, datasets).
        for id in ["cagataydev/loopl-4b", "cagataydev/loopl-2b", "cagataydev/loopl-0.8b", "cagataydev/loopl-4b-lora", "cagataydev/loopl-train"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-row-\(id)").firstMatch.exists, "\(id) must not be listed")
        }
        // Public collection → no sign-in hint for an anonymous user.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-signed-out").firstMatch.exists, "public collection: no sign-in hint")
        let footer = reach("collection-footer")
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(footer.label.contains("bundled list"), footer.label)

        // No GGUF item in the public collection → no disclosure, even with Settings › Show GGUF builds on (--design-gguf).
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-gguf").firstMatch.exists, "no GGUF rows → no disclosure")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "collection-row-cagataydev/loopl-4b-GGUF").firstMatch.exists)

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
        let more = app.descendants(matching: .any).matching(identifier: "models-more").firstMatch
        for _ in 0..<4 where !(more.exists && more.isHittable) { app.swipeUp() }   // the row sits under the loopl models section (lazy List)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More models row")
        let q17 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Qwen3-1.7B'")).firstMatch
        XCTAssertFalse(q17.exists, "catalog depth folded by default")
        shoot(app, "shortlist-folded")
        more.tap()
        var opened = q17.waitForExistence(timeout: 5)
        for _ in 0..<3 where !opened { app.swipeUp(); opened = q17.waitForExistence(timeout: 2) }
        if !opened, more.exists, more.isHittable { more.tap(); opened = q17.waitForExistence(timeout: 5) }   // the tap landed on a scroll instead
        XCTAssertTrue(opened, "More models opens the curated catalog — more.exists=\(more.exists) hittable=\(more.isHittable) texts=\(app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.prefix(40))")
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

    /// A private (gated) catalog model tapped while signed out asks for the Hugging Face account FIRST — the download
    /// used to start, 401 on the first byte and park a red "is private or gated" row under "On this iPhone" with a Retry
    /// that could never work (IMPROVE-4 #11).
    func testGatedModelAsksToSignInBeforeDownloading() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models", "--design-collection", "bundled", "--design-gguf", "--storage-fixture", "none", "--design-signed-out"]
        app.launch()
        app.swipeUp(); app.swipeUp()
        let more = app.descendants(matching: .any).matching(identifier: "models-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More models row")
        more.tap()
        // By identifier, not by label: IMPROVE-4 #158 dropped "· Q4_K_M (llama.cpp)" from the displayed name,
        // so matching on the old text found nothing — and matching on "loopl 0.8B" would now be ambiguous with
        // the MLX row of the same name.
        let row = app.descendants(matching: .any).matching(identifier: "models-row-loopl-0.8b-q4_k_m").firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the private loopl GGUF row (gated in models.json)")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "onboarding-hf-token").firstMatch.waitForExistence(timeout: 5), "sign-in sheet before any download")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "models-failed-loopl-0.8b-q4_k_m").firstMatch.exists, "no failed row")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "models-retry-loopl-0.8b-q4_k_m").firstMatch.exists, "no Retry")
    }
}
