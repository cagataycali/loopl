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
        for legacy in AppSettings.legacyDefaultSystemPrompts {       // build ≤ 9 and the 1.0.1 text of builds 10–14
            UserDefaults.standard.set(legacy, forKey: "loopl.system")
            XCTAssertEqual(AppSettings().systemPrompt, AppSettings.defaultSystemPrompt, legacy)
        }
    }

    /// The rule (2026-10-06): the directives live in the prompt, not in code — mount a missing tool before saying
    /// "I can't", compact when long, delegate with use_agent. No "write tool code" directive (runtime creation skipped).
    func testDefaultCarriesThePhase6Directives() {
        let p = AppSettings.defaultSystemPrompt
        for tool in ["manage_tools", "manage_messages", "use_agent"] { XCTAssertTrue(p.contains(tool), tool) }
        XCTAssertFalse(p.lowercased().contains("swift"))
        XCTAssertFalse(p.lowercased().contains("javascript"))
        XCTAssertLessThan(p.split(separator: " ").count, 160, "a default prompt for 0.8B–4B models stays short")
    }

    func testUserEditIsKept() {
        UserDefaults.standard.set("Always answer in Turkish.", forKey: "loopl.system")
        XCTAssertEqual(AppSettings().systemPrompt, "Always answer in Turkish.")
        UserDefaults.standard.removeObject(forKey: "loopl.system")
        XCTAssertEqual(AppSettings().systemPrompt, AppSettings.defaultSystemPrompt)
    }
}
#endif
