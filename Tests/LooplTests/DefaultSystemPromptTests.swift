import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// The default system prompt is the user's to edit (PR #89) — but a stored copy of the build-9 default was never an
/// edit, so it upgrades to the current default (which carries the measured memory sentence). A real edit is kept.
@MainActor
final class DefaultSystemPromptTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "loopl.system") }

    func testDefaultCarriesTheMemorySentence() {
        XCTAssertTrue(AppSettings.defaultSystemPrompt.contains("remember and recall tools"))
        XCTAssertFalse(AppSettings.legacyDefaultSystemPrompts.contains(AppSettings.defaultSystemPrompt))
    }

    func testStoredLegacyDefaultUpgrades() {
        UserDefaults.standard.set(AppSettings.legacyDefaultSystemPrompts.first!, forKey: "loopl.system")
        XCTAssertEqual(AppSettings().systemPrompt, AppSettings.defaultSystemPrompt)
    }

    func testUserEditIsKept() {
        UserDefaults.standard.set("Always answer in Turkish.", forKey: "loopl.system")
        XCTAssertEqual(AppSettings().systemPrompt, "Always answer in Turkish.")
        UserDefaults.standard.removeObject(forKey: "loopl.system")
        XCTAssertEqual(AppSettings().systemPrompt, AppSettings.defaultSystemPrompt)
    }
}
#endif
