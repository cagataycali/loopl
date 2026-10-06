import XCTest

/// Owner's two reports after downloading loopl-4b from Models › Mine (2026-10-06 07:5xZ): the "vision" badge was wrong
/// (the row said vision, the weights had no tower, the photo button vanished) and the model did not know who built it.
/// Proofs on the simulator (fixtures; MLX is compiled out here):
///   1. `--design-fixture persona` loads the loopl 0.8B row → Settings › System prompt carries "loopl identity (built in)",
///      the editor shows the built-in text; the row says vision but the fixture's LOCAL config.json has no tower (the owner's
///      old download) → NO attach button; `--design-local-vision` (files agree with the row) and the `vision` fixture show one.
///   2. Models › Mine with the owner's token (LOOPL_HF_TOKEN via `simctl spawn launchctl setenv`): the loopl-4b-4bit row
///      has no "vision" badge (qwen3_5 model_type, no processor files), Browse's Qwen3.5-0.8B-4bit keeps it.
/// Screenshots → LOOPL_SHOT_DIR: persona-settings.png persona-editor.png persona-chat.png vision-chat.png mine-badges.png.
final class LooplModelsUITests: XCTestCase {
    func testPersonaInSettingsAndNoPhotoButtonForTextOnlyLoopl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "persona", "--design-tab", "settings"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "settings-system-prompt").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings › System prompt row")
        let badge = app.descendants(matching: .any).matching(identifier: "settings-persona-badge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "loopl model loaded → 'loopl identity (built in)' badge")
        XCTAssertTrue(badge.label.contains("loopl identity"), badge.label)
        shoot(app, "persona-settings")
        row.tap()
        let group = app.descendants(matching: .any).matching(identifier: "settings-persona").firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), "identity disclosure in the editor")
        group.tap()
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'built by Cagatay Cali (@cagataycali)'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the built-in identity text is shown")
        shoot(app, "persona-editor")

        // Chat: the row says vision, the files on the phone do not → no attach button (the files win).
        app.terminate()
        app.launchArguments = ["--design-fixture", "persona"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Cagatay Cali'")).firstMatch.waitForExistence(timeout: 10))
        let attach = app.descendants(matching: .any).matching(identifier: "composer-attach").firstMatch
        XCTAssertFalse(attach.exists, "local config.json without vision_config must hide the photo button, whatever the row says")
        shoot(app, "persona-chat")

        // Same row, files agree (the re-downloaded mlx_vlm export) → the button is back.
        app.terminate()
        app.launchArguments = ["--design-fixture", "persona", "--design-local-vision"]
        app.launch()
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "vision files on the phone → attach button")
        shoot(app, "persona-chat-vision")

        // Control: the vision fixture (Qwen3.5-0.8B-4bit row, vision=true) shows it.
        app.terminate()
        app.launchArguments = ["--design-fixture", "vision"]
        app.launch()
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "vision model → attach button")
        shoot(app, "vision-chat")
    }

    func testMineBadgeFollowsTheFilesNotTheArchitecture() throws {
        let token = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "needs LOOPL_HF_TOKEN (owner's Hugging Face token) in the runner env")
        let app = XCUIApplication()
        app.launchArguments = ["--design-fixture", "empty", "--design-tab", "models"]
        app.launchEnvironment["LOOPL_HF_TOKEN"] = token
        app.launch()
        let list = app.collectionViews["pane-models"]
        if !list.waitForExistence(timeout: 8) {
            let item = app.buttons["Models"].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap() }
            XCTAssertTrue(list.waitForExistence(timeout: 10))
        }
        let hit4b = app.descendants(matching: .any).matching(identifier: "mine-hit-cagataydev/loopl-4b-4bit").firstMatch
        XCTAssertTrue(hit4b.waitForExistence(timeout: 40), "no Mine row for loopl-4b-4bit — whoami/listing failed or the token is not seen")
        for _ in 0..<6 where !hit4b.isHittable { list.swipeUp() }
        let label = hit4b.label
        // The weights have no tower (0/924 visual tensors) — the row must not say vision, whatever model_type says.
        // (If VISION-EXPORT has re-pushed loopl-4b-4bit with a tower by the time this runs, the files say vision and the badge may.)
        let files = try listedFiles("cagataydev/loopl-4b-4bit", token: token)
        let hasProcessor = files.contains("preprocessor_config.json")
        XCTAssertEqual(label.contains("vision"), hasProcessor, "badge '\(label)' vs Hub files \(files)")
        shoot(app, "mine-badges")
    }

    /// Top-level file names of a repo straight from the Hub (the same truth the badge must follow).
    private func listedFiles(_ repo: String, token: String) throws -> [String] {
        var req = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(repo)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var result: [String] = []
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sib = row["siblings"] as? [[String: Any]] {
                result = sib.compactMap { $0["rfilename"] as? String }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
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
